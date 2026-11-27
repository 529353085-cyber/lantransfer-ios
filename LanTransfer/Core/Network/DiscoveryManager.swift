//
//  DiscoveryManager.swift
//  局域网快传
//
//  设备发现：Bonjour（NetService 发布 + NetServiceBrowser 浏览）为主，
//  UDP 45210 为辅（监听对端广播；iOS 禁止广播到 255.255.255.255，
//  故发送侧仅尝试定向到本机子网广播地址，失败时静默忽略，不影响 Bonjour 主路径）。
//
//  与桌面 MdnsDiscovery.ts / UdpDiscovery.ts、Android NsdDiscovery.kt / UdpDiscovery.kt 对齐：
//  - Bonjour 服务类型 _lantransfer._tcp，TXT 记录 info=<base64(JSON(MdnsDeviceInfo))>
//  - UDP 广播载荷 DiscoveryAnnounce，端口 45210
//  注意：桌面端 mDNS 用自实现组播，其 TXT 记录为 info=<base64>，本端用系统 NetService 读取。
//

import Foundation
import Network
import os

final class DiscoveryManager: NSObject {
    private let selfDevice: Device
    private let registry: DeviceRegistry
    private let logger = Logger(subsystem: "com.lantransfer.ios", category: "discovery")

    private var publishedService: NetService?
    private var browser: NetServiceBrowser?
    private var resolvingServices: Set<NetService> = []
    private var udpListener: NWListener?
    private let udpQueue = DispatchQueue(label: "com.lantransfer.udp", qos: .utility)
    private var udpTimer: Timer?

    init(selfDevice: Device, registry: DeviceRegistry) {
        self.selfDevice = selfDevice
        self.registry = registry
    }

    /// 启动发现（Bonjour 发布 + 浏览 + UDP 监听）。
    func start() {
        publishBonjour()
        browseBonjour()
        startUdpListen()
        udpTimer = Timer.scheduledTimer(withTimeInterval: Double(DISCOVER_INTERVAL_MS) / 1000.0, repeats: true) { [weak self] _ in
            self?.announceUdp()
        }
    }

    func stop() {
        publishedService?.stop()
        publishedService = nil
        browser?.stop()
        browser = nil
        resolvingServices.forEach { $0.stopResolving() }
        resolvingServices.removeAll()
        udpListener?.cancel()
        udpListener = nil
        udpTimer?.invalidate()
        udpTimer = nil
    }

    // MARK: - Bonjour

    private func bonjourTxtData() -> Data {
        let info = MdnsDeviceInfo(
            deviceId: selfDevice.deviceId,
            deviceName: selfDevice.alias.isEmpty ? selfDevice.deviceName : selfDevice.alias,
            deviceType: selfDevice.deviceType,
            ip: selfDevice.ip,
            platform: selfDevice.platform
        )
        let json = (try? JSONEncoder().encode(info)) ?? Data()
        let base64 = json.base64EncodedString()
        // NetService 的 TXT 记录值需为 key=value 形式的数据项。
        return NetService.data(fromTXTRecord: ["info": base64.data(using: .utf8)!])
    }

    private func publishBonjour() {
        let service = NetService(
            domain: "local.",
            type: SERVICE_TYPE,
            name: selfDevice.deviceId,
            port: Int32(TCP_PORT)
        )
        service.setTXTRecord(bonjourTxtData())
        service.publish()
        publishedService = service
    }

    private func browseBonjour() {
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: SERVICE_TYPE, inDomain: "local.")
        browser = b
    }

    // MARK: - UDP

    private func startUdpListen() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UDP_DISCOVERY_PORT)!)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: BUFFER_SIZE) { data, _, _, _ in
                    if let data {
                        self.handleUdpPacket(data, sourceIp: self.peerIp(of: connection))
                    }
                    connection.cancel()
                }
            }
            listener.start(queue: udpQueue)
            udpListener = listener
        } catch {
            logger.error("UDP 监听失败: \(error.localizedDescription)")
        }
    }

    private func peerIp(of connection: NWConnection) -> String? {
        if case .hostPort(let host, _) = connection.endpoint,
           case .ipv4(let addr) = host {
            return addr.debugDescription
        }
        return nil
    }

    /// iOS 禁止向 255.255.255.255 广播；尝试发往本机子网定向广播地址。
    /// 失败静默忽略 —— 桌面/Android 的 UDP 监听 + Bonjour 仍能发现本端。
    private func announceUdp() {
        let announce = DiscoveryAnnounce(
            type: .announce,
            deviceId: selfDevice.deviceId,
            deviceName: selfDevice.alias.isEmpty ? selfDevice.deviceName : selfDevice.alias,
            deviceType: selfDevice.deviceType,
            ip: selfDevice.ip,
            tcpPort: Int(TCP_PORT),
            platform: selfDevice.platform,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        guard let json = try? JSONEncoder().encode(announce) else { return }
        guard let broadcastHost = subnetBroadcastAddress() else { return }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(broadcastHost),
            port: NWEndpoint.Port(rawValue: UDP_DISCOVERY_PORT)!
        )
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: json, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: udpQueue)
    }

    /// 取本机第一个非回环 IPv4 的子网定向广播地址。
    private func subnetBroadcastAddress() -> String? {
        var addresses: [(name: String, ip: String, mask: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let name = String(cString: current.pointee.ifa_name)
            let addr = current.pointee.ifa_addr
            if flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING),
               addr?.pointee.sa_family == UInt8(AF_INET) {
                let ip = ipString(addr!)
                if let mask = current.pointee.ifa_netmask, let ip {
                    addresses.append((name, ip, ipString(mask) ?? ""))
                }
            }
            ptr = current.pointee.ifa_next
        }
        // 优先 192.168.x，排除回环。
        let lan = addresses
            .filter { !$0.ip.hasPrefix("127.") }
            .sorted { $0.ip.hasPrefix("192.168.") && !$1.ip.hasPrefix("192.168.") }
        guard let first = lan.first else { return nil }
        let ipParts = first.ip.split(separator: ".").compactMap { Int($0) }
        let maskParts = first.mask.split(separator: ".").compactMap { Int($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return nil }
        let broadcast = zip(ipParts, maskParts).map { ($0 | (~$1 & 0xFF)) }
        return broadcast.map(String.init).joined(separator: ".")
    }

    private func ipString(_ sockaddr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addrIn = sockaddr.pointee
        let result = withUnsafePointer(to: &addrIn) { ptr in
            ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                inet_ntop(AF_INET, &sin.pointee.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            }
        }
        return result == nil ? nil : String(cString: buffer)
    }

    private func handleUdpPacket(_ data: Data, sourceIp: String?) {
        guard let announce = try? JSONDecoder().decode(DiscoveryAnnounce.self, from: data) else { return }
        guard announce.deviceId != selfDevice.deviceId else { return }
        switch announce.type {
        case .bye:
            registry.markOffline(announce.deviceId)
        case .announce:
            let peerIp = sourceIp ?? announce.ip
            guard isUsablePeerIp(peerIp) else { return }
            registry.upsert(Device(
                deviceId: announce.deviceId,
                deviceName: announce.deviceName,
                deviceType: announce.deviceType,
                ip: peerIp,
                tcpPort: announce.tcpPort,
                platform: announce.platform
            ))
        }
    }

    private func isUsablePeerIp(_ ip: String) -> Bool {
        if ip.isEmpty || ip == "0.0.0.0" || ip == "::" || ip == "::1" { return false }
        if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { return false }
        if ip.contains(":") { return false } // 只要 IPv4
        return true
    }
}

// MARK: - NetServiceBrowserDelegate / NetServiceDelegate

extension DiscoveryManager: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices.insert(service)
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        resolvingServices.remove(service)
        service.stopResolving()
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {}
    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {}
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        logger.error("Bonjour 浏览失败: \(errorDict.description)")
    }
}

extension DiscoveryManager: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        defer {
            sender.stopResolving()
            resolvingServices.remove(sender)
        }
       guard let txt = sender.txtRecordData(),
              let infoData = NetService.dictionary(fromTXTRecord: txt)["info"],
              let info = try? JSONDecoder().decode(MdnsDeviceInfo.self, from: infoData),
              info.deviceId != selfDevice.deviceId else { return }

        // 从 Bonjour 解析出的地址优先取 IPv4。
        let ip = resolvedIPv4(of: sender) ?? info.ip
        guard isUsablePeerIp(ip) else { return }
        registry.upsert(Device(
            deviceId: info.deviceId,
            deviceName: info.deviceName,
            deviceType: info.deviceType,
            ip: ip,
            tcpPort: sender.port > 0 ? Int(sender.port) : Int(TCP_PORT),
            platform: info.platform
        ))
    }

    private func resolvedIPv4(of service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for addressData in addresses {
            var raw = addressData
            let ip = raw.withUnsafeMutableBytes { buf -> String? in
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard let base = buf.baseAddress else { return nil }
                let sockaddrPtr = base.assumingMemoryBound(to: sockaddr.self)
                if sockaddrPtr.pointee.sa_family == UInt8(AF_INET) {
                    let sinPtr = base.assumingMemoryBound(to: sockaddr_in.self)
                    var sinAddr = sinPtr.pointee.sin_addr
                    if inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        return String(cString: buffer)
                    }
                }
                return nil
            }
            if let ip { return ip }
        }
        return nil
    }
}
