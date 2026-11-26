//
//  ChunkPlanner.swift
//  局域网快传
//
//  分块计划：把大文件逻辑切分为固定大小块，计算断点续传缺失块。
//  与 desktop ChunkPlanner.ts / Android ChunkPlanner.kt 逐项对齐。
//

import Foundation

struct FileChunk {
    var index: Int
    var offset: Int64
    var length: Int
    var crc32: UInt32 = 0
}

enum ChunkPlanner {
    static func normalizeChunkSize(_ chunkSize: Int) -> Int {
        guard chunkSize > 0 else { return DEFAULT_CHUNK_SIZE }
        return min(MAX_CHUNK_SIZE, max(MIN_CHUNK_SIZE, chunkSize))
    }

    /// 校验文件大小合法（Int64 且 ≥0）。
    static func assertSafeSize(_ size: Int64) throws {
        guard size >= 0 else { throw FrameError.invalidFrame("文件大小非法: \(size)") }
    }

    static func totalChunks(_ size: Int64, chunkSize: Int = DEFAULT_CHUNK_SIZE) -> Int {
        guard size > 0 else { return 0 }
        let normalized = normalizeChunkSize(chunkSize)
        return Int((size + Int64(normalized) - 1) / Int64(normalized))
    }

    static func offsetOf(_ index: Int, chunkSize: Int) -> Int64 {
        Int64(index) * Int64(chunkSize)
    }

    static func lengthOf(_ index: Int, fileSize: Int64, chunkSize: Int) -> Int {
        let offset = offsetOf(index, chunkSize: chunkSize)
        return Int(min(Int64(chunkSize), fileSize - offset))
    }

    /// 返回尚未完成的块索引（升序）。
    static func missingChunks(done: some Sequence<Int>, total: Int) -> [Int] {
        let doneSet = Set(done)
        return (0..<total).filter { !doneSet.contains($0) }
    }
}
