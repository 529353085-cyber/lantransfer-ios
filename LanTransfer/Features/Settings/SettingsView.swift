//
//  SettingsView.swift
//  局域网快传
//
//  应用设置：别名、传输参数、聊天选项与保存位置说明。
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var draft: Settings = Settings()
    @State private var showSaved = false

    private let chunkOptions = [1, 2, 4, 8, 16]

    var body: some View {
        NavigationStack {
            Form {
                Section("设备") {
                    TextField("设备别名", text: $draft.deviceAlias)
                    Text("对方设备列表中将显示此别名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("传输") {
                    Picker("分块大小", selection: $draft.chunkSizeMB) {
                        ForEach(chunkOptions, id: \.self) { size in
                            Text("\(size) MB").tag(size)
                        }
                    }

                    Stepper("并发数：\(draft.concurrency)",
                            value: $draft.concurrency,
                            in: MIN_CONCURRENCY...MAX_CONCURRENCY)

                    TextField("限速（KB/s，0 表示不限速）",
                              value: $draft.speedLimitKBps,
                              format: .number)
                        .keyboardType(.numberPad)
                }

                Section("聊天") {
                    Toggle("自动接收图片", isOn: $draft.chatAutoAcceptImages)
                }

                Section("保存位置") {
                    Text("iOS 保存位置为 App Documents，可通过文件 App 访问")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !draft.saveDir.isEmpty {
                        Text(draft.saveDir)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("保存设置") {
                        appState.updateSettings(draft)
                        showSaved = true
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("设置")
            .onAppear {
                draft = appState.settings
            }
            .alert("已保存", isPresented: $showSaved) {
                Button("好", role: .cancel) {}
            }
        }
    }
}
