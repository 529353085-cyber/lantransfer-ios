//
//  ChatManager.swift
//  章鱼快传
//
//  局域网聊天：文本 / 图片消息的发送、接收、已读回执、会话管理与持久化。
//  协议 v1 纯追加：CHAT_MESSAGE / CHAT_IMAGE / CHAT_ACK 三类消息，
//  聊天连接走独立控制连接（HELLO.purpose='chat'）。与桌面/Android ChatManager 对齐。
//

import Foundation
import Combine

@MainActor
final class ChatManager: ObservableObject {
    @Published var messages: [String: [ChatMessage]] = [:]   // conversationId -> 消息列表
    @Published var conversations: [ConversationSummary] = []
    @Published var activeConversationId: String?

    private let selfId: String
    private let selfName: String
    private let store: ChatMessageStore
    private var imageTransferIds: [String: String] = [:]    // msgId -> transferId（等待对方回写）
    /// 图片已完成但元数据尚未到达时的待回写缓存：msgId -> (transferId, localPath)。
    private var pendingImagePaths: [String: (String, String)] = [:]
    private let lock = NSLock()

    init(selfId: String, selfName: String, store: ChatMessageStore) {
        self.selfId = selfId
        self.selfName = selfName
        self.store = store
        loadFromStore()
    }

    private func loadFromStore() {
        let all = store.all
        var grouped: [String: [ChatMessage]] = [:]
        for msg in all {
            grouped[msg.conversationId, default: []].append(msg)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.timestamp < $1.timestamp }
        }
        messages = grouped
        rebuildConversations()
    }

    /// 会话 id = sorted([from,to]).join('|')。
    static func conversationId(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "|")
    }

    // MARK: - 会话

    func openConversation(id: String, peerName: String) {
        activeConversationId = id
        // 打开会话即标记已读：清除未读角标（与桌面 chatStore.openConversation 一致）。
        var list = store.all
        var changed = false
        for i in list.indices where list[i].conversationId == id && list[i].state != "READ" {
            list[i].state = "READ"
            changed = true
        }
        if changed {
            store.replaceAll(list)
            messages[id] = list.filter { $0.conversationId == id }.sorted { $0.timestamp < $1.timestamp }
        }
        rebuildConversations()
    }

    /// 指定会话中尚未读的消息 id（发 READ 回执用）。
    func unreadMessageIds(in convId: String) async -> [String] {
        store.all.filter { $0.conversationId == convId && !$0.outgoing && $0.state != "READ" }.map(\.msgId)
    }

    private func rebuildConversations() {
        var summaries: [ConversationSummary] = []
        for (convId, msgs) in messages {
            guard let last = msgs.last else { continue }
            let peerId = last.outgoing ? last.toDeviceId : last.fromDeviceId
            let peerName = last.outgoing ? (peerNameCache[peerId] ?? peerId) : (peerNameCache[peerId] ?? peerId)
            let unread = convId == activeConversationId ? 0 : msgs.filter { !$0.outgoing && $0.state != "READ" }.count
            let lastText = last.kind == "IMAGE" ? "[图片]" : last.text
            summaries.append(ConversationSummary(
                conversationId: convId, peerId: peerId, peerName: peerName,
                lastText: lastText, lastTs: last.timestamp, unread: unread
            ))
        }
        conversations = summaries.sorted { $0.lastTs > $1.lastTs }
    }

    private var peerNameCache: [String: String] = [:]
    func registerPeer(id: String, name: String) {
        peerNameCache[id] = name
        rebuildConversations()
    }

    // MARK: - 接收消息（由网络层调用）

    func receiveText(_ payload: ChatMessagePayload) {
        // 去重：同一 msgId 不重复落库。
        guard !store.contains(msgId: payload.msgId) else { return }
        let msg = ChatMessage(
            msgId: payload.msgId, fromDeviceId: payload.fromDeviceId,
            toDeviceId: payload.toDeviceId, conversationId: payload.conversationId,
            kind: "TEXT", text: String(payload.text.prefix(CHAT_MAX_TEXT_CHARS)),
            timestamp: payload.timestamp, state: "DELIVERED", outgoing: false
        )
        append(msg)
    }

    func receiveImageMeta(_ payload: ChatImagePayload) -> (name: String, sha256: String, mime: String)? {
        guard !store.contains(msgId: payload.msgId) else { return nil }
        let msg = ChatMessage(
            msgId: payload.msgId, fromDeviceId: payload.fromDeviceId,
            toDeviceId: payload.toDeviceId, conversationId: payload.conversationId,
            kind: "IMAGE", timestamp: payload.timestamp, state: "DELIVERED", outgoing: false,
            imageName: payload.image.name, transferId: payload.transferId
        )
        append(msg)
        // 若图片传输已完成但元数据迟到，补写此前缓存的路径。
        lock.lock()
        let pending = pendingImagePaths.removeValue(forKey: payload.msgId)
        lock.unlock()
        if let pending = pending {
            update(msgId: payload.msgId) { item in
                item.imagePath = pending.1
                item.transferId = pending.0
            }
        }
        return (payload.image.name, payload.image.sha256, payload.image.mime)
    }

    /// 图片传输完成后回写本地路径（规避控制消息与传输完成到达的竞态）。
    func markImageReceived(msgId: String, transferId: String, localPath: String) {
        // 消息可能尚未到达，先缓存；元数据到达时补写。
        if !store.contains(msgId: msgId) {
            lock.lock(); pendingImagePaths[msgId] = (transferId, localPath); lock.unlock()
            return
        }
        update(msgId: msgId) { msg in
            msg.imagePath = localPath
            msg.transferId = transferId
        }
    }

    func markImageSent(msgId: String, transferId: String) {
        update(msgId: msgId) { msg in
            msg.transferId = transferId
            msg.state = "DELIVERED"
        }
    }

    func applyAck(msgId: String, state: String) {
        update(msgId: msgId) { msg in
            if msg.state != "READ" { msg.state = state }
        }
    }

    func pendingImageTransferId(msgId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return imageTransferIds[msgId]
    }

    func rememberImageTransfer(msgId: String, transferId: String) {
        lock.lock(); imageTransferIds[msgId] = transferId; lock.unlock()
    }

    // MARK: - 发送消息构造（由 UI 调用，网络层负责实际发送）

    func makeTextMessage(text: String, to peerId: String) -> ChatMessagePayload {
        let trimmed = String(text.prefix(CHAT_MAX_TEXT_CHARS))
        return ChatMessagePayload(
            msgId: newId(), fromDeviceId: selfId, toDeviceId: peerId,
            conversationId: ChatManager.conversationId(selfId, peerId),
            kind: "TEXT", text: trimmed,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    func makeImageMessage(imagePath: String, name: String, size: Int64, sha256: String, mime: String, to peerId: String, transferId: String) -> (payload: ChatImagePayload, message: ChatMessage) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let msgId = newId()
        let payload = ChatImagePayload(
            msgId: msgId, fromDeviceId: selfId, toDeviceId: peerId,
            conversationId: ChatManager.conversationId(selfId, peerId),
            kind: "IMAGE", transferId: transferId,
            image: ChatImageMeta(name: name, size: size, sha256: sha256, mime: mime),
            timestamp: now
        )
        let message = ChatMessage(
            msgId: msgId, fromDeviceId: selfId, toDeviceId: peerId,
            conversationId: payload.conversationId, kind: "IMAGE",
            timestamp: now, state: "DELIVERED", outgoing: true,
            imagePath: imagePath, imageName: name, transferId: transferId
        )
        return (payload, message)
    }

    /// 把发出的文本消息落到本地（发送成功后由网络层调用）。
    func appendOutgoingText(_ payload: ChatMessagePayload) {
        let msg = ChatMessage(
            msgId: payload.msgId, fromDeviceId: payload.fromDeviceId,
            toDeviceId: payload.toDeviceId, conversationId: payload.conversationId,
            kind: "TEXT", text: payload.text, timestamp: payload.timestamp,
            state: "DELIVERED", outgoing: true
        )
        append(msg)
    }

    func appendOutgoingImage(_ message: ChatMessage) { append(message) }

    // MARK: - 内部

    private func append(_ msg: ChatMessage) {
        store.add(msg)
        messages[msg.conversationId, default: []].append(msg)
        messages[msg.conversationId]?.sort { $0.timestamp < $1.timestamp }
        rebuildConversations()
    }

    private func update(msgId: String, _ transform: (inout ChatMessage) -> Void) {
        var list = store.all
        guard let index = list.firstIndex(where: { $0.msgId == msgId }) else { return }
        transform(&list[index])
        store.replaceAll(list)
        let convId = list[index].conversationId
        messages[convId] = list.filter { $0.conversationId == convId }.sorted { $0.timestamp < $1.timestamp }
        rebuildConversations()
    }
}
