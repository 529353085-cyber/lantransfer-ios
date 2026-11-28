//
//  DiscoveryManager.swift
//  章鱼快传
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
    private var selfDevice: Device
    private let registry: DeviceRegistry
    private let logger = Logger(subsystem: "com.lantransfer.ios", category: "discovery")

    private var publishedService: NetService?
    private var browser: NetServiceBrowser?
    private var resolvingServices: Set<NetService> = []
    private var udpListener: NWListener?
    private let udpQueue = DispatchQueue(label: "com.lantransfer.udp", qos: .utility)
    private var udpTimer: Timer?
    /// NetService / NetServiceBrowser 要求 Bonjour 类型以点结尾（如 _http._tcp.）。
    /// Info.plist 的 NSBonjourServices 仍声明不带点的 _lantransfer._tcp（Apple 规定格式）。
    private let bonjourType = SERVICE_TYPE + "."

    init(selfDevice: Device, registry: DeviceRegistry) {
        self.selfDevice = selfDevice
        self.registry = registry
    }

    /// 启动发现（Bonjour 发布 + 浏览 + UDP 监听）。
    /// 可重复调用：先清理旧通道，避免定时器与 NWListener 叠加。
    func start() {
        stop()
        publishBonjour()
        browseBonjour()
        startUdpListen()
        udpTimer = Timer.scheduledTimer(withTimeInterval: Double(DISCOVER_INTERVAL_MS) / 1000.0, repeats: true) { [weak self] _ in
            self?.announceUdp()
        }
    }

    /// iOS 14+ 本地网络权限变化后，旧的浏览器/发布器/监听器不会自动恢复，必须重建。
    func restart() {
        start()
    }

    /// 本机 IP 变化后更新 TXT / UDP 宣告使用的地址（由 AppState 在网络切换时调用）。
    func updateSelfDevice(_ device: Device) {
        selfDevice = device
    }

    /// 用户手动刷新：重建全部发现通道并立刻广播一次宣告。
    func refresh() {
        restart()
        announceUdp()
    }

    func stop() {
        publishedService?.stop()
        publishedService = nil
        browser?.stop()
        browser = nil
        resolvingServices.forEach { $0.stop() }
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
            type: bonjourType,
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
        b.searchForServices(ofType: bonjourType, inDomain: "local.")
        browser = b
    }

    // MARK: - UDP

    private func startUdpListen() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UDP_DISCOVERY_PORT)!)
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.logger.error("UDP 监听失败: \(error.localizedDescription)")
                }
            }
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
        // 排除回环、APIPA（169.254.x 不可跨设备路由）、/32 主机路由与全零掩码，
        // 否则蜂窝数据/虚拟网卡可能被选中，算出「广播地址 == 自身 IP」导致宣告永不投递。
        let lan = addresses
            .filter { !$0.ip.hasPrefix("127.") && !$0.ip.hasPrefix("169.254.") }
            .filter { entry in
                let m = entry.mask.split(separator: ".").compactMap { Int($0) }
                guard m.count == 4 else { return false }
                return m != [255, 255, 255, 255] && m != [0, 0, 0, 0]
            }
            .sorted { left, right in lanPriority(left.ip) < lanPriority(right.ip) }
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
                var sinAddr = sin.pointee.sin_addr
                return inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN))
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

    /// LAN 地址优先级：192.168.x > 10.x > 172.16-31.x > 其他。
    private func lanPriority(_ ip: String) -> Int {
        if ip.hasPrefix("192.168.") { return 0 }
        if ip.hasPrefix("10.") { return 1 }
        if ip.hasPrefix("172.") { return 2 }
        return 3
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
        service.stop()
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {}
    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {}
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        logger.error("Bonjour 浏览失败: \(errorDict.description)")
    }
}

extension DiscoveryManager: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        // 不再 resolve 后立刻 stop：系统会在地址变化时再次回调，
        // 且保留服务实例可让浏览器持续缓存该设备，避免几秒后从列表消失。
        // 服务在 stop()/restart() 时统一清理。
        guard let txt = sender.txtRecordData(),
              let infoValue = NetService.dictionary(fromTXTRecord: txt)["info"] else { return }
        // TXT 的 info 值是 base64(UTF8 JSON)，必须先 base64 解码再交给 JSONDecoder；
        // 直接把 base64 字符串当 JSON 解析会恒定失败，导致解析出的设备被丢弃。
        let jsonData = Data(base64Encoded: infoValue) ?? infoValue
        guard let info = try? JSONDecoder().decode(MdnsDeviceInfo.self, from: jsonData),
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
