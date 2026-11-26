//
//  ChecksumUtil.swift
//  局域网快传
//
//  完整性校验：文件级 SHA-256（CryptoKit）与块级 CRC32（IEEE 802.3）。
//  CRC32 实现必须与桌面端 slice-by-8 / Android CRC32 逐向量一致：
//  反射多项式 0xEDB88320，初值 0xFFFFFFFF，终值异或 0xFFFFFFFF，结果无符号 32 位。
//

import Foundation
import CryptoKit

/// IEEE 802.3 CRC32（反射多项式 0xEDB88320）。
/// 采用 slice-by-8 并行查表，与桌面 ChecksumUtil.ts 的纯 JS 降级路径同源，
/// 保证与桌面原生 zlib.crc32、Android java.util.zip.CRC32 三者结果一致。
enum CRC32 {
    /// 8 张递推表，与桌面 buildCrcTables() 完全相同的构造方式。
    private static let tables: [[UInt32]] = buildTables()

    private static func buildTables() -> [[UInt32]] {
        var all: [[UInt32]] = [Array(repeating: 0, count: 256)]
        for n in 0..<256 {
            var value = UInt32(n)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            all[0][n] = value
        }
        for k in 1..<8 {
            var current = Array(repeating: UInt32(0), count: 256)
            let previous = all[k - 1]
            for x in 0..<256 {
                let value = previous[x]
                current[x] = all[0][Int(value & 0xFF)] ^ (value >> 8)
            }
            all.append(current)
        }
        return all
    }

    /// 计算一块数据的 CRC32（无符号 32 位，值域 0~4294967295）。
    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        var index = 0
        let count = bytes.count
        while index + 8 <= count {
            let b0 = UInt32(bytes[index])
            let b1 = UInt32(bytes[index + 1])
            let b2 = UInt32(bytes[index + 2])
            let b3 = UInt32(bytes[index + 3])
            let b4 = UInt32(bytes[index + 4])
            let b5 = UInt32(bytes[index + 5])
            let b6 = UInt32(bytes[index + 6])
            let b7 = UInt32(bytes[index + 7])
            crc = tables[7][Int((crc ^ b0) & 0xFF)]
                ^ tables[6][Int(((crc >> 8) ^ b1) & 0xFF)]
                ^ tables[5][Int(((crc >> 16) ^ b2) & 0xFF)]
                ^ tables[4][Int(((crc >> 24) ^ b3) & 0xFF)]
                ^ tables[3][Int(b4)]
                ^ tables[2][Int(b5)]
                ^ tables[1][Int(b6)]
                ^ tables[0][Int(b7)]
            index += 8
        }
        while index < count {
            crc = tables[0][Int((crc ^ UInt32(bytes[index])) & 0xFF)] ^ (crc >> 8)
            index += 1
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in checksum(raw) }
    }
}

enum ChecksumUtil {
    /// 流式计算文件 SHA-256，内存占用与文件大小无关（支持 ≥2GB）。
    static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: DISK_IO_BUFFER_SIZE) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }

    /// 计算一组块的 CRC32 映射（key = chunkIndex 字符串，值为无符号 32 位）。
    static func crcMap(forChunks chunks: [Data]) -> [String: UInt64] {
        var map: [String: UInt64] = [:]
        for (index, chunk) in chunks.enumerated() {
            map[String(index)] = UInt64(CRC32.checksum(chunk))
        }
        return map
    }
}

extension Digest {
    /// 十六进制小写摘要（与三端 digest('hex') 一致）。
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
