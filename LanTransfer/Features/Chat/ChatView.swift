//
//  ChatView.swift
//  局域网快传
//
//  聊天窗口：消息气泡、图片展示与底部输入区。
//

import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject var appState: AppState
    let peerId: String
    let peerName: String

    private var conversationId: String {
        ChatManager.conversationId(appState.selfDeviceId, peerId)
    }

    private var messages: [ChatMessage] {
        appState.chatMessages.filter { $0.conversationId == conversationId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            ChatComposer()
        }
        .navigationTitle(peerName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 打开会话：加载历史并清除未读角标。
            appState.openConversation(conversationId, peerId: peerId, peerName: peerName)
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.outgoing { Spacer() }

            VStack(alignment: message.outgoing ? .trailing : .leading, spacing: 4) {
                bubbleContent

                Text(chatTimeText(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.outgoing
                    ? Color.blue
                    : Color.gray.opacity(0.2)
            )
            .foregroundStyle(message.outgoing ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 280, alignment: message.outgoing ? .trailing : .leading)

            if !message.outgoing { Spacer() }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.kind == "IMAGE" {
            if !message.imagePath.isEmpty,
               let uiImage = UIImage(contentsOfFile: message.imagePath) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text(message.imageName.isEmpty ? "图片" : message.imageName)
                        .font(.caption)
                }
            }
        } else {
            Text(message.text)
                .textSelection(.enabled)
        }
    }
}
