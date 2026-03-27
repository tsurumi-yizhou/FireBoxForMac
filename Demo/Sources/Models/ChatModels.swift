import Foundation
import SwiftUI
import Client
import AISDKJSONSchema

@Observable
final class ModelOption: Identifiable, Hashable {
    let id: UUID
    var modelId: String
    var name: String
    var supportsImageInput: Bool
    var supportsReasoning: Bool

    init(
        id: UUID = UUID(),
        modelId: String,
        name: String,
        supportsImageInput: Bool = false,
        supportsReasoning: Bool = false
    ) {
        self.id = id
        self.modelId = modelId
        self.name = name
        self.supportsImageInput = supportsImageInput
        self.supportsReasoning = supportsReasoning
    }

    static func == (lhs: ModelOption, rhs: ModelOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum MessageRole: String {
    case user
    case assistant
}

@Observable
final class ChatMessage: Identifiable {
    let id: UUID
    var role: MessageRole
    var content: String
    var imageDataList: [Data]
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        imageDataList: [Data] = [],
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.imageDataList = imageDataList
        self.isStreaming = isStreaming
    }
}

@Observable
final class ChatSession: Identifiable {
    let id: UUID
    var title: String
    var isTitleLocked: Bool
    var messages: [ChatMessage]
    var selectedModel: ModelOption?
    var selectedReasoningEffort: Client.ReasoningEffort
    var activeRequestId: Int64?

    init(
        id: UUID = UUID(),
        title: String = String(localized: "demo.session.defaultTitle"),
        isTitleLocked: Bool = false,
        messages: [ChatMessage] = [],
        selectedModel: ModelOption? = nil,
        selectedReasoningEffort: Client.ReasoningEffort = .default,
        activeRequestId: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.isTitleLocked = isTitleLocked
        self.messages = messages
        self.selectedModel = selectedModel
        self.selectedReasoningEffort = selectedReasoningEffort
        self.activeRequestId = activeRequestId
    }
}

@MainActor
@Observable
final class DemoState {
    private struct StreamTarget {
        let sessionId: UUID
        let messageId: UUID
    }

    private struct TitleInput: Codable, Sendable {
        var firstUserMessage: String
        var latestAssistantReply: String
    }

    private struct TitleOutput: Codable, Sendable {
        var title: String
    }

    private enum TitleGenerationError: LocalizedError {
        case invalidJSONString
        case emptyTitle

        var errorDescription: String? {
            switch self {
            case .invalidJSONString:
                return "Failed to construct valid JSON string."
            case .emptyTitle:
                return "Generated title is empty."
            }
        }
    }

    struct SearchJumpRequest: Identifiable {
        let id: UUID
        let sessionId: UUID
        let messageId: UUID
    }

    var sessions: [ChatSession] = []
    var selectedSessionID: UUID?
    var availableModels: [ModelOption] = []
    var isBootstrapping = false
    var errorMessage: String?
    var sessionSearchQuery: String = "" {
        didSet {
            scheduleSessionSearch(debounce: true)
        }
    }
    var searchResponse: DemoSearchResponse = .empty
    var pendingSearchJumpRequest: SearchJumpRequest?

    private let client = Client()
    private let store = SessionStore()
    private let searchCoordinator = DemoSearchCoordinator(sources: [LocalSessionSearchSource()])
    private var streamTargets: [Int64: StreamTarget] = [:]
    private var titleGenerationInFlightSessionIDs: Set<UUID> = []
    private var searchTask: Task<Void, Never>?
    private var searchRevision = 0

    private static let maxTitleLength = 32
    private static let titleFunctionName = "generate_conversation_title"

    var selectedSession: ChatSession? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    var displayedSessions: [ChatSession] {
        if trimmedSearchQuery.isEmpty {
            return sessions
        }
        if searchResponse.hits.isEmpty {
            return []
        }

        var seen = Set<UUID>()
        var orderedSessionIDs: [UUID] = []
        for hit in searchResponse.hits {
            guard let sessionID = hit.target.sessionID else { continue }
            if seen.insert(sessionID).inserted {
                orderedSessionIDs.append(sessionID)
            }
        }

        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return orderedSessionIDs.compactMap { sessionsByID[$0] }
    }

    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }

        do {
            try await client.connect()
            let models = try await client.listModels()
            availableModels = models
                .map { info in
                    ModelOption(
                        modelId: info.modelId,
                        name: info.modelId,
                        supportsImageInput: info.capabilities.inputFormats.contains(.image),
                        supportsReasoning: info.capabilities.reasoning
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            // Restore persisted sessions
            let restored = await store.loadSessions(availableModels: availableModels)
            if !restored.isEmpty {
                sessions = restored
                for session in sessions {
                    if let selectedModel = session.selectedModel, !selectedModel.supportsReasoning {
                        session.selectedReasoningEffort = .default
                    }
                }
                selectedSessionID = sessions.first?.id
            }

            if sessions.isEmpty {
                _ = createSession()
            }
            if let current = selectedSession, current.selectedModel == nil {
                current.selectedModel = availableModels.first
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSession() -> ChatSession {
        let session = ChatSession(
            title: String(format: String(localized: "demo.session.title.format"), locale: .current, sessions.count + 1),
            selectedModel: availableModels.first
        )
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        refreshSearchResultsIfNeeded()
        Task { await store.saveSession(session) }
        return session
    }

    func deleteSession(_ session: ChatSession) {
        if let requestId = session.activeRequestId {
            Task {
                do {
                    try await client.cancelChatCompletion(requestId: requestId)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        let sessionId = session.id
        sessions.removeAll { $0.id == sessionId }
        if selectedSessionID == sessionId {
            selectedSessionID = sessions.first?.id
        }
        if pendingSearchJumpRequest?.sessionId == sessionId {
            pendingSearchJumpRequest = nil
        }
        refreshSearchResultsIfNeeded()
        Task { await store.deleteSession(id: sessionId) }
    }

    func selectSessionFromList(_ sessionID: UUID) {
        selectedSessionID = sessionID
        issueSearchJumpIfNeeded(for: sessionID)
    }

    func consumePendingSearchJump(requestID: UUID, sessionID: UUID) {
        guard let request = pendingSearchJumpRequest else { return }
        guard request.id == requestID, request.sessionId == sessionID else { return }
        pendingSearchJumpRequest = nil
    }

    func hasPendingSearchJump(for sessionID: UUID) -> Bool {
        pendingSearchJumpRequest?.sessionId == sessionID
    }

    func sendMessage(sessionId: UUID, text: String, imageDataList: [Data]) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imageDataList.isEmpty else { return }

        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            errorMessage = String(localized: "demo.error.sessionNotFound")
            return
        }

        guard sessions[sessionIndex].activeRequestId == nil else {
            errorMessage = String(localized: "demo.error.activeStreamExists")
            return
        }
        guard sessions[sessionIndex].selectedModel != nil else {
            errorMessage = String(localized: "demo.error.noModelSelected")
            return
        }

        let userMessage = ChatMessage(role: .user, content: trimmed, imageDataList: imageDataList)
        sessions[sessionIndex].messages.append(userMessage)
        refreshSearchResultsIfNeeded()

        // Persist user message immediately
        Task { await store.saveSession(sessions[sessionIndex]) }

        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        sessions[sessionIndex].messages.append(assistantMessage)
        await startAssistantStream(sessionId: sessionId, assistantMessageId: assistantMessage.id)
    }

    func retryMessage(sessionId: UUID, messageId: UUID) async {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            errorMessage = String(localized: "demo.error.sessionNotFound")
            return
        }
        guard sessions[sessionIndex].activeRequestId == nil else {
            errorMessage = String(localized: "demo.error.activeStreamExists")
            return
        }
        guard sessions[sessionIndex].selectedModel != nil else {
            errorMessage = String(localized: "demo.error.noModelSelected")
            return
        }
        guard let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        guard let retryUserIndex = retrySourceUserIndex(session: sessions[sessionIndex], messageIndex: messageIndex) else {
            return
        }

        let retrySource = sessions[sessionIndex].messages[retryUserIndex]
        guard !retrySource.content.isEmpty || !retrySource.imageDataList.isEmpty else {
            return
        }

        let preservedPrefix = Array(sessions[sessionIndex].messages[..<retryUserIndex])
        let retriedUserMessage = ChatMessage(
            role: .user,
            content: retrySource.content,
            imageDataList: retrySource.imageDataList
        )

        sessions[sessionIndex].messages = preservedPrefix + [retriedUserMessage]
        refreshSearchResultsIfNeeded()
        Task { await store.saveSession(sessions[sessionIndex]) }

        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        sessions[sessionIndex].messages.append(assistantMessage)
        await startAssistantStream(sessionId: sessionId, assistantMessageId: assistantMessage.id)
    }

    func deleteMessage(sessionId: UUID, messageId: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return
        }
        guard sessions[sessionIndex].activeRequestId == nil else {
            errorMessage = String(localized: "demo.error.activeStreamExists")
            return
        }
        guard let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }

        var removingIDs: Set<UUID> = [messageId]
        if sessions[sessionIndex].messages[messageIndex].role == .user {
            let nextIndex = messageIndex + 1
            if sessions[sessionIndex].messages.indices.contains(nextIndex),
               sessions[sessionIndex].messages[nextIndex].role == .assistant {
                removingIDs.insert(sessions[sessionIndex].messages[nextIndex].id)
            }
        }

        sessions[sessionIndex].messages.removeAll { removingIDs.contains($0.id) }
        if let pending = pendingSearchJumpRequest,
           pending.sessionId == sessionId,
           !sessions[sessionIndex].messages.contains(where: { $0.id == pending.messageId }) {
            pendingSearchJumpRequest = nil
        }
        refreshSearchResultsIfNeeded()
        Task { await store.saveSession(sessions[sessionIndex]) }
    }

    func cancelStreaming(sessionId: UUID) async {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return
        }
        guard let requestId = sessions[sessionIndex].activeRequestId else {
            return
        }
        do {
            try await client.cancelChatCompletion(requestId: requestId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func handleStreamEvent(_ event: Client.ChatStreamEvent) {
        guard let target = streamTargets[event.requestId],
              let sessionIndex = sessions.firstIndex(where: { $0.id == target.sessionId }) else {
            return
        }
        guard let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == target.messageId }) else {
            return
        }

        var didMutateSearchableContent = false
        var titleGenerationTrigger: (sessionId: UUID, latestAssistantReply: String)?
        switch event {
        case .started:
            break
        case .delta(_, let text):
            sessions[sessionIndex].messages[messageIndex].content += text
            didMutateSearchableContent = !text.isEmpty
        case .reasoning(_, let text):
            if !text.isEmpty {
                sessions[sessionIndex].messages[messageIndex].content += text
                didMutateSearchableContent = true
            }
        case .usage:
            break
        case .completed(_, let response):
            sessions[sessionIndex].messages[messageIndex].content = response.message.content
            sessions[sessionIndex].messages[messageIndex].isStreaming = false
            didMutateSearchableContent = true
            titleGenerationTrigger = (target.sessionId, response.message.content)
        case .error(_, let message):
            sessions[sessionIndex].messages[messageIndex].isStreaming = false
            if sessions[sessionIndex].messages[messageIndex].content.isEmpty {
                sessions[sessionIndex].messages[messageIndex].content = String(format: String(localized: "demo.stream.error.prefix"), locale: .current, message)
            } else {
                sessions[sessionIndex].messages[messageIndex].content += "\n" + String(format: String(localized: "demo.stream.error.prefix"), locale: .current, message)
            }
            errorMessage = message
            didMutateSearchableContent = true
        case .cancelled:
            sessions[sessionIndex].messages[messageIndex].isStreaming = false
            if sessions[sessionIndex].messages[messageIndex].content.isEmpty {
                sessions[sessionIndex].messages[messageIndex].content = String(localized: "demo.stream.cancelled")
            } else {
                sessions[sessionIndex].messages[messageIndex].content += "\n" + String(localized: "demo.stream.cancelled")
            }
            didMutateSearchableContent = true
        }

        if didMutateSearchableContent {
            refreshSearchResultsIfNeeded()
        }

        if event.isTerminal {
            sessions[sessionIndex].activeRequestId = nil
            streamTargets[event.requestId] = nil
            // Persist after stream finishes
            Task { await store.saveSession(sessions[sessionIndex]) }

            if let titleGenerationTrigger {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.generateTitleIfNeeded(
                        sessionId: titleGenerationTrigger.sessionId,
                        latestAssistantReply: titleGenerationTrigger.latestAssistantReply
                    )
                }
            }
        }
    }

    private func generateTitleIfNeeded(sessionId: UUID, latestAssistantReply: String) async {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return
        }
        guard !sessions[sessionIndex].isTitleLocked else {
            return
        }
        guard !titleGenerationInFlightSessionIDs.contains(sessionId) else {
            return
        }
        guard let modelId = sessions[sessionIndex].selectedModel?.modelId else {
            return
        }
        guard let firstUserMessage = firstUserMessageText(in: sessions[sessionIndex]) else {
            return
        }

        let normalizedAssistantReply = Self.compactWhitespaces(
            latestAssistantReply.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !normalizedAssistantReply.isEmpty else {
            applyFallbackTitle(sessionId: sessionId)
            return
        }

        titleGenerationInFlightSessionIDs.insert(sessionId)
        defer {
            titleGenerationInFlightSessionIDs.remove(sessionId)
        }

        do {
            let input = TitleInput(
                firstUserMessage: firstUserMessage,
                latestAssistantReply: normalizedAssistantReply
            )
            let request = try makeTitleFunctionRequest(modelId: modelId, input: input)
            let response = try await client.callFunction(request: request)
            let output: TitleOutput = try decodeFromJSONString(response.outputJson, as: TitleOutput.self)
            let cleanedTitle = Self.sanitizeGeneratedTitle(output.title, maxLength: Self.maxTitleLength)
            guard !cleanedTitle.isEmpty else {
                throw TitleGenerationError.emptyTitle
            }

            guard let latestSessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
                return
            }
            sessions[latestSessionIndex].title = cleanedTitle
            sessions[latestSessionIndex].isTitleLocked = true
            refreshSearchResultsIfNeeded()
            Task { await store.saveSession(sessions[latestSessionIndex]) }
        } catch {
            applyFallbackTitle(sessionId: sessionId)
        }
    }

    private func makeTitleFunctionRequest(modelId: String, input: TitleInput) throws -> Client.FunctionCallRequest {
        let functionDescription = """
        Generate a concise conversation title.
        Rules:
        - Return strictly valid JSON object with key "title".
        - Use the same language as the user input when possible.
        - Keep title specific and short.
        - Do not include surrounding quotes.
        - Maximum length: \(Self.maxTitleLength) characters.
        """

        return Client.FunctionCallRequest(
            modelId: modelId,
            functionName: Self.titleFunctionName,
            functionDescription: functionDescription,
            inputJson: try encodeToJSONString(input),
            inputSchemaJson: try schemaJSONString(for: TitleInput.self),
            outputSchemaJson: try schemaJSONString(for: TitleOutput.self),
            temperature: 0.2,
            maxOutputTokens: 64
        )
    }

    private func applyFallbackTitle(sessionId: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return
        }
        guard let fallback = fallbackTitle(for: sessions[sessionIndex]) else {
            return
        }
        if sessions[sessionIndex].title == fallback {
            return
        }
        sessions[sessionIndex].title = fallback
        refreshSearchResultsIfNeeded()
        Task { await store.saveSession(sessions[sessionIndex]) }
    }

    private func fallbackTitle(for session: ChatSession) -> String? {
        guard let firstUserMessage = firstUserMessageText(in: session) else {
            return nil
        }
        let fallback = String(firstUserMessage.prefix(Self.maxTitleLength))
        return fallback.isEmpty ? nil : fallback
    }

    private func firstUserMessageText(in session: ChatSession) -> String? {
        for message in session.messages where message.role == .user {
            let normalized = Self.compactWhitespaces(
                message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }

    private func encodeToJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TitleGenerationError.invalidJSONString
        }
        return json
    }

    private func decodeFromJSONString<T: Decodable>(_ jsonString: String, as type: T.Type) throws -> T {
        guard let data = jsonString.data(using: .utf8) else {
            throw TitleGenerationError.invalidJSONString
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func schemaJSONString<T: Codable & Sendable>(for type: T.Type) throws -> String {
        let schema = JSONSchemaGenerator.generate(for: type)
        return try encodeToJSONString(schema)
    }

    private static func sanitizeGeneratedTitle(_ rawTitle: String, maxLength: Int) -> String {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrapperPairs: [(Character, Character)] = [
            ("\"", "\""),
            ("'", "'"),
            ("`", "`"),
        ]

        while title.count >= 2, let first = title.first, let last = title.last {
            if wrapperPairs.contains(where: { $0.0 == first && $0.1 == last }) {
                title.removeFirst()
                title.removeLast()
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                break
            }
        }

        title = compactWhitespaces(title)
        if title.count > maxLength {
            title = String(title.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }

    private static func compactWhitespaces(_ input: String) -> String {
        input.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var trimmedSearchQuery: String {
        sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshSearchResultsIfNeeded() {
        guard !trimmedSearchQuery.isEmpty else { return }
        scheduleSessionSearch(debounce: false)
    }

    private func makeSearchRequest(query: String) -> DemoSearchRequest {
        let snapshots = sessions.enumerated().map { index, session in
            DemoSearchSessionSnapshot(
                id: session.id,
                order: index,
                title: session.title,
                messages: session.messages.map {
                    DemoSearchMessageSnapshot(id: $0.id, content: $0.content)
                }
            )
        }
        return DemoSearchRequest(query: query, limit: nil, sessionSnapshot: snapshots)
    }

    private func scheduleSessionSearch(debounce: Bool) {
        searchTask?.cancel()
        searchRevision += 1
        let revision = searchRevision
        let query = trimmedSearchQuery

        guard !query.isEmpty else {
            searchResponse = .empty
            return
        }

        let request = makeSearchRequest(query: query)
        let coordinator = searchCoordinator
        searchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            if Task.isCancelled {
                return
            }

            let response = await coordinator.search(request)
            if Task.isCancelled {
                return
            }

            await MainActor.run {
                guard let self else { return }
                guard self.searchRevision == revision else { return }
                self.searchResponse = response
            }
        }
    }

    private func issueSearchJumpIfNeeded(for sessionID: UUID) {
        guard !trimmedSearchQuery.isEmpty else { return }

        for hit in searchResponse.hits {
            guard case .session(let targetSessionID, let messageID) = hit.target else { continue }
            guard targetSessionID == sessionID else { continue }
            guard let messageID else { continue }

            pendingSearchJumpRequest = SearchJumpRequest(
                id: UUID(),
                sessionId: sessionID,
                messageId: messageID
            )
            return
        }
    }

    private func retrySourceUserIndex(session: ChatSession, messageIndex: Int) -> Int? {
        guard session.messages.indices.contains(messageIndex) else {
            return nil
        }
        if session.messages[messageIndex].role == .user {
            return messageIndex
        }
        return session.messages[..<messageIndex].lastIndex(where: { $0.role == .user })
    }

    private func startAssistantStream(sessionId: UUID, assistantMessageId: UUID) async {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return
        }
        guard let selectedModel = sessions[sessionIndex].selectedModel else {
            sessions[sessionIndex].messages.removeAll { $0.id == assistantMessageId }
            errorMessage = String(localized: "demo.error.noModelSelected")
            refreshSearchResultsIfNeeded()
            return
        }
        guard let assistantIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == assistantMessageId }) else {
            return
        }

        let requestMessages = sessions[sessionIndex].messages[..<assistantIndex].map(Self.toClientMessage(_:))
        let reasoningEffort: Client.ReasoningEffort = selectedModel.supportsReasoning
            ? sessions[sessionIndex].selectedReasoningEffort
            : .default
        let request = Client.ChatCompletionRequest(
            modelId: selectedModel.modelId,
            messages: requestMessages,
            reasoningEffort: reasoningEffort
        )

        do {
            let requestId = try await client.startChatCompletionStream(request: request) { [weak self] event in
                guard let self else { return }
                Task { @MainActor in
                    self.handleStreamEvent(event)
                }
            }
            guard let latestSessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
                return
            }
            sessions[latestSessionIndex].activeRequestId = requestId
            streamTargets[requestId] = StreamTarget(sessionId: sessionId, messageId: assistantMessageId)
        } catch {
            if let latestSessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[latestSessionIndex].messages.removeAll { $0.id == assistantMessageId }
                Task { await store.saveSession(sessions[latestSessionIndex]) }
            }
            errorMessage = error.localizedDescription
            refreshSearchResultsIfNeeded()
        }
    }

    private static func toClientMessage(_ message: ChatMessage) -> Client.ChatMessage {
        switch message.role {
        case .assistant:
            return Client.ChatMessage(role: .assistant, content: message.content, attachments: [])
        case .user:
            var attachments: [Client.ChatAttachment] = []
            for imageData in message.imageDataList {
                attachments.append(
                    Client.ChatAttachment(
                        mediaFormat: .image,
                        mimeType: "image/png",
                        fileName: nil,
                        data: imageData,
                        sizeBytes: Int64(imageData.count)
                    )
                )
            }
            return Client.ChatMessage(role: .user, content: message.content, attachments: attachments)
        }
    }
}
