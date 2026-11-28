//
//  LanTransferApp.swift
//  章鱼快传
//
//  应用入口。创建全局 AppState 并注入到视图层级。
//

import SwiftUI

@main
struct LanTransferApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                // 本地网络权限弹窗出现/消失会改变 scenePhase；
                // 用户点「允许」后必须重建发现通道，否则首次启动的
                // NetServiceBrowser / NWListener 一直处于未授权状态。
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        appState.handleAppActive()
                    }
                }
        }
    }
}
