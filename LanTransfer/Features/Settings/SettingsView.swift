//
//  SettingsView.swift
//  局域网快传
//
//  应用设置：别名、传输参数、聊天选项与保存位置说明。
//

import SwiftUI
import UIKit

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
                        .onSubmit { hideKeyboard() }
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
                        // 数字键盘没有 return 键，必须用键盘工具栏提供「完成」出口。
                        .toolbar {
                            ToolbarItem(placement: .keyboard) {
                                Button("完成") { hideKeyboard() }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
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

                Section {
                    PromoSloganView()
                }
            }
            // 滚动列表时可交互式收起键盘；数字键盘另有工具栏「完成」按钮。
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设置")
            .onAppear {
                draft = appState.settings
            }
            .alert("已保存", isPresented: $showSaved) {
                Button("好", role: .cancel) {}
            }
        }
    }

    /// 收起当前第一响应者（键盘）。数字键盘无 return 键时必须由工具栏按钮触发。
    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}
