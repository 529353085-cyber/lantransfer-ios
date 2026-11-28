//
//  Messages.swift
//  局域网快传
//
//  控制层消息信封、跨端共享领域模型与编解码。
//  字段与 desktop/core/protocol/messages.ts、Android Messages.kt 逐一对齐。
//  使用 Codable，对端多发的字段自动忽略（JSONDecoder 默认行为），
//  缺失的可选字段使用 nil/默认值，保证协议 v1 向后兼容。
//

import Foundation

/// JSON 编解码器：统一配置，容忍未知字段。
enum ProtocolJson {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // ISO8601 不用；我们所有时间戳都是毫秒整数，交给各 payload 的 Int64 字段。
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [] // 紧凑输出，不 prettyPrint
        return e
    }()
}

/// 在线设备（与桌面端 Device 字段一致）。
struct Device: Codable, Identifiable, Hashable {
    var deviceId: String
    var deviceName: String
    var deviceType: DeviceType
    var ip: String
    var tcpPort: Int = Int(TCP_PORT)
    var platform: String
    var lastSeen: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var online: Bool = true
    var alias: String = ""

    var id: String { deviceId }

    /// UI 显示名：别名优先。
    var displayName: String { alias.isEmpty ? deviceName : alias }

    /// 导航路径按 deviceId 判定。lastSeen 每 2 秒变化，若参与哈希，
    /// navigationDestination 会不断重建详情视图，导致 fileImporter 的 @State
    /// 被重置、用户点「打开」后选择器直接消失且 completion 不回调。
    func hash(into hasher: inout Hasher) {
        hasher.combine(deviceId)
    }

    static func == (lhs: Device, rhs: Device) -> Bool {
        lhs.deviceId == rhs.deviceId
    }
}

/// 文件元数据（协议载荷）。
struct FileMeta: Codable, Hashable {
    var fileId: String
    var name: String
    var size: Int64
    var sha256: String
    var mime: String
    /// 相对文件夹根的路径（旧版逐文件兼容字段），'/' 分隔含文件名。单文件缺省。
    var relativePath: String? = nil
    /// 文件夹整包标记（协议 v1 纯追加）。带该字段时 name 为临时包名。
    var bundle: FolderBundleRef? = nil
    /// 仅本机使用，不进入协议载荷 —— 因此不参与 Codable（手动合成时会编码，见下注）。
    var localPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case fileId, name, size, sha256, mime, relativePath, bundle
        // localPath 故意不列入 CodingKeys，绝不上线。
    }

    /// UI 显示名：整包显示「文件夹「rootName」」，否则 basename。
    var displayName: String {
        if let bundle { return "文件夹「\(bundle.rootName)」" }
        return name
    }
}

/// 文件夹整包元数据。
struct FolderBundleRef: Codable, Hashable {
    var format: String
    var rootName: String
    var fileCount: Int
}

/// 传输任务（UI 与核心之间传递的可序列化 DTO）。
struct TransferTask: Identifiable {
    var transferId: String
    var peer: Device
    var direction: Direction
    var files: [FileMeta]
    var totalSize: Int64
    var transferredBytes: Int64 = 0
    var status: TaskStatus = .pending
    var speedBps: Int64 = 0
    var concurrency: Int = Int(DEFAULT_CONCURRENCY)
    var chunkSize: Int = DEFAULT_CHUNK_SIZE
    var startedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var finishedAt: Int64? = nil
    var currentFileName: String = ""
    var saveDir: String = ""
    var errorCode: String = ""
    var errorMessage: String = ""
    var category: TransferCategory = .normal
    var chatMsgId: String = ""
    /// 接收完成后每个 fileId 对应的最终路径，供「打开」入口使用。
    var finalPaths: [String: String] = [:]
    /// 本机打包产生的临时 LFTB1 文件，传输结束后清理（不进入协议）。
    var tempBundlePaths: [String] = []

    var id: String { transferId }

    /// 进度 0.0 ~ 1.0。
    var progress: Double {
        guard totalSize > 0 else { return 0 }
        return min(1, max(0, Double(transferredBytes) / Double(totalSize)))
    }
}

/// 持久化传输记录。
struct TransferRecord: Codable, Identifiable, Hashable {
    var recordId: String
    var timestamp: Int64
    var peerId: String
    var peerName: String
    var peerIp: String
    var fileName: String
    var fileSize: Int64
    var direction: Direction
    var status: TaskStatus
    var avgSpeedBps: Int64
    var localPath: String
    var sha256: String
    var mime: String
    var errorCode: String? = nil
    var category: TransferCategory? = nil

    var id: String { recordId }
}

/// 用户设置。
struct Settings: Codable {
    var saveDir: String = ""
    var chunkSizeMB: Int = 4
    var concurrency: Int = Int(DEFAULT_CONCURRENCY)
    var speedLimitKBps: Int = 0
    var deviceAlias: String = ""
    var tlsEnabled: Bool = false
    var chatAutoAcceptImages: Bool = true
}

/// 待用户确认的接收请求。
struct IncomingRequest: Identifiable {
    var transferId: String
    var peer: Device
    var files: [FileMeta]
    var totalSize: Int64
    var saveDir: String
    var expiresAt: Int64
    var category: TransferCategory = .normal
    var chatMsgId: String = ""

    var id: String { transferId }
}

/// 完成提示。
struct CompleteNotice: Identifiable {
    var id: String { transferId }
    var transferId: String
    var title: String
    var message: String
    var localPath: String = ""
    var success: Bool = true
}

/// 聊天消息（本地存储与 UI 展示统一模型）。
struct ChatMessage: Codable, Identifiable, Hashable {
    var msgId: String
    var fromDeviceId: String
    var toDeviceId: String
    var conversationId: String
    var kind: String  // "TEXT" | "IMAGE"
    var text: String = ""
    var timestamp: Int64
    var state: String = "DELIVERED"  // DELIVERED | READ
    var outgoing: Bool = false
    /// 图片消息：接收后的本地路径 / 发送前的源路径。
    var imagePath: String = ""
    var imageName: String = ""
    var transferId: String = ""

    var id: String { msgId }
}

/// 会话摘要（聊天列表）。
struct ConversationSummary: Identifiable, Hashable {
    var conversationId: String
    var peerId: String
    var peerName: String
    var lastText: String
    var lastTs: Int64
    var unread: Int

    var id: String { conversationId }
}

// MARK: - 发现层载荷

struct DiscoveryAnnounce: Codable {
    var type: DiscoveryMessageType
    var deviceId: String
    var deviceName: String
    var deviceType: DeviceType
    var ip: String
    var tcpPort: Int
    var platform: String
    var ts: Int64
}

/// mDNS TXT 中携带的设备信息（base64(JSON) 后放入 info= 记录）。
struct MdnsDeviceInfo: Codable {
    var deviceId: String
    var deviceName: String
    var deviceType: DeviceType
    var ip: String
    var platform: String
}

// MARK: - 控制层 payload

struct HelloPayload: Codable {
    var deviceId: String
    var channel: Channel
    var transferId: String? = nil
    var fileId: String? = nil
    var chunkIndex: Int? = nil
    /// 'transfer'（默认）或 'chat'。
    var purpose: String? = nil
    /// 能力协商，如 ['CHAT']。
    var features: [String] = []
}

struct HelloAckPayload: Codable {
    var ok: Bool
    var reason: String? = nil
}

struct TransferRequestPayload: Codable {
    var transferId: String
    var files: [FileMeta]
    var totalSize: Int64
    var category: String = "NORMAL"
    var chatMsgId: String? = nil
}

struct TransferDecisionPayload: Codable {
    var transferId: String
    var saveDir: String? = nil
    var reason: String? = nil
}

struct ResumeQueryPayload: Codable {
    var transferId: String
    var fileId: String
}

struct ResumeResponsePayload: Codable {
    var transferId: String
    var fileId: String
    var doneChunks: [Int]
    var receivedBytes: Int64
}

struct ChunkPlanPayload: Codable {
    var transferId: String
    var fileId: String
    var chunkSize: Int
    var totalChunks: Int
}

struct ProgressPayload: Codable {
    var transferId: String
    var fileId: String
    var receivedBytes: Int64
    var speedBps: Int64
}

struct VerifyRequestPayload: Codable {
    var transferId: String
    var fileId: String
    var expectSha256: String
    /// 块 CRC32（key = chunkIndex 字符串）。CRC32 是无符号 32 位（0~4294967295），
    /// 必须用 UInt32/UInt64 承载，避免 Int32 溢出 —— 与 Android 用 Long 的修复一致。
    var crcMap: [String: UInt64]? = nil
}

struct VerifyResultPayload: Codable {
    var transferId: String
    var fileId: String
    var ok: Bool
    var mismatchChunks: [Int]? = nil
}

struct ResendChunkPayload: Codable {
    var transferId: String
    var fileId: String
    /// 线格式字段名固定为 chunkIndex（与三端一致）。
    var chunkIndex: [Int]
}

struct TransferCompletePayload: Codable {
    var transferId: String
    var fileId: String
    var finalPath: String
    var size: Int64
    var avgSpeedBps: Int64
}

struct TransferFailedPayload: Codable {
    var transferId: String
    var code: ErrorCode
    var message: String
    /// 线格式字段名固定为 final；message 已是最终中文文案时置 true。
    var finalMessage: Bool = false

    enum CodingKeys: String, CodingKey {
        case transferId, code, message
        case finalMessage = "final"
    }
}

struct TransferCancelPayload: Codable {
    var transferId: String
    var reason: String
}

struct PingPayload: Codable {
    var ts: Int64
}

struct ChatMessagePayload: Codable {
    var msgId: String
    var fromDeviceId: String
    var toDeviceId: String
    var conversationId: String
    var kind: String = "TEXT"
    var text: String
    var timestamp: Int64
}

struct ChatImageMeta: Codable {
    var name: String
    var size: Int64
    var sha256: String
    var mime: String
}

struct ChatImagePayload: Codable {
    var msgId: String
    var fromDeviceId: String
    var toDeviceId: String
    var conversationId: String
    var kind: String = "IMAGE"
    var transferId: String
    var image: ChatImageMeta
    var timestamp: Int64
}

struct ChatAckPayload: Codable {
    var msgId: String
    var state: String
    var fromDeviceId: String
    var timestamp: Int64
}

// MARK: - 信封

/// 控制层统一信封：{ v, type, msgId, ts, payload }。
/// payload 用 JSONValue 承载，按 type 解码为具体 payload，避免强耦合。
struct ProtocolEnvelope: Codable {
    var v: Int
    var type: MessageType
    var msgId: String
    var ts: Int64
    var payload: JSONValue
}

/// 创建消息信封（payload 编码为 JSONValue）。
func createEnvelope<P: Encodable>(_ type: MessageType, _ payload: P) -> ProtocolEnvelope {
    let json = (try? JSONValue(encodable: payload)) ?? .object([:])
    return ProtocolEnvelope(
        v: PROTOCOL_VERSION,
        type: type,
        msgId: newId(),
        ts: Int64(Date().timeIntervalSince1970 * 1000),
        payload: json
    )
}

/// 从信封的 payload 解码具体类型。
func decodePayload<P: Decodable>(_ envelope: ProtocolEnvelope, as type: P.Type) throws -> P {
    try envelope.payload.decoded(as: type)
}
