//
//  ChatComposer.swift
//  章鱼快传
//
//  聊天输入区：文本输入、图片选择、粘贴图片与发送。
//

import SwiftUI
import PhotosUI
import UIKit

struct ChatComposer: View {
    @EnvironmentObject var appState: AppState

    @State private var text: String = ""
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem? = nil

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedText.isEmpty && text.count <= CHAT_MAX_TEXT_CHARS
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("输入消息…", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4)

                Button {
                    sendText()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            }

            HStack(spacing: 16) {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("图片", systemImage: "photo")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Button {
                    pasteImage()
                } label: {
                    Label("粘贴图片", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                if text.count > CHAT_MAX_TEXT_CHARS {
                    Text("超出 \(CHAT_MAX_TEXT_CHARS) 字上限")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("\(text.count)/\(CHAT_MAX_TEXT_CHARS)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { newItem in
            guard let newItem else { return }
            Task { @MainActor in
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    appState.sendImage(saveToTemporaryFile(image))
                }
                selectedPhoto = nil
            }
        }
    }

    private func sendText() {
        guard canSend else { return }
        appState.sendText(trimmedText)
        text = ""
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image else { return }
        appState.sendImage(saveToTemporaryFile(image))
    }

    private func saveToTemporaryFile(_ image: UIImage) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-image-\(UUID().uuidString).jpg")
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: url)
        }
        return url
    }
}
