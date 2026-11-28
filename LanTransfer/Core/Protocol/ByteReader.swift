//
//  ByteReader.swift
//  章鱼快传
//
//  字节流读取器：在连接上维护接收缓冲，提供精确读取 n 字节的 async 接口，
//  解决 TCP 粘包/半包问题。语义与 desktop FrameCodec.ByteReader 一致，
//  但基于 Swift Concurrency 的 CheckedContinuation 实现（Network.framework 为回调式接收）。
//

import Foundation

/// 精确字节读取器。由网络层在收到数据时调用 feed(_:)，由协议层调用 readExactly(_:)。
/// 线程安全：内部用 NSLock 保护缓冲与等待队列。
final class ByteReader {
    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [Waiter] = []
    private var failure: Error?
    private var ended = false

    private struct Waiter {
        let n: Int
        let continuation: CheckedContinuation<Data, Error>
    }

    /// 喂入从 socket 收到的数据。零长度数据会被忽略。
    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if failure == nil && !ended {
            buffer.append(data)
        }
        let ready = pumpLocked()
        lock.unlock()
        ready.forEach { $0.continuation.resume(returning: $0.data) }
    }

    /// 标记流结束（对端 FIN）。唤醒所有等待者并报错。
    func finish() {
        lock.lock()
        ended = true
        let error = failure ?? FrameError.closed
        failure = error
        let pending = waiters
        waiters.removeAll()
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        pending.forEach { $0.continuation.resume(throwing: error) }
    }

    /// 连接出错时调用，唤醒所有等待者。
    func fail(_ error: Error) {
        lock.lock()
        guard failure == nil else { lock.unlock(); return }
        failure = error
        let pending = waiters
        waiters.removeAll()
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        pending.forEach { $0.continuation.resume(throwing: error) }
    }

    /// 精确读取 n 字节。
    func readExactly(_ n: Int) async throws -> Data {
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            let waiter = Waiter(n: n, continuation: continuation)
            waiters.append(waiter)
            let ready = pumpLocked()
            lock.unlock()
            ready.forEach { $0.continuation.resume(returning: $0.data) }
        }
        return result
    }

    /// 读取一个控制帧并返回信封。
    func readFrame() async throws -> ProtocolEnvelope {
        let prefix = try await readExactly(CONTROL_LENGTH_PREFIX_BYTES)
        let length = Int(BE.u32(prefix, at: 0))
        guard length > 0, length <= CONTROL_MAX_FRAME_BYTES else {
            throw FrameError.invalidFrame("非法控制帧长度 \(length)")
        }
        let jsonData = try await readExactly(length)
        return try FrameCodec.decodeEnvelope(jsonData)
    }

    /// 读取数据帧 20 字节头。
    func readDataHeader() async throws -> DataHeader {
        let header = try await readExactly(DATA_HEADER_BYTES)
        return try FrameCodec.decodeDataHeader(header)
    }

    // MARK: - 内部

    /// 在已加锁状态下，把缓冲中已就绪的等待者取出；返回 (等待者, 数据) 列表供解锁后 resume。
    private func pumpLocked() -> [(continuation: CheckedContinuation<Data, Error>, data: Data)] {
        var ready: [(CheckedContinuation<Data, Error>, Data)] = []
        while let first = waiters.first, buffer.count >= first.n {
            waiters.removeFirst()
            let taken = Data(buffer.prefix(first.n))
            buffer.removeSubrange(0..<first.n)
            ready.append((first.continuation, taken))
        }
        return ready
    }
}
