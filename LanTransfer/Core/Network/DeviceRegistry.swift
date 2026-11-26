//
//  DeviceRegistry.swift
//  局域网快传
//
//  在线设备注册表：upsert / 别名 / 超时剔除，是 UI 设备列表的唯一数据源。
//  与桌面 DeviceRegistry.ts / Android DeviceRegistry.kt 对齐。
//

import Foundation
import Combine

final class DeviceRegistry: ObservableObject {
    @Published private(set) var devices: [Device] = []
    private var aliases: [String: String] = [:]
    private var sweepTimer: Timer?
    private let lock = NSLock()

    /// 定时清理超时设备（每 2s）。
    func start() {
        stop()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: Double(DISCOVER_INTERVAL_MS) / 1000.0, repeats: true) { [weak self] _ in
            self?.sweepExpired()
        }
    }

    func stop() {
        sweepTimer?.invalidate()
        sweepTimer = nil
    }

    /// 新增或刷新设备，保留已有别名。
    func upsert(_ device: Device) {
        lock.lock()
        let alias = aliases[device.deviceId] ?? ""
        let lastSeen = Int64(Date().timeIntervalSince1970 * 1000)
        var merged = device
        merged.alias = device.alias.isEmpty ? alias : device.alias
        merged.tcpPort = device.tcpPort > 0 ? device.tcpPort : Int(TCP_PORT)
        merged.lastSeen = lastSeen
        merged.online = true
        let existingIndex = devices.firstIndex { $0.deviceId == merged.deviceId }
        lock.unlock()

        DispatchQueue.main.async {
            if let index = existingIndex {
                if self.devices.indices.contains(index) {
                    self.devices[index] = merged
                } else if let reindex = self.devices.firstIndex(where: { $0.deviceId == merged.deviceId }) {
                    self.devices[reindex] = merged
                }
            } else {
                self.devices.append(merged)
            }
        }
    }

    /// 标记设备离线并移除。
    func markOffline(_ deviceId: String) {
        DispatchQueue.main.async {
            self.devices.removeAll { $0.deviceId == deviceId }
        }
    }

    func get(_ deviceId: String) -> Device? {
        devices.first { $0.deviceId == deviceId }
    }

    func setAlias(_ alias: String, for deviceId: String) {
        lock.lock()
        aliases[deviceId] = alias
        lock.unlock()
        DispatchQueue.main.async {
            if let index = self.devices.firstIndex(where: { $0.deviceId == deviceId }) {
                self.devices[index].alias = alias
            }
        }
    }

    func loadAliases(_ map: [String: String]) {
        lock.lock()
        aliases = map
        lock.unlock()
        DispatchQueue.main.async {
            self.devices = self.devices.map { device in
                var copy = device
                copy.alias = map[device.deviceId] ?? device.alias
                return copy
            }
        }
    }

    func exportAliases() -> [String: String] { aliases }

    /// 清理超过 DEVICE_TIMEOUT_MS 未宣告的设备。
    func sweepExpired() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let expired = devices.filter { now - $0.lastSeen > DEVICE_TIMEOUT_MS }.map(\.deviceId)
        if !expired.isEmpty {
            DispatchQueue.main.async {
                self.devices.removeAll { expired.contains($0.deviceId) }
            }
        }
    }
}
