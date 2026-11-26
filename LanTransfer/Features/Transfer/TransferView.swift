//
//  TransferView.swift
//  局域网快传
//
//  进行中任务与历史传输记录。
//

import SwiftUI
import Foundation

struct TransferView: View {
    @EnvironmentObject var appState: AppState
    @State private var segment: Int = 0
    @State private var selectedIds: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("传输", selection: $segment) {
                    Text("进行中").tag(0)
                    Text("传输记录").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if segment == 0 {
                    activeTaskList
                } else {
                    recordList
                }

                PromoSloganView()
                    .padding(.bottom, 6)
            }
            .navigationTitle("传输")
            .toolbar {
                if segment == 1 && !selectedIds.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("删除") {
                            appState.deleteRecords(selectedIds)
                            selectedIds.removeAll()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 进行中

    private var activeTaskList: some View {
        Group {
            if appState.tasks.isEmpty {
                EmptyStateView(
                    systemImage: "arrow.left.arrow.right",
                    title: "暂无进行中的传输",
                    message: "从设备页选择文件或文件夹开始传输"
                )
            } else {
                List(appState.tasks) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: task.direction == .send ? "arrow.up.circle" : "arrow.down.circle")
                                .foregroundStyle(Color.accentColor)
                            Text(currentName(of: task))
                                .lineLimit(1)
                            Spacer()
                            Text(transferStatusText(task.status))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: task.progress)
                        HStack {
                            Text("已传 \(formatSize(task.transferredBytes)) / \(formatSize(task.totalSize))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatSpeed(task.speedBps))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            appState.cancelTask(task.id)
                        } label: {
                            Text("取消")
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - 传输记录

    private var recordList: some View {
        Group {
            if appState.records.isEmpty {
                EmptyStateView(
                    systemImage: "clock.arrow.circlepath",
                    title: "暂无传输记录",
                    message: "完成一次传输后，记录会显示在这里"
                )
            } else {
                List {
                    ForEach(appState.records) { record in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                toggleSelection(record.id)
                            } label: {
                                Image(systemName: selectedIds.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIds.contains(record.id) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.fileName)
                                    .font(.headline)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(record.direction == .send ? "发送" : "接收")
                                    Text("·")
                                    Text(transferStatusText(record.status))
                                    Text("·")
                                    Text(formatSize(record.fileSize))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Text("\(record.peerName) · \(formatSpeed(record.avgSpeedBps)) · \(timestampText(record.timestamp))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button("打开") {
                                appState.openFile(record.localPath)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func currentName(of task: TransferTask) -> String {
        if !task.currentFileName.isEmpty { return task.currentFileName }
        return task.files.first?.displayName ?? "传输任务"
    }

    // MARK: - 格式化（本文件内）

    private func formatSpeed(_ bytesPerSec: Int64) -> String {
        if bytesPerSec < 1024 {
            return "\(bytesPerSec) B/s"
        } else if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1f KB/s", Double(bytesPerSec) / 1024.0)
        } else {
            return String(format: "%.2f MB/s", Double(bytesPerSec) / (1024.0 * 1024.0))
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        } else {
            return String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024.0 * 1024.0))
        }
    }

    private func timestampText(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
