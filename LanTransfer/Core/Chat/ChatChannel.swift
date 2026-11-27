//
//  ChatChannel.swift
//  局域网快传
//
//  聊天连接管理：每条会话一条 purpose='chat' 的控制连接，复用 HELLO/信封帧。
//  与桌面 ChatChannel.ts / Android ChatManager 的聊天连接语义对齐：
//  连接建立后循环读 CHAT_MESSAGE / CHAT_IMAGE / CHAT_ACK / PONG。
//

import Foundation

@MainActor
final class ChatChannel {
    private var connections: [String: TcpConnection] = [:]   // peerId -> 连接
    private let selfDevice: Device
    private let chatManager: ChatManager
    private let onIncomingImage: (ChatImagePayload) -> Void

    init(selfDevice: Device, chatManager: ChatManager, onIncomingImage: @escaping (ChatImagePayload) -> Void) {
        self.selfDevice = selfDevice
        self.chatManager = chatManager
        self.onIncomingImage = onIncomingImage
    }

    /// 处理被动接受的聊天连接（对端主动连入，purpose=chat）。
    /// 与主动连接共用读循环语义，但不放入 connections（避免与主动连接混淆）。
    func handleIncoming(_ link: TcpConnection) {
        Task { [weak self] in
            await self?.readLoop(link: link, peerId: link.hello?.deviceId ?? "")
        }
    }

    /// 获取（或建立）到对端的聊天连接。
    private func connection(to peer: Device) async throws -> TcpConnection {
        if let existing = connections[peer.deviceId] {
            return existing
        }
        let link = try await connectTcp(
            host: peer.ip, port: UInt16(peer.tcpPort > 0 ? peer.tcpPort : Int(TCP_PORT)),
            channel: .control, purpose: "chat",
            deviceId: selfDevice.deviceId, features: ["CHAT"]
        )
        connections[peer.deviceId] = link
        // 启动接收循环。
        Task { [weak self] in
            await self?.readLoop(link: link, peerId: peer.deviceId)
        }
        return link
    }

    private func readLoop(link: TcpConnection, peerId: String) async {
        while true {
            do {
                let env = try await link.reader.readFrame()
                switch env.type {
                case .chatMessage:
                    if let payload = try? decodePayload(env, as: ChatMessagePayload.self) {
                        chatManager.receiveText(payload)
                        // 回 DELIVERED 回执。
                        try? await link.sendMessage(.chatAck, ChatAckPayload(
                            msgId: payload.msgId, state: "DELIVERED",
                            fromDeviceId: selfDevice.deviceId,
                            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
                        ))
                    }
                case .chatImage:
                    if let payload = try? decodePayload(env, as: ChatImagePayload.self) {
                        chatManager.receiveImageMeta(payload)
                        onIncomingImage(payload)
                        try? await link.sendMessage(.chatAck, ChatAckPayload(
                            msgId: payload.msgId, state: "DELIVERED",
                            fromDeviceId: selfDevice.deviceId,
                            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
                        ))
                    }
                case .chatAck:
                    if let ack = try? decodePayload(env, as: ChatAckPayload.self) {
                        chatManager.applyAck(msgId: ack.msgId, state: ack.state)
                    }
                case .ping:
                    try? await link.sendMessage(.pong, PingPayload(ts: Int64(Date().timeIntervalSince1970 * 1000)))
                default:
                    break
                }
            } catch {
                break
            }
        }
        connections[peerId] = nil
        link.close()
    }

    /// 发送文本消息（先落本地，再上线）。
    func sendText(_ text: String, to peer: Device) async {
        let payload = chatManager.makeTextMessage(text: text, to: peer.deviceId)
        chatManager.appendOutgoingText(payload)
        guard let link = try? await connection(to: peer) else { return }
        try? await link.sendMessage(.chatMessage, payload)
    }

    /// 发送图片元数据（图片字节由 TransferManager 走文件传输通道）。
    func sendImageMeta(_ payload: ChatImagePayload, to peer: Device) async {
        guard let link = try? await connection(to: peer) else { return }
        try? await link.sendMessage(.chatImage, payload)
    }

    /// 打开会话时发送 READ 回执。
    func sendReadAck(msgId: String, from peer: Device) async {
        guard let link = try? await connection(to: peer) else { return }
        try? await link.sendMessage(.chatAck, ChatAckPayload(
            msgId: msgId, state: "READ", fromDeviceId: selfDevice.deviceId,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    /// 打开会话时对该会话全部未读消息批量发 READ 回执。
    func sendReadAckForConversation(id: String, to peer: Device) async {
        guard let link = try? await connection(to: peer) else { return }
        let unreadIds = await chatManager.unreadMessageIds(in: id)
        for msgId in unreadIds {
            try? await link.sendMessage(.chatAck, ChatAckPayload(
                msgId: msgId, state: "READ", fromDeviceId: selfDevice.deviceId,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            ))
        }
    }

    func closeAll() {
        connections.values.forEach { $0.close() }
        connections.removeAll()
    }
}
