//
//  AppState.swift
//  局域网快传
//
//  全局界面状态容器 + 依赖装配。所有视图通过 @EnvironmentObject 读取状态、调用动作。
//  这里把 Core 层（发现/传输/聊天/存储）与视图绑定起来。
//

import SwiftUI
import Combine
import Network
import UniformTypeIdentifiers
import CryptoKit

@MainActor
final class AppState: ObservableObject {
    // MARK: - 视图状态
    @Published var devices: [Device] = []
    @Published var tasks: [TransferTask] = []
    @Published var records: [TransferRecord] = []
    @Published var incoming: IncomingRequest? = nil
    @Published var notice: CompleteNotice? = nil
    @Published var settings: Settings = Settings()
    @Published var selfDeviceName: String = "我的 iPhone" {
        didSet { applyAlias() }
    }
    @Published var isDiscovering: Bool = false

    /// 系统「文件」App 打开失败时的兜底提示；原路径保留供“预览文件”使用。
    @Published var folderOpenFailedPath: String? = nil

    @Published var conversations: [ConversationSummary] = []
    @Published var chatMessages: [ChatMessage] = []
    @Published var activeConversationId: String? = nil

    /// 本机设备 id（稳定持久化）。
    let selfDeviceId: String
    private var selfDevice: Device

    // MARK: - Core 依赖
    private let registry: DeviceRegistry
    private let discovery: DiscoveryManager
    private let recordStore: TransferRecordStore
    private let settingsStore: SettingsStore
    private let chatManager: ChatManager
    private let transferManager: TransferManager
    private let chatChannel: ChatChannel
    private var cancellables = Set<AnyCancellable>()
    private var probeTimer: Timer?
    private var isProbing = false

    init() {
        // 设备 id 持久化到 UserDefaults，保证重启后不变（会话/记录关联稳定）。
        let defaults = UserDefaults.standard
        let storedId = defaults.string(forKey: "lantransfer.deviceId")
        let id = storedId ?? UUID().uuidString
        if storedId == nil { defaults.set(id, forKey: "lantransfer.deviceId") }
        self.selfDeviceId = id

        let storedAlias = defaults.string(forKey: "lantransfer.alias") ?? ""
        let name = storedAlias.isEmpty ? UIDevice.current.name : storedAlias
        let device = Device(
            deviceId: id, deviceName: name, deviceType: .mobile,
            ip: AppState.localIPv4() ?? "127.0.0.1", platform: "iOS"
        )
        self.selfDevice = device
        self.selfDeviceName = name

        self.registry = DeviceRegistry()
        self.discovery = DiscoveryManager(selfDevice: device, registry: registry)
        self.recordStore = TransferRecordStore()
        self.settingsStore = SettingsStore()
        self.settings = settingsStore.settings

        let chatStore = ChatMessageStore()
        self.chatManager = ChatManager(selfId: id, selfName: name, store: chatStore)

        let records = recordStore
        let st = settingsStore
        self.transferManager = TransferManager(
            selfDevice: device, registry: registry,
            settings: { st.settings }, recordStore: records, chatManager: chatManager
        )
        self.chatChannel = ChatChannel(
            selfDevice: device, chatManager: chatManager,
            onIncomingImage: { _ in /* 图片字节由聊天图片传输静默接收 */ }
        )

        bindCore()
        startServices()
    }

    // MARK: - 绑定 Core 状态到视图

    private func bindCore() {
        registry.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.devices = $0 }
            .store(in: &cancellables)

        transferManager.$tasks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.tasks = $0 }
            .store(in: &cancellables)

        transferManager.$incoming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.incoming = $0 }
            .store(in: &cancellables)

        transferManager.$notice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.notice = $0 }
            .store(in: &cancellables)

        chatManager.$conversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.conversations = $0 }
            .store(in: &cancellables)

        chatManager.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.chatMessages = $0.values.flatMap { $0 }
            }
            .store(in: &cancellables)

        settingsStore.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.settings = $0 }
            .store(in: &cancellables)
    }

    private func startServices() {
        registry.start()
        // 聊天连接入口：接收端 purpose=chat 的连接交给 ChatChannel。
        transferManager.onChatConnection = { [weak self] link in
            self?.chatChannel.handleIncoming(link)
        }
        do {
            try transferManager.startServer(chatHandler: { [weak self] link in
                self?.chatChannel.handleIncoming(link)
            })
        } catch {
            // 监听失败（例如端口占用）时提示，发现与发送仍可用。
            Task { @MainActor [weak self] in
                self?.notice = CompleteNotice(
                    transferId: newId(), title: "服务启动失败",
                    message: "无法监听 \(TCP_PORT) 端口：\(error.localizedDescription)", success: false
                )
            }
        }
        // TCP 监听就绪后再对外宣告，避免对端发现后立刻建连被拒。
        // 首次启动即处于「本地网络权限未决定」状态；授权弹窗结束后由
        // handleAppActive() / refreshDevices() 重建发现通道。
        discovery.start()
        isDiscovering = true
        scheduleEarlyDiscoveryRetries()
        startLivenessProbe()
        records = recordStore.all
        for device in registry.devices {
            chatManager.registerPeer(id: device.deviceId, name: device.displayName)
        }
    }

    // MARK: - 设备 / 传输动作

    /// 视图层 fileImporter 拿到 URL 后回调，发起发送。
    func sendFiles(_ urls: [URL], to device: Device) {
        guard !device.ip.isEmpty else {
            sendFailure("对方设备不在线，请到设备页刷新后重试")
            return
        }
        chatManager.registerPeer(id: device.deviceId, name: device.displayName)
        Task {
            await transferManager.send(urls: urls, to: device)
            records = recordStore.all
        }
    }

    private func sendFailure(_ message: String) {
        notice = CompleteNotice(
            transferId: newId(), title: "发送失败", message: message, success: false
        )
    }

    func acceptIncoming(_ accept: Bool) {
        transferManager.acceptIncoming(accept)
    }

    func cancelTask(_ taskId: String) {
        transferManager.cancelTask(taskId)
    }

    func deleteRecords(_ ids: Set<String>) {
        recordStore.delete(ids: ids)
        records = recordStore.all
    }

    func openFile(_ path: String) {
        guard !path.isEmpty else { return }
        // iOS 沙盒内文件用系统分享/预览打开。
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let vc = UIApplication.shared.firstKeyWindow?.rootViewController?.topMostViewController
        let interaction = UIDocumentInteractionController(url: url)
        interaction.delegate = DocumentInteractionDelegate.shared
        if let view = vc?.view {
            interaction.presentOpenInMenu(from: CGRect(x: 0, y: 0, width: 1, height: 1), in: view, animated: true)
        }
    }

    /// 传输记录「打开」入口：普通文件在「文件」App 中定位到所在目录，文件夹整包直接打开该文件夹。
    /// App 已开启 UIFileSharingEnabled，Documents 目录在「文件」→「我的 iPhone」→「局域网快传」可见。
    func openContainingFolder(_ path: String, mime: String = "") {
        guard !path.isEmpty else { return }
        let fileURL = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let openItself = mime == "application/x-lantransfer-folder" || (exists && isDirectory.boolValue)
        let targetURL = openItself ? fileURL : fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return }

        // shareddocuments://<沙盒绝对路径> 会让系统「文件」App 打开指定目录（非预览文件本身）。
        guard var components = URLComponents(url: targetURL, resolvingAgainstBaseURL: false) else {
            folderOpenFailedPath = path
            return
        }
        components.scheme = "shareddocuments"
        guard let folderURL = components.url else {
            folderOpenFailedPath = path
            return
        }
        UIApplication.shared.open(folderURL, options: [:]) { [weak self] success in
            guard !success else { return }
            Task { @MainActor [weak self] in
                self?.folderOpenFailedPath = path
            }
        }
    }

    func refreshDevices() {
        // 重建 Bonjour 发布/浏览与 UDP 监听，并立刻广播一次宣告。
        // 用户在系统「本地网络」弹窗点允许后再点刷新即可恢复发现。
        refreshLocalIp()
        discovery.refresh()
        isDiscovering = true
    }

    /// 本地网络权限弹窗消失时，不同 iOS 版本并不保证触发 scenePhase 变化。
    /// 首次启动做两次有界延迟重建，覆盖用户点「允许」的时间窗；
    /// 之后还有 scenePhase 回前台与 ContentView.onAppear 两条触发路径。
    private func scheduleEarlyDiscoveryRetries() {
        // 权限弹窗可能晚于 6 秒才点「允许」，延长有界重建窗口覆盖这一情况。
        for delay in [2.0, 6.0, 12.0, 20.0, 30.0] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.refreshLocalIp()
                self?.discovery.restart()
            }
        }
    }

    // MARK: - 在线状态保活

    /// 每 2 秒对超过 2 秒未收到宣告的设备做一次 TCP 连接探测。
    /// 只要对端 TCP 45211 可连就续期，避免发现通道偶发丢包导致列表清空。
    private func startLivenessProbe() {
        probeTimer?.invalidate()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.probeStaleDevices()
            }
        }
    }

    private func probeStaleDevices() async {
        guard !isProbing else { return }
        isProbing = true
        defer { isProbing = false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let stale = devices.filter { now - $0.lastSeen > 2000 && !$0.ip.isEmpty }
        for device in stale {
            let alive = await probeTcp(host: device.ip, port: device.tcpPort)
            if alive { registry.touch(device.deviceId) }
        }
    }

    private func probeTcp(host: String, port: Int) async -> Bool {
        let resolvedPort = port > 0 ? port : Int(TCP_PORT)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: resolvedPort)) else { return false }
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: nwPort, using: .tcp
        )
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.lantransfer.probe", qos: .utility)
            let lock = NSLock()
            var finished = false
            let complete: (Bool) -> Void = { result in
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                continuation.resume(returning: result)
                connection.cancel()
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: complete(true)
                case .failed, .cancelled: complete(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.0) { complete(false) }
        }
    }

    /// App 回到前台（含本地网络权限弹窗结束）时重建发现通道。
    /// iOS 14+ 权限从「未决定」变为「允许」后，之前创建的 NetServiceBrowser /
    /// NetService / NWListener 不会自动恢复，必须重新创建，否则永久搜不到设备。
    func handleAppActive() {
        refreshLocalIp()
        discovery.restart()
        isDiscovering = true
        for device in registry.devices {
            chatManager.registerPeer(id: device.deviceId, name: device.displayName)
        }
    }

    func updateSettings(_ s: Settings) {
        settingsStore.update(s)
        settings = s
    }

    private func applyAlias() {
        UserDefaults.standard.set(selfDeviceName, forKey: "lantransfer.alias")
    }

    // MARK: - 聊天动作

    func openConversation(_ id: String, peerId: String, peerName: String) {
        activeConversationId = id
        chatManager.registerPeer(id: peerId, name: peerName)
        chatManager.openConversation(id: id, peerName: peerName)
        // 对端设备对象（用于建连）。
        let peer = registry.get(peerId) ?? Device(
            deviceId: peerId, deviceName: peerName, deviceType: .mobile,
            ip: "", platform: "unknown"
        )
        if !peer.ip.isEmpty {
            Task { await chatChannel.sendReadAckForConversation(id: id, to: peer) }
        }
    }

    func sendText(_ text: String) {
        guard let peerId = activePeerId(), let peer = peerDevice(for: peerId) else {
            sendFailure("对方设备不在线或未发现，请到设备页刷新后重试")
            return
        }
        Task {
            let sent = await chatChannel.sendText(text, to: peer)
            if !sent { sendFailure("消息未能送达，请确认对方在线后重试") }
        }
    }

    func sendImage(_ url: URL) {
        guard let peerId = activePeerId(), let peer = peerDevice(for: peerId) else {
            sendFailure("对方设备不在线或未发现，请到设备页刷新后重试")
            return
        }
        Task {
            guard let data = try? Data(contentsOf: url),
                  let imageHash = try? SHA256.hash(data: data).hexString else { return }
            let name = url.lastPathComponent
            let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            let transferId = newId()
            let built = chatManager.makeImageMessage(
                imagePath: url.path, name: name, size: Int64(data.count),
                sha256: imageHash, mime: mime, to: peerId, transferId: transferId
            )
            chatManager.appendOutgoingImage(built.message)
            // 图片字节走文件传输通道（聊天图片 silent accept）；先上线元数据。
            await chatChannel.sendImageMeta(built.payload, to: peer)
            await transferManager.send(
                urls: [url], to: peer, category: .chatImage,
                chatMsgId: built.payload.msgId, forcedTransferId: transferId
            )
        }
    }

    func loadMessages(for id: String) {
        // ChatManager 已在内部维护全量消息；这里触发会话重建。
        chatManager.openConversation(id: id, peerName: chatManager.conversations.first(where: { $0.conversationId == id })?.peerName ?? "")
    }

    private func activePeerId() -> String? {
        guard let id = activeConversationId else { return nil }
        let parts = id.split(separator: "|").map(String.init)
        return parts.first { $0 != selfDeviceId }
    }

    private func peerDevice(for peerId: String) -> Device? {
        if let device = registry.get(peerId), !device.ip.isEmpty { return device }
        return nil
    }

    // MARK: - 工具

    private static func localIPv4() -> String? {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            if flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
               let sockaddrPtr = current.pointee.ifa_addr,
               sockaddrPtr.pointee.sa_family == UInt8(AF_INET) {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                // 关键修复：inet_ntop(AF_INET, ...) 的参数必须指向 4 字节的 in_addr。
                // 旧代码传的是整个 sockaddr（16 字节），实际读取的前 4 字节为
                // [sa_len=16, sa_family=2, sin_port 高 8 位, sin_port 低 8 位]，
                // 恒定得到 16.2.0.0 —— 电脑端按此地址连 45211 必然超时。
                let ip = sockaddrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String? in
                    var sinAddr = sin.pointee.sin_addr
                    guard inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                    return String(cString: buffer)
                }
                if let ip, !ip.hasPrefix("127."), !ip.hasPrefix("169.254."), ip != "0.0.0.0" {
                    addresses.append(ip)
                }
            }
            ptr = current.pointee.ifa_next
        }
        return addresses.first { $0.hasPrefix("192.168.") }
            ?? addresses.first { $0.hasPrefix("10.") }
            ?? addresses.first { $0.hasPrefix("172.") }
            ?? addresses.first
    }

    /// WiFi 切换 / 重连后本机 IP 可能变化，刷新并重建发现通道，
    /// 否则 mDNS TXT 与 UDP 宣告会持续广播旧地址。
    private func refreshLocalIp() {
        guard let ip = Self.localIPv4(), ip != selfDevice.ip else { return }
        selfDevice.ip = ip
        discovery.updateSelfDevice(selfDevice)
        discovery.restart()
    }
}

// MARK: - UIKit 辅助

private extension UIApplication {
    var firstKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

private extension UIViewController {
    var topMostViewController: UIViewController {
        if let presented = presentedViewController { return presented.topMostViewController }
        if let nav = self as? UINavigationController { return nav.visibleViewController?.topMostViewController ?? self }
        if let tab = self as? UITabBarController { return tab.selectedViewController?.topMostViewController ?? self }
        return self
    }
}

private final class DocumentInteractionDelegate: NSObject, UIDocumentInteractionControllerDelegate {
    static let shared = DocumentInteractionDelegate()
}
