//
//  ChatMessageStore.swift
//  章鱼快传
//
//  聊天消息持久化（JSON 文件）。字段与桌面 ChatMessageRepo / Android ChatMessageDao 对齐。
//

import Foundation

final class ChatMessageStore {
    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [ChatMessage]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LanTransfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("chat-messages.json", isDirectory: false)
        self.cache = Self.load(from: fileURL)
    }

    private static func load(from url: URL) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return [] }
        return list
    }

    var all: [ChatMessage] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    func contains(msgId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cache.contains { $0.msgId == msgId }
    }

    func add(_ message: ChatMessage) {
        lock.lock()
        if !cache.contains(where: { $0.msgId == message.msgId }) {
            cache.append(message)
            persistLocked()
        }
        lock.unlock()
    }

    func replaceAll(_ list: [ChatMessage]) {
        lock.lock()
        cache = list
        persistLocked()
        lock.unlock()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
