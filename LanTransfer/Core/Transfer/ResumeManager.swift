//
//  ResumeManager.swift
//  章鱼快传
//
//  断点续传位图：记录每个块是否已落盘。格式与三端完全一致：
//  [4B magic=BIT1][4B chunkSize BE][4B totalChunks BE][totalChunks 字节 0/1]
//

import Foundation

struct BitmapState {
    var chunkSize: Int
    var totalChunks: Int
    var done: [Bool]
}

enum ResumeManager {
    static func bitmapPath(for partPath: URL) -> URL {
        URL(fileURLWithPath: partPath.path + ".bitmap", isDirectory: false)
    }

    /// 读取位图。文件不存在或格式非法时返回 nil（视为全新传输）。
    static func read(partPath: URL) -> BitmapState? {
        let path = bitmapPath(for: partPath).path
        guard let data = FileManager.default.contents(atPath: path), data.count >= BITMAP_HEADER_BYTES else {
            return nil
        }
        guard BE.u32(data, at: 0) == MAGIC_BITMAP else { return nil }
        let chunkSize = Int(BE.u32(data, at: 4))
        let totalChunks = Int(BE.u32(data, at: 8))
        guard chunkSize > 0, totalChunks > 0, data.count == BITMAP_HEADER_BYTES + totalChunks else {
            return nil
        }
        var done: [Bool] = []
        done.reserveCapacity(totalChunks)
        for i in 0..<totalChunks {
            done.append(data[BITMAP_HEADER_BYTES + i] == 1)
        }
        return BitmapState(chunkSize: chunkSize, totalChunks: totalChunks, done: done)
    }

    /// 写入位图并 fsync。先写临时文件再原子替换，避免崩溃产生半截位图。
    static func write(_ state: BitmapState, partPath: URL) throws {
        var data = Data()
        data.reserveCapacity(BITMAP_HEADER_BYTES + state.done.count)
        data.append(BE.u32(MAGIC_BITMAP))
        data.append(BE.u32(UInt32(state.chunkSize)))
        data.append(BE.u32(UInt32(state.totalChunks)))
        for flag in state.done {
            data.append(flag ? 1 : 0)
        }
        let target = bitmapPath(for: partPath)
        let temp = URL(fileURLWithPath: target.path + ".tmp", isDirectory: false)
        try data.write(to: temp, options: .atomic)
        // fsync 位图，确保崩溃最多丢最后一块标记。
        if let handle = try? FileHandle(forWritingTo: temp) {
            try? handle.synchronize()
            try? handle.close()
        }
        // 原子替换
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temp, to: target)
    }

    /// 读取已完成块索引。
    static func doneChunks(partPath: URL) -> [Int] {
        guard let state = read(partPath: partPath) else { return [] }
        return state.done.enumerated().compactMap { $0.element ? $0.offset : nil }
    }

    /// 删除位图（校验通过后）。
    static func remove(partPath: URL) {
        try? FileManager.default.removeItem(at: bitmapPath(for: partPath))
    }
}
