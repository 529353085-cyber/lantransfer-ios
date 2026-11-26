//
//  DeviceListView.swift
//  局域网快传
//
//  设备列表、设备操作页与进行中任务概要。
//

import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// 通用空状态视图（兼容 iOS 16，替代 iOS 17 的 ContentUnavailableView）。
/// 定义为 internal，供其他页面复用。
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

/// 任务状态中文文案（internal，供传输页复用）。
func transferStatusText(_ status: TaskStatus) -> String {
    switch status {
    case .pending:     return "等待中"
    case .accepted:    return "已接受"
    case .transferring: return "传输中"
    case .verifying:   return "校验中"
    case .success:     return "已完成"
    case .failed:      return "失败"
    case .cancelled:   return "已取消"
    case .rejected:    return "已拒绝"
    }
}

struct DeviceListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                if !appState.tasks.isEmpty {
                    Section("进行中的传输") {
                        ForEach(appState.tasks) { task in
                            DeviceTaskRow(task: task)
                        }
                    }
                }

                Section("附近设备") {
                    if appState.devices.isEmpty {
                        EmptyStateView(
                            systemImage: "radio",
                            title: "未发现设备",
                            message: "请确保对方设备在同一局域网内并已打开本应用，然后点击右上角刷新"
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(appState.devices) { device in
                            NavigationLink(value: device) {
                                DeviceRow(device: device)
                            }
                        }
                    }
                }
            }
            .navigationTitle("设备")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        appState.refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .navigationDestination(for: Device.self) { device in
                DeviceDetailView(device: device)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.deviceType == .desktop ? "desktopcomputer" : "iphone")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName)
                    .font(.headline)
                Text(device.ip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(device.online ? Color.green : Color.gray)
                .frame(width: 9, height: 9)
        }
        .padding(.vertical, 2)
    }
}

private struct DeviceTaskRow: View {
    @EnvironmentObject var appState: AppState
    let task: TransferTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: task.direction == .send ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(Color.accentColor)
                Text(task.currentFileName.isEmpty ? "准备传输" : task.currentFileName)
                    .lineLimit(1)
                Spacer()
                Text(transferStatusText(task.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: task.progress)
            HStack {
                Text(task.peer.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    appState.cancelTask(task.id)
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DeviceDetailView: View {
    @EnvironmentObject var appState: AppState
    let device: Device

    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @State private var showChat = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: device.deviceType == .desktop ? "desktopcomputer" : "iphone")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.accentColor)
                Text(device.displayName)
                    .font(.title2)
                    .bold()
                Text("\(device.ip) · \(device.platform)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            VStack(spacing: 12) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("发送文件", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showFolderImporter = true
                } label: {
                    Label("发送文件夹", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    openChat()
                } label: {
                    Label("发消息", systemImage: "bubble.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                appState.sendFiles(urls, to: device)
            case .failure:
                break
            }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let folder = urls.first {
                    appState.sendFiles([folder], to: device)
                }
            case .failure:
                break
            }
        }
        .navigationDestination(isPresented: $showChat) {
            ChatView(peerId: device.deviceId, peerName: device.displayName)
        }
    }

    private func openChat() {
        let convId = ChatManager.conversationId(appState.selfDeviceId, device.deviceId)
        appState.openConversation(convId, peerId: device.deviceId, peerName: device.displayName)
        showChat = true
    }
}
