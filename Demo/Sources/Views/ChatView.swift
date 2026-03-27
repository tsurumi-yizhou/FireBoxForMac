import SwiftUI
import Client
import Textual

private enum ChatImageCache {
    private static let cache: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        cache.countLimit = 512
        return cache
    }()

    static func image(from data: Data) -> NSImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let decoded = NSImage(data: data) else {
            return nil
        }
        cache.setObject(decoded, forKey: key, cost: data.count)
        return decoded
    }
}

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

    private struct MessageRowItem: Identifiable {
        let id: UUID
        let message: ChatMessage
        let canRetryWhenIdle: Bool
    }

    private var messageRowItems: [MessageRowItem] {
        var seenUserMessage = false
        var result: [MessageRowItem] = []
        result.reserveCapacity(session.messages.count)

        for message in session.messages {
            let canRetryWhenIdle: Bool
            if message.isStreaming {
                canRetryWhenIdle = false
            } else if message.role == .user {
                canRetryWhenIdle = true
            } else {
                canRetryWhenIdle = seenUserMessage
            }

            result.append(
                MessageRowItem(
                    id: message.id,
                    message: message,
                    canRetryWhenIdle: canRetryWhenIdle
                )
            )

            if message.role == .user {
                seenUserMessage = true
            }
        }

        return result
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
                Task(priority: .userInitiated) {
                    let loaded = await Self.loadImageData(from: urls)
                    guard !loaded.isEmpty else { return }
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
                    ForEach(messageRowItems) { item in
                        MessageRow(
                            message: item.message,
                            canRetry: !hasActiveStream && item.canRetryWhenIdle,
                            canDelete: !hasActiveStream,
                            onRetry: { retryMessage(messageID: item.id) },
                            onDelete: { deleteMessage(messageID: item.id) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: session.messages.last?.content) {
                if state.hasPendingSearchJump(for: session.id) {
                    return
                }
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: session.messages.last?.reasoningContent) {
                if state.hasPendingSearchJump(for: session.id) {
                    return
                }
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: session.messages.count) {
                if state.hasPendingSearchJump(for: session.id) {
                    return
                }
                scrollToBottom(proxy: proxy)
            }
            .task(id: state.pendingSearchJumpRequest?.id) {
                scrollToSearchMatch(proxy: proxy)
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

    private func scrollToSearchMatch(proxy: ScrollViewProxy) {
        guard let request = state.pendingSearchJumpRequest else {
            return
        }
        guard request.sessionId == session.id else {
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(request.messageId, anchor: .center)
        }
        state.consumePendingSearchJump(requestID: request.id, sessionID: session.id)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachedImageDataList.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(attachedImageDataList.enumerated()), id: \.offset) { index, imageData in
                            if let nsImage = ChatImageCache.image(from: imageData) {
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

                if hasActiveStream {
                    Button(action: stopStreaming) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "demo.chat.stop"))
                    .padding(.bottom, 1)
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(
                                (inputText.isEmpty && attachedImageDataList.isEmpty)
                                    ? Color.secondary : Color.accentColor
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.isEmpty && attachedImageDataList.isEmpty)
                    .padding(.bottom, 1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func sendMessage() {
        guard !hasActiveStream else { return }
        guard !inputText.isEmpty || !attachedImageDataList.isEmpty else { return }

        let text = inputText
        let imageDataList = attachedImageDataList
        inputText = ""
        attachedImageDataList.removeAll()

        Task {
            await state.sendMessage(sessionId: session.id, text: text, imageDataList: imageDataList)
        }
    }

    private func stopStreaming() {
        Task {
            await state.cancelStreaming(sessionId: session.id)
        }
    }

    private func retryMessage(messageID: UUID) {
        guard !hasActiveStream else { return }
        Task {
            await state.retryMessage(sessionId: session.id, messageId: messageID)
        }
    }

    private func deleteMessage(messageID: UUID) {
        guard !hasActiveStream else { return }
        state.deleteMessage(sessionId: session.id, messageId: messageID)
    }

    private static func loadImageData(from urls: [URL]) async -> [Data] {
        await withTaskGroup(of: Data?.self, returning: [Data].self) { group in
            for url in urls {
                group.addTask {
                    guard url.startAccessingSecurityScopedResource() else {
                        return nil
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    return try? Data(contentsOf: url)
                }
            }

            var loaded: [Data] = []
            for await data in group {
                if let data {
                    loaded.append(data)
                }
            }
            return loaded
        }
    }
}

// MARK: - Message Row

private struct MessageRow: View {
    let message: ChatMessage
    let canRetry: Bool
    let canDelete: Bool
    let onRetry: () -> Void
    let onDelete: () -> Void

    private var isUser: Bool { message.role == .user }
    @State private var isHovering = false
    @State private var preparedAssistantContent: String
    @State private var preparedAssistantReasoningContent: String
    @State private var isReasoningExpanded: Bool
    private static let markdownParser = AttributedStringMarkdownParser(
        baseURL: nil,
        options: .init(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
    )

    init(
        message: ChatMessage,
        canRetry: Bool,
        canDelete: Bool,
        onRetry: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.message = message
        self.canRetry = canRetry
        self.canDelete = canDelete
        self.onRetry = onRetry
        self.onDelete = onDelete
        _preparedAssistantContent = State(initialValue: Self.preparedSource(for: message))
        _preparedAssistantReasoningContent = State(initialValue: Self.preparedReasoningSource(for: message))
        _isReasoningExpanded = State(initialValue: message.isStreaming)
    }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                bubble

                if message.isStreaming {
                    streamingIndicator
                }
            }
            .overlay(alignment: isUser ? .topLeading : .topTrailing) {
                messageActions
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: message.content) {
            refreshPreparedAssistantContent()
        }
        .onChange(of: message.reasoningContent) {
            refreshPreparedAssistantContent()
            if message.isStreaming && !message.reasoningContent.isEmpty {
                isReasoningExpanded = true
            }
        }
        .onChange(of: message.isStreaming) {
            refreshPreparedAssistantContent()
        }
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(message.imageDataList.enumerated()), id: \.offset) { _, imageData in
                if let nsImage = ChatImageCache.image(from: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            reasoningSection

            if !message.content.isEmpty {
                if !isUser && !message.isStreaming {
                    StructuredText(
                        preparedAssistantContent,
                        parser: Self.markdownParser
                    )
                    .textual.textSelection(.enabled)
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

    @ViewBuilder
    private var reasoningSection: some View {
        if !isUser && !message.reasoningContent.isEmpty {
            DisclosureGroup(
                isExpanded: $isReasoningExpanded,
                content: {
                    if message.isStreaming {
                        Text(message.reasoningContent)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    } else {
                        StructuredText(
                            preparedAssistantReasoningContent,
                            parser: Self.markdownParser
                        )
                        .textual.textSelection(.enabled)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }
                },
                label: {
                    Label(String(localized: "demo.chat.thinking"), systemImage: "brain")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            )
        }
    }

    private static func preparedSource(for message: ChatMessage) -> String {
        guard message.role == .assistant, !message.isStreaming, !message.content.isEmpty else {
            return ""
        }
        return sourceWithPreservedSoftBreaks(message.content)
    }

    private static func preparedReasoningSource(for message: ChatMessage) -> String {
        guard message.role == .assistant, !message.isStreaming, !message.reasoningContent.isEmpty else {
            return ""
        }
        return sourceWithPreservedSoftBreaks(message.reasoningContent)
    }

    private func refreshPreparedAssistantContent() {
        preparedAssistantContent = Self.preparedSource(for: message)
        preparedAssistantReasoningContent = Self.preparedReasoningSource(for: message)
    }

    private static func sourceWithPreservedSoftBreaks(_ content: String) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else { return normalized }

        var result = ""
        var insideFence = false

        for index in lines.indices {
            let line = lines[index]
            let trimmedCurrent = line.trimmingCharacters(in: .whitespaces)
            let currentIsFenceLine = isFenceDelimiter(trimmedCurrent)
            if currentIsFenceLine {
                insideFence.toggle()
            }

            result += line
            guard index < lines.count - 1 else { continue }

            let next = lines[index + 1]
            let trimmedNext = next.trimmingCharacters(in: .whitespaces)
            let keepSoftBreak =
                currentIsFenceLine ||
                insideFence ||
                line.isEmpty ||
                next.isEmpty ||
                line.hasSuffix("  ") ||
                line.hasSuffix("\\") ||
                startsMarkdownBlock(trimmedNext)

            result += keepSoftBreak ? "\n" : "  \n"
        }

        return result
    }

    private static func isFenceDelimiter(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
    }

    private static func startsMarkdownBlock(_ trimmedLine: String) -> Bool {
        guard !trimmedLine.isEmpty else { return false }
        if trimmedLine.hasPrefix("#") { return true }
        if trimmedLine.hasPrefix(">") { return true }
        if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ") { return true }
        if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") { return true }
        if trimmedLine.hasPrefix("|") { return true }
        if isHorizontalRule(trimmedLine) { return true }
        if isOrderedListMarker(trimmedLine) { return true }
        return false
    }

    private static func isOrderedListMarker(_ trimmedLine: String) -> Bool {
        var index = trimmedLine.startIndex
        while index < trimmedLine.endIndex, trimmedLine[index].isNumber {
            index = trimmedLine.index(after: index)
        }
        guard index > trimmedLine.startIndex, index < trimmedLine.endIndex else {
            return false
        }

        let marker = trimmedLine[index]
        guard marker == "." || marker == ")" else {
            return false
        }

        let nextIndex = trimmedLine.index(after: index)
        guard nextIndex < trimmedLine.endIndex else {
            return false
        }
        return trimmedLine[nextIndex].isWhitespace
    }

    private static func isHorizontalRule(_ trimmedLine: String) -> Bool {
        let compact = trimmedLine.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        if compact.allSatisfy({ $0 == "-" }) { return true }
        if compact.allSatisfy({ $0 == "*" }) { return true }
        if compact.allSatisfy({ $0 == "_" }) { return true }
        return false
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

    private var messageActions: some View {
        HStack(spacing: 4) {
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(!canRetry)
            .help(String(localized: "demo.chat.retry"))
            .accessibilityLabel(Text("demo.chat.retry"))

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
            .help(String(localized: "demo.common.delete"))
            .accessibilityLabel(Text("demo.common.delete"))
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.background, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .offset(x: isUser ? -8 : 8, y: -6)
        .opacity((isHovering && (canRetry || canDelete)) ? 1 : 0)
        .allowsHitTesting(isHovering && (canRetry || canDelete))
    }
}
