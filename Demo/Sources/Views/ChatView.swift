import SwiftUI
import Textual

struct ChatView: View {
    @Bindable var state: DemoState
    @Bindable var session: ChatSession
    var availableModels: [ModelOption]

    @State private var inputText = ""
    @State private var attachedImageData: Data?
    @State private var showingFilePicker = false

    private var currentModelSupportsImage: Bool {
        session.selectedModel?.supportsImageInput ?? false
    }

    private var hasActiveStream: Bool {
        session.activeRequestId != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = state.errorMessage {
                errorBanner(error)
            }
            messageList
            Divider()
            inputBar
        }
        .toolbar {
            ToolbarItem {
                Picker("demo.common.model", selection: $session.selectedModel) {
                    ForEach(availableModels) { model in
                        Text(model.name).tag(model as ModelOption?)
                    }
                }
                .frame(minWidth: 200)
            }
            if hasActiveStream {
                ToolbarItem {
                    Button("demo.chat.stop") {
                        Task {
                            await state.cancelStreaming(sessionId: session.id)
                        }
                    }
                }
            }
        }
        .navigationTitle(session.title)
        .onChange(of: session.selectedModel) {
            if !currentModelSupportsImage {
                attachedImageData = nil
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                if url.startAccessingSecurityScopedResource() {
                    attachedImageData = try? Data(contentsOf: url)
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("demo.common.dismiss") { state.clearError() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.red.opacity(0.08))
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(session.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: session.messages.last?.content) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: session.messages.count) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastId = session.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let imageData = attachedImageData, let nsImage = NSImage(data: imageData) {
                HStack(spacing: 6) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button(action: { self.attachedImageData = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                if currentModelSupportsImage {
                    Button(action: { showingFilePicker = true }) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                }

                TextField("demo.chat.messagePlaceholder", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.background.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onSubmit { sendMessage() }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(
                            (inputText.isEmpty && attachedImageData == nil) || hasActiveStream
                                ? Color.secondary : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled((inputText.isEmpty && attachedImageData == nil) || hasActiveStream)
                .padding(.bottom, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func sendMessage() {
        guard !inputText.isEmpty || attachedImageData != nil else { return }

        let text = inputText
        let imageData = attachedImageData
        inputText = ""
        attachedImageData = nil

        Task {
            await state.sendMessage(sessionId: session.id, text: text, imageData: imageData)
        }
    }
}

// MARK: - Message Row

private struct MessageRow: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 60) }

            if !isUser {
                avatar
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                bubble

                if message.isStreaming {
                    streamingIndicator
                }
            }

            if isUser {
                avatar
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.vertical, 4)
    }

    private var avatar: some View {
        Image(systemName: isUser ? "person.circle.fill" : "cpu.fill")
            .font(.system(size: 22))
            .foregroundStyle(isUser ? .blue : .secondary)
            .frame(width: 28, height: 28)
            .padding(.top, 2)
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let imageData = message.imageData, let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !message.content.isEmpty {
                if !isUser && !message.isStreaming {
                    StructuredText(markdown: message.content)
                        .textSelection(.enabled)
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isUser ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var streamingIndicator: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(0.6)
            }
        }
        .padding(.leading, 4)
    }
}
