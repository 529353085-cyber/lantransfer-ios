//
//  TransferRecordStore.swift
//  局域网快传
//
//  传输记录持久化（JSON 文件，位于 App 沙盒 Application Support）。
//  与桌面 better-sqlite3 / Android Room 的 TransferRecord 字段一致。
//

import Foundation

final class TransferRecordStore {
    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [TransferRecord]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LanTransfer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("transfer-records.json", isDirectory: false)
        self.cache = Self.load(from: fileURL)
    }

    private static func load(from url: URL) -> [TransferRecord] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([TransferRecord].self, from: data) else { return [] }
        return list
    }

    /// 当前记录（按时间倒序）。
    var all: [TransferRecord] {
        lock.lock(); defer { lock.unlock() }
        return cache.sorted { $0.timestamp > $1.timestamp }
    }

    func add(_ record: TransferRecord) {
        lock.lock()
        cache.append(record)
        persistLocked()
        lock.unlock()
    }

    func add(_ records: [TransferRecord]) {
        guard !records.isEmpty else { return }
        lock.lock()
        cache.append(contentsOf: records)
        persistLocked()
        lock.unlock()
    }

    func delete(ids: Set<String>) {
        lock.lock()
        cache.removeAll { ids.contains($0.recordId) }
        persistLocked()
        lock.unlock()
    }

    func clear() {
        lock.lock()
        cache.removeAll()
        persistLocked()
        lock.unlock()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
