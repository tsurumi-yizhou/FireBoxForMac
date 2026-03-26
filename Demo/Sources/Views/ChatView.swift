import SwiftUI
import Client

struct ChatView: View {
    @Bindable var state: DemoState
    @Bindable var session: ChatSession
    var availableModels: [ModelOption]

    @State private var inputText = ""
    @State private var attachedImageDataList: [Data] = []
    @State private var showingFilePicker = false

    private var currentModelSupportsImage: Bool {
        session.selectedModel?.supportsImageInput ?? false
    }

    private var currentModelSupportsReasoning: Bool {
        session.selectedModel?.supportsReasoning ?? false
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
            ToolbarItem {
                Picker("Thinking", selection: $session.selectedReasoningEffort) {
                    Text("Default").tag(Client.ReasoningEffort.default)
                    Text("Low").tag(Client.ReasoningEffort.low)
                    Text("Medium").tag(Client.ReasoningEffort.medium)
                    Text("High").tag(Client.ReasoningEffort.high)
                }
                .frame(minWidth: 130)
                .disabled(!currentModelSupportsReasoning)
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
                attachedImageDataList.removeAll()
            }
            if !currentModelSupportsReasoning {
                session.selectedReasoningEffort = .default
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                var loaded: [Data] = []
                for url in urls {
                    if url.startAccessingSecurityScopedResource() {
                        if let data = try? Data(contentsOf: url) {
                            loaded.append(data)
                        }
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                if !loaded.isEmpty {
                    attachedImageDataList.append(contentsOf: loaded)
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
            if !attachedImageDataList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachedImageDataList.enumerated()), id: \.offset) { index, imageData in
                            if let nsImage = NSImage(data: imageData) {
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Button(action: {
                                        if attachedImageDataList.indices.contains(index) {
                                            attachedImageDataList.remove(at: index)
                                        }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .background(.background, in: Circle())
                                    .offset(x: 6, y: -6)
                                }
                            }
                        }
                    }
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
                            (inputText.isEmpty && attachedImageDataList.isEmpty) || hasActiveStream
                                ? Color.secondary : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled((inputText.isEmpty && attachedImageDataList.isEmpty) || hasActiveStream)
                .padding(.bottom, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func sendMessage() {
        guard !inputText.isEmpty || !attachedImageDataList.isEmpty else { return }

        let text = inputText
        let imageDataList = attachedImageDataList
        inputText = ""
        attachedImageDataList.removeAll()

        Task {
            await state.sendMessage(sessionId: session.id, text: text, imageDataList: imageDataList)
        }
    }
}

// MARK: - Message Row

private struct MessageRow: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                bubble

                if message.isStreaming {
                    streamingIndicator
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.imageDataList.enumerated()), id: \.offset) { _, imageData in
                if let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            if !message.content.isEmpty {
                if !isUser && !message.isStreaming {
                    if let attributed = try? AttributedString(markdown: message.content) {
                        Text(attributed)
                    } else {
                        Text(message.content)
                    }
                } else {
                    Text(message.content)
                }
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isUser ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
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
