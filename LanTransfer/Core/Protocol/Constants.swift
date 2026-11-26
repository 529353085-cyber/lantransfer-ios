//
//  Constants.swift
//  局域网快传
//
//  跨端共享协议常量 —— 与 shared/protocol/constants.yaml、
//  desktop/core/protocol/constants.ts、Android ProtocolConstants.kt 逐项对齐。
//  本文件为纯数据模块，不依赖任何 iOS 框架。
//
//  重要：任何改动必须同步更新上述三处，否则会破坏桌面/Android/iOS 三端互通。
//

import Foundation

/// 协议版本，对应消息信封的 v 字段。
let PROTOCOL_VERSION: Int = 1

/// 主校验算法 / 兼容算法。
let HASH_ALGO = "sha256"
let HASH_ALGO_COMPAT = "md5"

/// UDP 发现端口与广播地址。
let UDP_DISCOVERY_PORT: UInt16 = 45210
let UDP_BROADCAST_ADDR = "255.255.255.255"

/// TCP 控制连接与数据连接共用端口。
let TCP_PORT: UInt16 = 45211

/// mDNS 组播参数与服务类型。
let MDNS_GROUP = "224.0.0.251"
let MDNS_PORT: UInt16 = 5353
let SERVICE_TYPE = "_lantransfer._tcp"

/// 控制帧：4 字节 uint32 BE 长度前缀。
let CONTROL_LENGTH_PREFIX_BYTES = 4
let CONTROL_MAX_FRAME_BYTES = 1024 * 1024

/// 数据帧命令字 0x44415431 ("DAT1") 与 20 字节定长头。
let MAGIC_DATA: UInt32 = 0x44415431
let DATA_HEADER_BYTES = 20

/// 断点位图魔数 0x42495431 ("BIT1") 与 12 字节定长头。
let MAGIC_BITMAP: UInt32 = 0x42495431
let BITMAP_HEADER_BYTES = 12

/// 分块参数。
let DEFAULT_CHUNK_SIZE = 4 * 1024 * 1024
let MIN_CHUNK_SIZE = 1 * 1024 * 1024
let MAX_CHUNK_SIZE = 16 * 1024 * 1024
let DEFAULT_CONCURRENCY = 4
let MIN_CONCURRENCY = 1
let MAX_CONCURRENCY = 8
/// 协议约定的流式缓冲（64KB），跨端共享语义，不可擅自改动。
let BUFFER_SIZE = 64 * 1024
/// iOS 本地磁盘 I/O 缓冲（256KB），与桌面端 DISK_IO_BUFFER_SIZE 对齐（非线格式常量）。
let DISK_IO_BUFFER_SIZE = 256 * 1024
let PROGRESS_THROTTLE_MS = 200

/// 超时（毫秒）。
let DISCOVER_INTERVAL_MS: Int64 = 2000
let DEVICE_TIMEOUT_MS: Int64 = 6000
let HEARTBEAT_INTERVAL_MS: Int64 = 5000
let CONN_TIMEOUT_MS: Int64 = 15000
let CONNECT_TIMEOUT_MS: Int64 = 5000
let DATA_RW_TIMEOUT_MS: Int64 = 30000
let ACCEPT_TIMEOUT_MS: Int64 = 60000

/// R-001：VERIFY_REQUEST 判定 pending 前的有界宽限参数。
let VERIFY_GRACE_MS: Int64 = 800
let VERIFY_POLL_INTERVAL_MS: Int64 = 50
/// 宽限轮询绝对硬上限（2 分钟）。
let VERIFY_MAX_WAIT_MS: Int64 = 2 * 60 * 1000

/// 等待接收端 FIN 的预算按块长自适应（与桌面端一致）。
let MIN_PEER_ACK_BYTES_PER_SEC: Int64 = 128 * 1024
let MAX_PEER_ACK_WAIT_MS: Int64 = 10 * 60 * 1000

/// 重试上限。
let MAX_RETRY = 3
let MAX_VERIFY_ROUNDS = 3

/// 聊天常量。
let CHAT_ACK_TIMEOUT_MS: Int64 = 10_000
let CHAT_MAX_TEXT_CHARS = 2000
let CHAT_MAX_IMAGE_BYTES = 20 * 1024 * 1024
let CHAT_PENDING_MAX = 200
let CHAT_PENDING_TTL_MS: Int64 = 7 * 24 * 60 * 60 * 1000
let CHAT_KEEPALIVE_MS: Int64 = 30_000
let CHAT_IMAGE_SUBDIR = "chat-images"

/// 设备类型（与三端字符串值一致）。
enum DeviceType: String, Codable {
    case desktop = "DESKTOP"
    case mobile = "MOBILE"
}

/// 传输任务状态。
enum TaskStatus: String, Codable {
    case pending = "PENDING"
    case accepted = "ACCEPTED"
    case transferring = "TRANSFERRING"
    case verifying = "VERIFYING"
    case success = "SUCCESS"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    case rejected = "REJECTED"
}

/// 传输方向。
enum Direction: String, Codable {
    case send = "SEND"
    case receive = "RECEIVE"
}

/// 控制层消息类型（与 message-types.json 完全一致）。
/// 未知类型解析为 .unknown 哨兵，路由时忽略不崩溃（协议 v1 兼容要求：旧端忽略未知消息）。
enum MessageType: String, Codable {
    case hello = "HELLO"
    case helloAck = "HELLO_ACK"
    case transferRequest = "TRANSFER_REQUEST"
    case transferAccept = "TRANSFER_ACCEPT"
    case transferReject = "TRANSFER_REJECT"
    case resumeQuery = "RESUME_QUERY"
    case resumeResponse = "RESUME_RESPONSE"
    case chunkPlan = "CHUNK_PLAN"
    case progress = "PROGRESS"
    case verifyRequest = "VERIFY_REQUEST"
    case verifyResult = "VERIFY_RESULT"
    case resendChunk = "RESEND_CHUNK"
    case transferComplete = "TRANSFER_COMPLETE"
    case transferFailed = "TRANSFER_FAILED"
    case transferCancel = "TRANSFER_CANCEL"
    case ping = "PING"
    case pong = "PONG"
    case chatMessage = "CHAT_MESSAGE"
    case chatImage = "CHAT_IMAGE"
    case chatAck = "CHAT_ACK"

    /// 内部哨兵：仅用于解码未知类型，永不编码上线。
    case unknown = "__UNKNOWN__"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageType(rawValue: raw) ?? .unknown
    }
}

/// 错误码（与三端一致）。
enum ErrorCode: String, Codable {
    case userRejected = "USER_REJECTED"
    case userTimeout = "USER_TIMEOUT"
    case hashMismatch = "HASH_MISMATCH"
    case connLost = "CONN_LOST"
    case diskFull = "DISK_FULL"
    case cancelled = "CANCELLED"
    case crcMismatch = "CRC_MISMATCH"
    case invalidFrame = "INVALID_FRAME"
    case peerOffline = "PEER_OFFLINE"
}

/// 发现层消息类型（UDP 广播，独立于控制层信封）。
enum DiscoveryMessageType: String, Codable {
    case announce = "DISCOVER_ANNOUNCE"
    case bye = "DISCOVER_BYE"
}

/// 数据连接首帧的 channel 值。
enum Channel: String, Codable {
    case control = "control"
    case data = "data"
}

/// 传输分类。
enum TransferCategory: String, Codable {
    case normal = "NORMAL"
    case chatImage = "CHAT_IMAGE"
}

/// 由 UUID v4 的 transferId 派生数据帧中的 uint32 transferKey。
/// 规则：去掉连字符后取前 8 位十六进制字符，big-endian 解析。
/// 与桌面 toTransferKey / Android 等价实现逐字一致。
func toTransferKey(_ transferId: String) -> UInt32 {
    let hex = String(transferId.filter { $0 != "-" }.prefix(8))
    guard hex.count == 8, hex.allSatisfy({ $0.isHexDigit }) else {
        return 0
    }
    return UInt32(hex, radix: 16) ?? 0
}

/// 生成 UUID v4 字符串（统一入口）。
func newId() -> String {
    UUID().uuidString
}
