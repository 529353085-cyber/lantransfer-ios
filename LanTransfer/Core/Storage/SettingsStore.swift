//
//  SettingsStore.swift
//  章鱼快传
//
//  设置持久化（UserDefaults，Codable JSON）。字段与桌面 Settings / Android AppSettings 对齐。
//

import Foundation
import Combine

final class SettingsStore: ObservableObject {
    @Published var settings: Settings {
        didSet { persist() }
    }
    private let key = "lantransfer.settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = Settings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func update(_ new: Settings) { settings = new }
}
