//
//  ReceiveState.swift
//  章鱼快传
//
//  接收任务的共享状态：管理每个文件的 part 文件、位图、落点与坏块标记。
//  由控制连接（协商/校验）与多条数据连接（块落盘）并发访问，内部用 NSLock 串行化。
//

import Foundation

final class ReceiveState {
    let transferId: String
    let peer: Device
    let files: [FileMeta]
    let saveDir: URL
    var chunkSize: Int = DEFAULT_CHUNK_SIZE
    var totalChunks: Int = 0

    /// 对应的接收任务（进度/状态由控制连接更新，MainActor 隔离下访问）。
    var task: TransferTask
    /// fileId -> 最终落盘路径（聊天图片回写与「打开」入口使用）。
    var finalPaths: [String: String] = [:]

    /// fileId -> 文件最终落点信息。
    private let targets: [String: Target]
    /// fileId -> 坏块索引集合（CRC 失败/写失败）。
    private var badChunks: [String: Set<Int>] = [:]
    private let lock = NSLock()

    struct Target {
        let file: FileMeta
        let partPath: URL
        let finalPath: URL
        let targetDir: URL
        let safeName: String
    }

    init(transferId: String, peer: Device, files: [FileMeta], saveDir: URL, chunkSize: Int, task: TransferTask? = nil) throws {
        self.transferId = transferId
        self.peer = peer
        self.files = files
        self.saveDir = saveDir
        self.chunkSize = chunkSize
        self.totalChunks = files.first.map { ChunkPlanner.totalChunks($0.size, chunkSize: chunkSize) } ?? 0
        // task 由 TransferManager.beginReceive 在确认阶段赋值；这里给占位值保证存储属性已初始化。
        self.task = task ?? TransferTask(
            transferId: transferId, peer: peer, direction: .receive, files: files,
            totalSize: files.reduce(0) { $0 + $1.size }
        )

        var built: [String: Target] = [:]
        for file in files {
            // 文件夹整包直接落在 saveDir 根目录，用包名做文件名。
            guard let resolved = PathSanitizer.resolveTargets(
                saveDir: saveDir, name: file.name,
                relativePath: file.bundle == nil ? file.relativePath : nil,
                fileId: file.fileId
            ) else {
                throw FrameError.invalidFrame("非法文件路径：\(file.name)")
            }
            built[file.fileId] = Target(
                file: file,
                partPath: resolved.partPath,
                finalPath: resolved.finalPath,
                targetDir: resolved.targetDir,
                safeName: resolved.safeName
            )
        }
        self.targets = built
    }

    func partPath(for fileId: String) -> URL { targets[fileId]!.partPath }
    func finalPath(for fileId: String) -> URL { targets[fileId]!.finalPath }
    func file(for fileId: String) -> FileMeta { targets[fileId]!.file }
    func target(for fileId: String) -> Target { targets[fileId]! }

    func sizeOf(fileId: String) -> Int64 { file(for: fileId).size }

    /// 写入一个已通过 CRC 校验的块到 part 文件指定偏移，并标记位图完成。
    func writeChunk(fileId: String, index: Int, data: Data, chunkSize: Int) throws {
        let target = targets[fileId]!
        let partPath = target.partPath
        let offset = ChunkPlanner.offsetOf(index, chunkSize: chunkSize)

        lock.lock()
        defer { lock.unlock() }

        // 确保 part 文件存在并预分配到文件大小（稀疏文件）。
        if !FileManager.default.fileExists(atPath: partPath.path) {
            FileManager.default.createFile(atPath: partPath.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partPath)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()

        // 更新位图。
        let total = ChunkPlanner.totalChunks(target.file.size, chunkSize: chunkSize)
        var bitmap = ResumeManager.read(partPath: partPath)
            ?? BitmapState(chunkSize: chunkSize, totalChunks: total, done: Array(repeating: false, count: total))
        if bitmap.done.count != total || bitmap.chunkSize != chunkSize {
            bitmap = BitmapState(chunkSize: chunkSize, totalChunks: total, done: Array(repeating: false, count: total))
        }
        if index >= 0 && index < bitmap.done.count { bitmap.done[index] = true }
        try ResumeManager.write(bitmap, partPath: partPath)
    }

    /// CRC 失败时记录坏块（位图不会标记完成，VERIFY 时自然回报）。
    func markBad(fileId: String, index: Int) {
        lock.lock()
        var set = badChunks[fileId] ?? Set<Int>()
        set.insert(index)
        badChunks[fileId] = set
        lock.unlock()
    }

    func badIndices(fileId: String) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return Array(badChunks[fileId] ?? []).sorted()
    }

    /// 读取位图中未完成的块索引。
    func missingChunks(fileId: String) -> [Int] {
        let partPath = targets[fileId]!.partPath
        let total = ChunkPlanner.totalChunks(file(for: fileId).size, chunkSize: chunkSize)
        let done = ResumeManager.doneChunks(partPath: partPath)
        return ChunkPlanner.missingChunks(done: done, total: total)
    }

    /// 收到 RESEND_CHUNK 后清除指定块的完成标记（清位屏障）。
    func markUndone(fileId: String, indices: [Int]) {
        let partPath = targets[fileId]!.partPath
        guard var bitmap = ResumeManager.read(partPath: partPath) else { return }
        lock.lock()
        for index in indices where index >= 0 && index < bitmap.done.count {
            bitmap.done[index] = false
        }
        try? ResumeManager.write(bitmap, partPath: partPath)
        lock.unlock()
    }

    /// 校验并终化单个文件：SHA-256 → 文件夹解包或 part 重命名 → 返回最终路径。
    func finalize(fileId: String, expectSha256: String) throws -> String {
        let target = targets[fileId]!
        let partPath = target.partPath
        guard FileManager.default.fileExists(atPath: partPath.path) else {
            throw FrameError.invalidFrame("part 文件不存在")
        }
        let actual = try ChecksumUtil.sha256File(partPath)
        guard actual.lowercased() == expectSha256.lowercased() else {
            throw FrameError.invalidFrame(ErrorCode.hashMismatch.rawValue)
        }

        var finalURL: URL
        if let bundle = target.file.bundle {
            // 文件夹整包：解包到 saveDir/rootName，删除临时包。
            let extracted = try FolderBundle.extract(
                bundlePath: partPath, saveDir: saveDir,
                expectedRootName: bundle.rootName, expectedFileCount: bundle.fileCount
            )
            finalURL = extracted.folderPath
            try? FileManager.default.removeItem(at: partPath)
        } else {
            finalURL = target.finalPath
            try? FileManager.default.createDirectory(at: target.targetDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partPath, to: finalURL)
        }
        ResumeManager.remove(partPath: partPath)
        return finalURL.path
    }
}
