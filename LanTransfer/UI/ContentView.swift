//
//  ContentView.swift
//  局域网快传
//
//  主容器：四个标签页，并全局覆盖接收请求弹窗与完成提示。
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            DeviceListView()
                .tabItem {
                    Label("设备", systemImage: "devices2")
                }

            TransferView()
                .tabItem {
                    Label("传输", systemImage: "arrow.left.arrow.right")
                }

            ChatConversationListView()
                .tabItem {
                    Label("聊天", systemImage: "bubble.left.and.bubble.right")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
        .overlay {
            if let request = appState.incoming {
                IncomingRequestView(request: request)
            }
        }
        .alert(item: $appState.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .onAppear {
            appState.refreshDevices()
        }
    }
}
