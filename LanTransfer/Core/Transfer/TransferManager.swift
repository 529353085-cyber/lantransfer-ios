//
//  TransferManager.swift
//  局域网快传
//
//  传输状态机（核心）：发送方主动连接接收方，控制连接走 HELLO→REQUEST→ACCEPT→
//  RESUME→PLAN→VERIFY→COMPLETE，数据块走每块独占的数据连接（20B 头 + 裸流）。
//  与桌面 TransferManager.ts / Android TransferManager.kt 消息时序逐条对齐。
//

import Foundation
import Combine

@MainActor
final class TransferManager: ObservableObject {
    @Published var tasks: [TransferTask] = []
    @Published var incoming: IncomingRequest?
    @Published var notice: CompleteNotice?

    let selfDevice: Device
    private let registry: DeviceRegistry
    private let settings: () -> Settings
    private let recordStore: TransferRecordStore
    private let chatManager: ChatManager
    private let server: TcpServer

    /// 接收侧共享状态（控制连接与数据连接共用），按 transferId 索引。
    private var receiveStates: [String: ReceiveState] = [:]
    private var cancelled: Set<String> = []
    /// 接收请求的确认等待器：transferId -> (结果 continuation)。
    private var decisionWaiters: [String: CheckedContinuation<Bool, Never>] = [:]

    init(
        selfDevice: Device,
        registry: DeviceRegistry,
        settings: @escaping () -> Settings,
        recordStore: TransferRecordStore,
        chatManager: ChatManager
    ) {
        self.selfDevice = selfDevice
        self.registry = registry
        self.settings = settings
        self.recordStore = recordStore
        self.chatManager = chatManager
        self.server = TcpServer(deviceId: selfDevice.deviceId)
    }

    /// 聊天连接回调（由 AppState 装配 ChatChannel.handleIncoming）。
    var onChatConnection: ((TcpConnection) -> Void)?

    func startServer(chatHandler: (@escaping (TcpConnection) -> Void)? = nil) throws {
        server.onControl = { [weak self] link in
            Task { await self?.handleControl(link) }
        }
        server.onData = { [weak self] link in
            Task { await self?.handleDataConnection(link) }
        }
        server.onChat = { link in
            chatHandler?(link)
        }
        try server.start(port: TCP_PORT)
    }

    func stopServer() { server.stop() }

    // MARK: - 发送入口

    func send(
        urls: [URL], to device: Device,
        category: TransferCategory = .normal,
        chatMsgId: String = "",
        forcedTransferId: String? = nil
    ) async {
        let cfg = settings()
        var files: [FileMeta] = []
        var tempBundles: [String] = []
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lantransfer-bundles", isDirectory: true)

        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                do {
                    let built = try FolderBundle.build(folderURL: url, tempDir: tempDir)
                    tempBundles.append(built.bundlePath.path)
                    files.append(FileMeta(
                        fileId: newId(), name: built.bundlePath.lastPathComponent,
                        size: built.size, sha256: built.sha256,
                        mime: "application/x-lantransfer-folder",
                        bundle: FolderBundleRef(format: "LFTB1", rootName: built.manifest.rootName, fileCount: built.manifest.files.count),
                        localPath: built.bundlePath.path
                    ))
                } catch {
                    await publishNotice(CompleteNotice(transferId: newId(), title: "打包失败", message: error.localizedDescription, success: false))
                    continue
                }
            } else {
                guard let url = try? accessSecurityScoped(url),
                      let sha = try? ChecksumUtil.sha256File(url),
                      let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { continue }
                files.append(FileMeta(
                    fileId: newId(), name: url.lastPathComponent, size: size.int64Value,
                    sha256: sha, mime: mimeType(for: url), localPath: url.path
                ))
            }
        }
        guard !files.isEmpty else {
            await publishNotice(CompleteNotice(transferId: newId(), title: "发送失败", message: "没有可发送的文件", success: false))
            return
        }

        var task = TransferTask(
            transferId: forcedTransferId ?? newId(), peer: device, direction: .send, files: files,
            totalSize: files.reduce(0) { $0 + $1.size },
            concurrency: max(MIN_CONCURRENCY, min(MAX_CONCURRENCY, cfg.concurrency)),
            chunkSize: ChunkPlanner.normalizeChunkSize(cfg.chunkSizeMB * 1024 * 1024),
            saveDir: cfg.saveDir, category: category, chatMsgId: chatMsgId,
            tempBundlePaths: tempBundles
        )
        upsertTask(task)

        do {
            try await runSend(&task, to: device)
        } catch {
            task.status = .failed
            task.errorMessage = error.localizedDescription
            for file in task.files {
                recordStore.add(makeRecord(task, file, .failed, 0, ""))
            }
            await publishNotice(CompleteNotice(transferId: task.transferId, title: "发送失败", message: error.localizedDescription, success: false))
        }
        upsertTask(task)
        cleanupBundles(task.tempBundlePaths)
    }

    private func runSend(_ task: inout TransferTask, to device: Device) async throws {
        let link = try await connectTcp(
            host: device.ip, port: UInt16(device.tcpPort > 0 ? device.tcpPort : Int(TCP_PORT)),
            channel: .control, purpose: "transfer", deviceId: selfDevice.deviceId
        )
        defer { link.close() }

        var request = TransferRequestPayload(
            transferId: task.transferId, files: task.files, totalSize: task.totalSize
        )
        if task.category == .chatImage {
            request.category = "CHAT_IMAGE"
            request.chatMsgId = task.chatMsgId
        }
        try await link.sendMessage(.transferRequest, request)

        let decisionEnv = try await link.reader.readFrame()
        if decisionEnv.type == .transferReject {
            let reject = try decodePayload(decisionEnv, as: TransferDecisionPayload.self)
            throw FrameError.socket(reject.reason ?? "对方拒绝了传输")
        }
        guard decisionEnv.type == .transferAccept else {
            throw FrameError.invalidFrame("期望 TRANSFER_ACCEPT/REJECT")
        }
        task.status = .accepted
        upsertTask(task)

        // 后台心跳：响应对端 PING。
        let heartbeat = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(HEARTBEAT_INTERVAL_MS) * 1_000_000)
                if Task.isCancelled { break }
                try? await link.sendMessage(.pong, PingPayload(ts: Int64(Date().timeIntervalSince1970 * 1000)))
            }
        }
        defer { heartbeat.cancel() }

        task.status = .transferring
        upsertTask(task)
        for file in task.files {
            try await sendOneFile(&task, file: file, link: link, peer: device)
        }
        task.status = .success
        task.finishedAt = Int64(Date().timeIntervalSince1970 * 1000)
        upsertTask(task)
        await publishNotice(CompleteNotice(
            transferId: task.transferId, title: "发送完成",
            message: "\(task.files.count) 项已成功送达 \(device.displayName)", success: true
        ))
    }

    private func sendOneFile(_ task: inout TransferTask, file: FileMeta, link: TcpConnection, peer: Device) async throws {
        task.currentFileName = file.displayName
        upsertTask(task)
        let transferId = task.transferId
        let chunkSize = task.chunkSize
        let totalSize = task.totalSize
        let totalChunks = ChunkPlanner.totalChunks(file.size, chunkSize: chunkSize)

        try await link.sendMessage(.resumeQuery, ResumeQueryPayload(transferId: transferId, fileId: file.fileId))
        let resumeEnv = try await link.reader.readFrame()
        guard resumeEnv.type == .resumeResponse else { throw FrameError.invalidFrame("期望 RESUME_RESPONSE") }
        let resume = try decodePayload(resumeEnv, as: ResumeResponsePayload.self)
        var missing = ChunkPlanner.missingChunks(done: resume.doneChunks, total: totalChunks)
        task.transferredBytes += resume.receivedBytes
        upsertTask(task)

        try await link.sendMessage(.chunkPlan, ChunkPlanPayload(
            transferId: transferId, fileId: file.fileId, chunkSize: chunkSize, totalChunks: totalChunks
        ))

        let crcBox = CRCMapBox()
        var verifyRounds = 0
        while true {
            if !missing.isEmpty && !cancelled.contains(transferId) {
                let sentBytes = try await sendChunks(
                    file: file, indices: missing, chunkSize: chunkSize,
                    peer: peer, transferId: transferId, crcBox: crcBox
                )
                addProgress(sentBytes, to: transferId, cap: totalSize)
            }

            try await link.sendMessage(.verifyRequest, VerifyRequestPayload(
                transferId: transferId, fileId: file.fileId,
                expectSha256: file.sha256, crcMap: crcBox.snapshot()
            ))
            let verifyEnv = try await link.reader.readFrame()
            guard verifyEnv.type == .verifyResult else { throw FrameError.invalidFrame("期望 VERIFY_RESULT") }
            let result = try decodePayload(verifyEnv, as: VerifyResultPayload.self)
            if result.ok { break }

            verifyRounds += 1
            if verifyRounds >= MAX_VERIFY_ROUNDS { throw FrameError.invalidFrame(ErrorCode.hashMismatch.rawValue) }
            var badChunks = result.mismatchChunks ?? []
            if badChunks.isEmpty { badChunks = missing }
            try? await link.sendMessage(.resendChunk, ResendChunkPayload(
                transferId: transferId, fileId: file.fileId, chunkIndex: badChunks
            ))
            for index in badChunks where !missing.contains(index) { missing.append(index) }
            missing.sort()
        }

        let elapsed = max(0.001, Double(Date().timeIntervalSince1970 * 1000) - Double(task.startedAt)) / 1000.0
        task.speedBps = Int64(Double(file.size) / elapsed)
        recordStore.add(makeRecord(task, file, .success, task.speedBps, file.localPath ?? ""))
        if task.category == .chatImage && !task.chatMsgId.isEmpty {
            chatManager.markImageSent(msgId: task.chatMsgId, transferId: transferId)
        }
        try? await link.sendMessage(.transferComplete, TransferCompletePayload(
            transferId: transferId, fileId: file.fileId, finalPath: "",
            size: file.size, avgSpeedBps: task.speedBps
        ))
    }

    private func sendChunks(
        file: FileMeta, indices: [Int], chunkSize: Int, peer: Device, transferId: String,
        crcBox: CRCMapBox
    ) async throws -> Int64 {
        let concurrency = max(1, min(MAX_CONCURRENCY, settings().concurrency))
        let deviceId = selfDevice.deviceId
        let port = UInt16(peer.tcpPort > 0 ? peer.tcpPort : Int(TCP_PORT))
        let path = file.localPath ?? ""
        let fileName = file.name
        let sentCounter = SentBytesCounter()

        // sendOne 为顶层静态函数，避免捕获 actor 隔离的 self / inout 参数。
        func sendOne(_ index: Int) async throws {
            let length = ChunkPlanner.lengthOf(index, fileSize: file.size, chunkSize: chunkSize)
            let offset = ChunkPlanner.offsetOf(index, chunkSize: chunkSize)
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: length) ?? Data()
            guard data.count == length else { throw FrameError.socket("读取源文件失败：\(fileName)") }
            let crc = CRC32.checksum(data)
            crcBox.set(String(index), UInt64(crc))

            let dataLink = try await connectTcp(
                host: peer.ip, port: port,
                channel: .data, purpose: "transfer", transferId: transferId,
                fileId: file.fileId, chunkIndex: index, deviceId: deviceId
            )
            defer { dataLink.close() }
            var frame = FrameCodec.encodeDataHeader(DataHeader(
                cmd: MAGIC_DATA, transferKey: toTransferKey(transferId),
                chunkIndex: UInt32(index), chunkLen: UInt32(length), crc32: crc
            ))
            frame.append(data)
            try await dataLink.send(frame)
            await dataLink.waitForEnd()
            sentCounter.add(Int64(length))
        }

        var inFlight: [Task<Void, Error>] = []
        for index in indices {
            if cancelled.contains(transferId) { break }
            inFlight.append(Task { try await sendOne(index) })
            if inFlight.count >= concurrency {
                for t in inFlight { try await t.value }
                inFlight.removeAll()
            }
        }
        for t in inFlight { try await t.value }
        return sentCounter.value
    }

    // MARK: - 接收：控制连接

    private func handleControl(_ link: TcpConnection) async {
        var transferId = ""
        var state: ReceiveState?
        let heartbeat = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(HEARTBEAT_INTERVAL_MS) * 1_000_000)
                if Task.isCancelled { break }
                try? await link.sendMessage(.ping, PingPayload(ts: Int64(Date().timeIntervalSince1970 * 1000)))
            }
        }
        defer {
            heartbeat.cancel()
            if !transferId.isEmpty { receiveStates[transferId] = nil }
            link.close()
        }

        while true {
            let env: ProtocolEnvelope
            do { env = try await link.reader.readFrame() } catch { break }
            switch env.type {
            case .transferRequest:
                guard let request = try? decodePayload(env, as: TransferRequestPayload.self) else { continue }
                transferId = request.transferId
                state = await beginReceive(request, link: link)

            case .resumeQuery:
                guard let query = try? decodePayload(env, as: ResumeQueryPayload.self), let s = state else { continue }
                let done = ResumeManager.doneChunks(partPath: s.partPath(for: query.fileId))
                let received = done.reduce(Int64(0)) { sum, idx in
                    sum + Int64(ChunkPlanner.lengthOf(idx, fileSize: s.sizeOf(fileId: query.fileId), chunkSize: s.chunkSize))
                }
                try? await link.sendMessage(.resumeResponse, ResumeResponsePayload(
                    transferId: query.transferId, fileId: query.fileId, doneChunks: done, receivedBytes: received
                ))

            case .chunkPlan:
                guard let plan = try? decodePayload(env, as: ChunkPlanPayload.self), let s = state else { continue }
                s.chunkSize = plan.chunkSize
                s.totalChunks = plan.totalChunks

            case .resendChunk:
                guard let resend = try? decodePayload(env, as: ResendChunkPayload.self), let s = state else { continue }
                s.markUndone(fileId: resend.fileId, indices: resend.chunkIndex)

            case .verifyRequest:
                guard let verify = try? decodePayload(env, as: VerifyRequestPayload.self), let s = state else { continue }
                await handleVerify(verify, state: s, link: link)

            case .transferCancel:
                cancelled.insert(transferId)

            case .ping:
                try? await link.sendMessage(.pong, PingPayload(ts: Int64(Date().timeIntervalSince1970 * 1000)))

            default:
                break
            }
        }
    }

    /// 收到 TRANSFER_REQUEST：准备 part/目录，弹确认或静默接受，回 ACCEPT/REJECT。
    private func beginReceive(_ request: TransferRequestPayload, link: TcpConnection) async -> ReceiveState? {
        let cfg = settings()
        // 通过 HELLO.deviceId 找到对端设备（注册表由发现层维护），找不到时用占位设备。
        let peer: Device = {
            let helloId = link.hello?.deviceId ?? ""
            if let found = registry.get(helloId) { return found }
            return Device(
                deviceId: helloId.isEmpty ? request.transferId : helloId,
                deviceName: "对端设备", deviceType: .mobile, ip: link.peerAddress, platform: "unknown"
            )
        }()

        let saveRoot: URL
        if request.category == "CHAT_IMAGE" && cfg.chatAutoAcceptImages {
            let chatDir = documentsURL()
                .appendingPathComponent(CHAT_IMAGE_SUBDIR, isDirectory: true)
                .appendingPathComponent(PathSanitizer.sanitizeFileName(peer.displayName), isDirectory: true)
            saveRoot = chatDir
        } else {
            saveRoot = documentsURL()
        }

        guard let state = try? ReceiveState(
            transferId: request.transferId, peer: peer,
            files: request.files, saveDir: saveRoot, chunkSize: DEFAULT_CHUNK_SIZE
        ) else {
            try? await link.sendMessage(.transferReject, TransferDecisionPayload(transferId: request.transferId, reason: "非法文件路径"))
            return nil
        }
        receiveStates[request.transferId] = state

        // 建一个接收任务用于 UI。
        var task = TransferTask(
            transferId: request.transferId, peer: state.peer, direction: .receive,
            files: request.files, totalSize: request.totalSize, saveDir: saveRoot.path,
            category: request.category == "CHAT_IMAGE" ? .chatImage : .normal,
            chatMsgId: request.chatMsgId ?? ""
        )
        task.status = .accepted
        upsertTask(task)
        state.task = task

        let accepted: Bool
        if request.category == "CHAT_IMAGE" && cfg.chatAutoAcceptImages {
            accepted = true
        } else {
            let req = IncomingRequest(
                transferId: request.transferId, peer: state.peer, files: request.files,
                totalSize: request.totalSize, saveDir: saveRoot.path,
                expiresAt: Int64(Date().timeIntervalSince1970 * 1000) + ACCEPT_TIMEOUT_MS,
                category: request.category == "CHAT_IMAGE" ? .chatImage : .normal,
                chatMsgId: request.chatMsgId ?? ""
            )
            incoming = req
            accepted = await withCheckedContinuation { continuation in
                decisionWaiters[request.transferId] = continuation
            }
            decisionWaiters[request.transferId] = nil
            incoming = nil
        }

        if accepted {
            try? await link.sendMessage(.transferAccept, TransferDecisionPayload(transferId: request.transferId, saveDir: saveRoot.path))
            return state
        } else {
            try? await link.sendMessage(.transferReject, TransferDecisionPayload(transferId: request.transferId, reason: "用户拒绝"))
            receiveStates[request.transferId] = nil
            return nil
        }
    }

    /// UI 调用：接受/拒绝接收请求。
    func acceptIncoming(_ accept: Bool) {
        guard let transferId = incoming?.transferId else { return }
        decisionWaiters[transferId]?.resume(returning: accept)
        decisionWaiters[transferId] = nil
        if !accept { incoming = nil }
    }

    // MARK: - 接收：数据连接

    private func handleDataConnection(_ link: TcpConnection) async {
        guard let hello = link.hello, hello.channel == .data,
              let transferId = hello.transferId, let fileId = hello.fileId,
              let chunkIndex = hello.chunkIndex else { link.close(); return }
        defer { link.close() }
        guard let state = receiveStates[transferId] else { link.close(); return }

        do {
            let header = try await link.reader.readDataHeader()
            guard header.chunkLen > 0, header.chunkLen <= 32 * 1024 * 1024 else {
                throw FrameError.invalidFrame("非法块长度 \(header.chunkLen)")
            }
            let data = try await link.reader.readExactly(Int(header.chunkLen))
            guard CRC32.checksum(data) == header.crc32 else {
                state.markBad(fileId: fileId, index: Int(header.chunkIndex))
                return
            }
            try state.writeChunk(fileId: fileId, index: Int(header.chunkIndex), data: data, chunkSize: state.chunkSize)
            await MainActor.run {
                state.task.transferredBytes = min(state.task.totalSize, state.task.transferredBytes + Int64(data.count))
                self.upsertTask(state.task)
            }
        } catch {
            state.markBad(fileId: fileId, index: chunkIndex)
        }
    }

    // MARK: - 接收：校验

    /// 校验单个 fileId（发送方逐文件发 VERIFY_REQUEST，与桌面/Andoid 语义一致）。
    /// 含 R-001 有界宽限轮询：控制连接与数据连接独立，VERIFY 可能抢在最后几块落盘前到达，
    /// 判定缺块前先轮询位图，避免把正常但稍慢的块误判为失败。
    private func handleVerify(_ verify: VerifyRequestPayload, state: ReceiveState, link: TcpConnection) async {
        guard let file = state.files.first(where: { $0.fileId == verify.fileId }) else {
            let result = VerifyResultPayload(transferId: verify.transferId, fileId: verify.fileId, ok: false, mismatchChunks: [])
            try? await link.sendMessage(.verifyResult, result)
            return
        }
        let total = ChunkPlanner.totalChunks(file.size, chunkSize: state.chunkSize)

        // R-001：有界宽限 —— 800ms 无进展宽限 + 有进展就继续等（硬上限 VERIFY_MAX_WAIT_MS）。
        var missing = state.missingChunks(fileId: file.fileId)
        var lastProgressAt = Date()
        let hardDeadline = Date().addingTimeInterval(Double(VERIFY_MAX_WAIT_MS) / 1000.0)
        var lastDoneCount = total - missing.count
        let grace = Double(VERIFY_GRACE_MS) / 1000.0
        while !missing.isEmpty, Date() < hardDeadline {
            try? await Task.sleep(nanoseconds: UInt64(VERIFY_POLL_INTERVAL_MS) * 1_000_000)
            missing = state.missingChunks(fileId: file.fileId)
            let doneCount = total - missing.count
            if doneCount > lastDoneCount {
                lastDoneCount = doneCount
                lastProgressAt = Date()
            }
            // 连续 grace 秒无进展即停止等待，按当前位图判定。
            if Date().timeIntervalSince(lastProgressAt) >= grace { break }
        }

        if !missing.isEmpty {
            let result = VerifyResultPayload(
                transferId: verify.transferId, fileId: verify.fileId,
                ok: false, mismatchChunks: missing
            )
            try? await link.sendMessage(.verifyResult, result)
            return
        }

        // 位图已齐，做整文件 SHA-256 校验并终化。
        do {
            let finalPath = try state.finalize(fileId: file.fileId, expectSha256: verify.expectSha256)
            state.finalPaths[file.fileId] = finalPath
            state.task.finalPaths = state.finalPaths
            state.task.currentFileName = file.displayName

            // 发送方逐文件顺序校验；最后一个文件通过即整个任务完成。
            let allDone = (verify.fileId == state.files.last?.fileId)
            let elapsed = max(0.001, Double(Date().timeIntervalSince1970 * 1000) - Double(state.task.startedAt)) / 1000.0
            let speed = Int64(Double(file.size) / elapsed)
            state.task.speedBps = speed
            recordStore.add(makeRecord(state.task, file, .success, speed, finalPath))
            if state.task.category == .chatImage && !state.task.chatMsgId.isEmpty {
                chatManager.markImageReceived(msgId: state.task.chatMsgId, transferId: verify.transferId, localPath: finalPath)
            }
            if allDone {
                state.task.status = .success
                state.task.finishedAt = Int64(Date().timeIntervalSince1970 * 1000)
            }
            upsertTask(state.task)

            try? await link.sendMessage(.verifyResult, VerifyResultPayload(
                transferId: verify.transferId, fileId: verify.fileId, ok: true, mismatchChunks: []
            ))
            await publishNotice(CompleteNotice(
                transferId: verify.transferId, title: "接收完成",
                message: "\(file.displayName) 已接收并通过校验", localPath: finalPath, success: true
            ))
        } catch {
            // SHA-256 不匹配：回报全部块让发送方重传（最多 MAX_VERIFY_ROUNDS 轮）。
            let allChunks = Array(0..<total)
            let result = VerifyResultPayload(
                transferId: verify.transferId, fileId: verify.fileId,
                ok: false, mismatchChunks: allChunks
            )
            try? await link.sendMessage(.verifyResult, result)
        }
    }

    // MARK: - 记录与工具

    private func makeRecord(_ task: TransferTask, _ file: FileMeta, _ status: TaskStatus, _ speed: Int64, _ localPath: String) -> TransferRecord {
        TransferRecord(
            recordId: newId(), timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            peerId: task.peer.deviceId, peerName: task.peer.displayName, peerIp: task.peer.ip,
            fileName: file.displayName, fileSize: file.size, direction: task.direction,
            status: status, avgSpeedBps: speed, localPath: localPath,
            sha256: file.sha256, mime: file.mime, errorCode: nil, category: task.category
        )
    }

    private func publishNotice(_ notice: CompleteNotice) async { self.notice = notice }

    private func cleanupBundles(_ paths: [String]) {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    private func accessSecurityScoped(_ url: URL) throws -> URL {
        let got = url.startAccessingSecurityScopedResource()
        defer { if got { url.stopAccessingSecurityScopedResource() } }
        return url
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    private func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func upsertTask(_ task: TransferTask) {
        if let index = tasks.firstIndex(where: { $0.transferId == task.transferId }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
    }

    /// 并发块完成后累加进度（MainActor 隔离，直接改 tasks 数组）。
    private func addProgress(_ bytes: Int64, to transferId: String, cap: Int64) {
        guard let index = tasks.firstIndex(where: { $0.transferId == transferId }) else { return }
        tasks[index].transferredBytes = min(cap, tasks[index].transferredBytes + bytes)
    }

    func cancelTask(_ taskId: String) { cancelled.insert(taskId) }
    func deleteTasks(_ ids: Set<String>) { tasks.removeAll { ids.contains($0.transferId) } }
    func clearNotice() { notice = nil }
}

/// 线程安全的 CRC 映射容器（并发块写入，主线程快照读取）。
final class CRCMapBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: UInt64] = [:]
    func set(_ key: String, _ value: UInt64) {
        lock.lock(); map[key] = value; lock.unlock()
    }
    func snapshot() -> [String: UInt64] {
        lock.lock(); defer { lock.unlock() }
        return map
    }
}

/// 线程安全字节累加器。
final class SentBytesCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ bytes: Int64) { lock.lock(); total += bytes; lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return total }
}
