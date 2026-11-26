//
//  LanTransferApp.swift
//  局域网快传
//
//  应用入口。创建全局 AppState 并注入到视图层级。
//

import SwiftUI

@main
struct LanTransferApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
