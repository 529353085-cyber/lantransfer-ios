//
//  TcpConnection.swift
//  局域网快传
//
//  TCP 连接封装：基于 Network.framework 的 NWConnection，把回调式接收数据
//  喂给 ByteReader，提供 async 的帧读写接口。控制连接与数据连接共用此类。
//

import Foundation
import Network

/// 一条 TCP 连接（已握手）。
final class TcpConnection {
    let connection: NWConnection
    let reader = ByteReader()
    /// 握手时写入的 HELLO 载荷（服务端被动连接由 TcpServer.handshake 回填）。
    /// 必须在回调 onData/onChat/onControl 之前赋值，保证接收侧按 deviceId/channel 分流。
    var hello: HelloPayload?
    private let queue = DispatchQueue(label: "com.lantransfer.tcp", qos: .userInitiated)
    private let lock = NSLock()
    private var closed = false

    init(connection: NWConnection, hello: HelloPayload? = nil) {
        self.connection = connection
        self.hello = hello
    }

    /// 启动接收循环：持续 receive 并把数据喂给 ByteReader。
    func startReading() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.reader.fail(FrameError.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.reader.feed(data)
            }
            if let error {
                self.reader.fail(FrameError.socket(error.localizedDescription))
                return
            }
            if isComplete {
                self.reader.finish()
                return
            }
            self.receiveLoop()
        }
    }

    /// 发送原始数据并等待完成。
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: FrameError.socket(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// 发送一条控制消息。
    func sendMessage<P: Encodable>(_ type: MessageType, _ payload: P) async throws {
        let data = try FrameCodec.encodeMessage(type, payload)
        try await send(data)
    }

    /// 正常关闭连接（发送 FIN）。
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        connection.cancel()
    }

    /// 等待对端 FIN（用于 VERIFY 前的 FIN 同步）。
    func waitForEnd() async {
        // 读取一个字节：对端关闭时 readExactly 会收到 SOCKET_END 并抛错。
        _ = try? await reader.readExactly(1)
    }

    var peerAddress: String {
        switch connection.endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr): return addr.debugDescription
            case .ipv6(let addr): return addr.debugDescription
            case .name(let name, _): return name
            @unknown default: return ""
            }
        @unknown default:
            return ""
        }
    }
}

/// 主动建立 TCP 连接并握手（channel + transferId 等扩展字段）。
func connectTcp(
    host: String,
    port: UInt16 = TCP_PORT,
    channel: Channel,
    purpose: String? = nil,
    transferId: String? = nil,
    fileId: String? = nil,
    chunkIndex: Int? = nil,
    deviceId: String,
    features: [String] = [],
    timeoutMs: Int64 = Int64(CONNECT_TIMEOUT_MS)
) async throws -> TcpConnection {
    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    let connection = NWConnection(to: endpoint, using: parameters)
    let link = TcpConnection(connection: connection)

    // 等待 ready，带超时。
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        var resumed = false
        let resumeOnce: (Result<Void, Error>) -> Void = { result in
            guard !resumed else { return }
            resumed = true
            switch result {
            case .success: continuation.resume()
            case .failure(let e): continuation.resume(throwing: e)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                resumeOnce(.success(()))
            case .failed(let error):
                resumeOnce(.failure(FrameError.socket(error.localizedDescription)))
            case .cancelled:
                resumeOnce(.failure(FrameError.closed))
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "com.lantransfer.connect", qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(timeoutMs) / 1000.0) {
            resumeOnce(.failure(FrameError.timeout("连接超时 \(timeoutMs)ms")))
        }
    }

    link.startReading()

    // 发送 HELLO 首帧。
    let hello = HelloPayload(
        deviceId: deviceId,
        channel: channel,
        transferId: transferId,
        fileId: fileId,
        chunkIndex: chunkIndex,
        purpose: purpose,
        features: features
    )
    try await link.sendMessage(.hello, hello)

    // 等待 HELLO_ACK。
    let ackEnvelope = try await link.reader.readFrame()
    guard ackEnvelope.type == .helloAck else {
        throw FrameError.invalidFrame("首帧响应必须为 HELLO_ACK")
    }
    let ack = try decodePayload(ackEnvelope, as: HelloAckPayload.self)
    guard ack.ok else {
        throw FrameError.socket(ack.reason ?? "对端拒绝连接")
    }

    return link
}
