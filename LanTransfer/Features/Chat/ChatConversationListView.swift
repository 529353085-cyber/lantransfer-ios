//
//  ChatConversationListView.swift
//  局域网快传
//
//  会话列表：显示对方名称、最后一条消息、时间与未读角标。
//

import SwiftUI
import Foundation

/// 聊天时间戳文案（internal，供聊天窗口复用）。
func chatTimeText(_ milliseconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000.0)
    let formatter = DateFormatter()
    if Calendar.current.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
    } else {
        formatter.dateFormat = "MM-dd"
    }
    return formatter.string(from: date)
}

struct ChatConversationListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if appState.conversations.isEmpty {
                        EmptyStateView(
                            systemImage: "bubble.left.and.bubble.right",
                            title: "暂无会话",
                            message: "在设备页点击「发消息」即可开始聊天"
                        )
                    } else {
                        List {
                            ForEach(appState.conversations) { conversation in
                                NavigationLink(value: conversation) {
                                    ConversationRow(summary: conversation)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }

                PromoSloganView()
                    .padding(.bottom, 8)
            }
            .navigationTitle("聊天")
            .navigationDestination(for: ConversationSummary.self) { summary in
                ChatView(peerId: summary.peerId, peerName: summary.peerName)
            }
        }
    }
}

private struct ConversationRow: View {
    let summary: ConversationSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.peerName)
                    .font(.headline)
                Text(summary.lastText.isEmpty ? "暂无消息" : summary.lastText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(chatTimeText(summary.lastTs))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if summary.unread > 0 {
                    Text("\(summary.unread)")
                        .font(.caption2)
                        .bold()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }
}
