//
//  FrameCodec.swift
//  章鱼快传
//
//  控制帧（4B 长度前缀 + UTF-8 JSON）与数据帧（20B 定长头 + 裸流）编解码。
//  与 desktop/core/protocol/FrameCodec.ts、Android FrameCodec.kt 完全一致。
//

import Foundation

/// 数据帧 20 字节头。
struct DataHeader {
    var cmd: UInt32
    var transferKey: UInt32
    var chunkIndex: UInt32
    var chunkLen: UInt32
    var crc32: UInt32
}

/// 帧读写错误。
enum FrameError: Error, LocalizedError {
    case invalidFrame(String)
    case timeout(String)
    case closed
    case socket(String)

    var errorDescription: String? {
        switch self {
        case .invalidFrame(let message): return "INVALID_FRAME: \(message)"
        case .timeout(let message): return message
        case .closed: return "连接已关闭"
        case .socket(let message): return message
        }
    }
}

/// 大端整数读写辅助（与三端 big-endian 约定一致）。
enum BE {
    static func u32(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4)
    }

    static func u32(_ data: Data, at offset: Int) -> UInt32 {
        let slice = data.subdata(in: offset..<(offset + 4))
        return slice.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        }
    }
}

enum FrameCodec {
    /// 编码控制帧：[4B length BE][N B JSON]。
    static func encode(_ envelope: ProtocolEnvelope) throws -> Data {
        let json = try ProtocolJson.encoder.encode(envelope)
        guard json.count <= CONTROL_MAX_FRAME_BYTES else {
            throw FrameError.invalidFrame("控制帧过大: \(json.count) > \(CONTROL_MAX_FRAME_BYTES)")
        }
        var out = Data()
        out.append(BE.u32(UInt32(json.count)))
        out.append(json)
        return out
    }

    /// 便捷构造消息并编码。
    static func encodeMessage<P: Encodable>(_ type: MessageType, _ payload: P) throws -> Data {
        try encode(createEnvelope(type, payload))
    }

    /// 解码控制帧 JSON 为信封。
    static func decodeEnvelope(_ jsonData: Data) throws -> ProtocolEnvelope {
        let envelope = try ProtocolJson.decoder.decode(ProtocolEnvelope.self, from: jsonData)
        guard envelope.v == PROTOCOL_VERSION else {
            throw FrameError.invalidFrame("不支持的协议版本 \(envelope.v)")
        }
        return envelope
    }

    /// 编码数据帧头（20B，全 big-endian）。
    static func encodeDataHeader(_ header: DataHeader) -> Data {
        var out = Data()
        out.reserveCapacity(DATA_HEADER_BYTES)
        out.append(BE.u32(header.cmd))
        out.append(BE.u32(header.transferKey))
        out.append(BE.u32(header.chunkIndex))
        out.append(BE.u32(header.chunkLen))
        out.append(BE.u32(header.crc32))
        return out
    }

    /// 从 20 字节解析数据帧头并校验魔数。
    static func decodeDataHeader(_ data: Data) throws -> DataHeader {
        guard data.count >= DATA_HEADER_BYTES else {
            throw FrameError.invalidFrame("数据帧头不足 20 字节")
        }
        let header = DataHeader(
            cmd: BE.u32(data, at: 0),
            transferKey: BE.u32(data, at: 4),
            chunkIndex: BE.u32(data, at: 8),
            chunkLen: BE.u32(data, at: 12),
            crc32: BE.u32(data, at: 16)
        )
        guard header.cmd == MAGIC_DATA else {
            throw FrameError.invalidFrame(String(format: "非法数据帧魔数 0x%X", header.cmd))
        }
        return header
    }
}
