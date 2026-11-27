//
//  TcpServer.swift
//  局域网快传
//
//  TCP 监听服务：控制连接与数据连接共用 45211，靠首帧 HELLO.channel 分流，
//  先回 HELLO_ACK。与桌面 TcpServer.ts、Android TcpServer.kt 行为一致。
//
//  注意：iOS 上 App 进入后台后监听会被系统挂起，因此本 App 仅支持前台传输。
//

import Foundation
import Network

final class TcpServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.lantransfer.listen", qos: .userInitiated)
    private let deviceId: String

    /// 收到控制连接（已握手，purpose=transfer 或缺省）。
    var onControl: ((TcpConnection) -> Void)?
    /// 收到聊天控制连接（已握手，purpose=chat）。
    var onChat: ((TcpConnection) -> Void)?
    /// 收到数据连接（已握手，HELLO 带 transferId/fileId/chunkIndex）。
    var onData: ((TcpConnection) -> Void)?
    var onError: ((String) -> Void)?

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    func start(port: UInt16 = TCP_PORT) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let nwListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = nwListener

        nwListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.onError?(error.localizedDescription)
            default:
                break
            }
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let link = TcpConnection(connection: connection)
            link.startReading()
            Task {
                await self.handshake(link)
            }
        }

        nwListener.start(queue: queue)
    }

    private func handshake(_ link: TcpConnection) async {
        do {
            let envelope = try await link.reader.readFrame()
            guard envelope.type == .hello else {
                throw FrameError.invalidFrame("首帧必须为 HELLO")
            }
            let hello = try decodePayload(envelope, as: HelloPayload.self)
            guard hello.channel == .control || hello.channel == .data else {
                throw FrameError.invalidFrame("HELLO 缺少合法 channel")
            }
            // 回填到连接对象：接收侧 handleDataConnection / beginReceive 依赖
            // link.hello 取 channel、transferId、fileId、chunkIndex 与对端 deviceId。
            link.hello = hello
            // 回 HELLO_ACK。
            try await link.sendMessage(.helloAck, HelloAckPayload(ok: true))
            if hello.channel == .data {
                onData?(link)
            } else if hello.purpose == "chat" {
                onChat?(link)
            } else {
                onControl?(link)
            }
        } catch {
            try? await link.sendMessage(.helloAck, HelloAckPayload(ok: false, reason: error.localizedDescription))
            link.close()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
