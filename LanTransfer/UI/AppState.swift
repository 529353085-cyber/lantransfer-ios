//
//  AppState.swift
//  局域网快传
//
//  全局界面状态容器 + 依赖装配。所有视图通过 @EnvironmentObject 读取状态、调用动作。
//  这里把 Core 层（发现/传输/聊天/存储）与视图绑定起来。
//

import SwiftUI
import Combine
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

    @Published var conversations: [ConversationSummary] = []
    @Published var chatMessages: [ChatMessage] = []
    @Published var activeConversationId: String? = nil

    /// 本机设备 id（稳定持久化）。
    let selfDeviceId: String
    private let selfDevice: Device

    // MARK: - Core 依赖
    private let registry: DeviceRegistry
    private let discovery: DiscoveryManager
    private let recordStore: TransferRecordStore
    private let settingsStore: SettingsStore
    private let chatManager: ChatManager
    private let transferManager: TransferManager
    private let chatChannel: ChatChannel
    private var cancellables = Set<AnyCancellable>()

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
        discovery.start()
        isDiscovering = true
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
        records = recordStore.all
        for device in registry.devices {
            chatManager.registerPeer(id: device.deviceId, name: device.displayName)
        }
    }

    // MARK: - 设备 / 传输动作

    /// 视图层 fileImporter 拿到 URL 后回调，发起发送。
    func sendFiles(_ urls: [URL], to device: Device) {
        chatManager.registerPeer(id: device.deviceId, name: device.displayName)
        Task {
            await transferManager.send(urls: urls, to: device)
            records = recordStore.all
        }
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

    func refreshDevices() {
        isDiscovering = true
        // Bonjour 浏览是持续性的；这里主动发一次 UDP 宣告，加快互相发现。
        // DiscoveryManager 内部定时器已周期广播，此处仅更新 UI 状态。
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
        guard let peerId = activePeerId(), let peer = peerDevice(for: peerId) else { return }
        Task { await chatChannel.sendText(text, to: peer) }
    }

    func sendImage(_ url: URL) {
        guard let peerId = activePeerId(), let peer = peerDevice(for: peerId) else { return }
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
               current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
                var addr = current.pointee.ifa_addr!.pointee
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buffer)
                    if !ip.hasPrefix("127.") { addresses.append(ip) }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return addresses.first { $0.hasPrefix("192.168.") } ?? addresses.first
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
