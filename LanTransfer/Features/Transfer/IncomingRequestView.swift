//
//  IncomingRequestView.swift
//  章鱼快传
//
//  接收请求确认弹窗，由 ContentView 根据 appState.incoming 以覆盖层显示。
//

import SwiftUI
import Foundation

struct IncomingRequestView: View {
    @EnvironmentObject var appState: AppState
    let request: IncomingRequest

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.accentColor)

                Text("收到传输请求")
                    .font(.title3)
                    .bold()

                Text("来自 \(request.peer.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(request.files, id: \.fileId) { file in
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text(file.displayName)
                                    .lineLimit(1)
                                Spacer()
                                Text(formatSize(file.size))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)

                HStack {
                    Text("总计 \(formatSize(request.totalSize))")
                        .font(.headline)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Button("拒绝") {
                        appState.acceptIncoming(false)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button("接受") {
                        appState.acceptIncoming(true)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }

                PromoSloganView()
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(24)
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
}
