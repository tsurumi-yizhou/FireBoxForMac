import Foundation
import SwiftUI
import Client

@Observable
final class ModelOption: Identifiable, Hashable {
    let id: UUID
    var modelId: String
    var name: String
    var supportsImageInput: Bool

    init(id: UUID = UUID(), modelId: String, name: String, supportsImageInput: Bool = false) {
        self.id = id
        self.modelId = modelId
        self.name = name
        self.supportsImageInput = supportsImageInput
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
    var imageData: Data?
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        imageData: Data? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.imageData = imageData
        self.isStreaming = isStreaming
    }
}

@Observable
final class ChatSession: Identifiable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var selectedModel: ModelOption?
    var activeRequestId: Int64?

    init(
        id: UUID = UUID(),
        title: String = String(localized: "demo.session.defaultTitle"),
        messages: [ChatMessage] = [],
        selectedModel: ModelOption? = nil,
        activeRequestId: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.selectedModel = selectedModel
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

    var sessions: [ChatSession] = []
    var selectedSessionID: UUID?
    var availableModels: [ModelOption] = []
    var isBootstrapping = false
    var errorMessage: String?

    private let client = Client()
    private let store = SessionStore()
    private var streamTargets: [Int64: StreamTarget] = [:]

    var selectedSession: ChatSession? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first { $0.id == id }
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
                        supportsImageInput: info.capabilities.inputFormats.contains(.image)
                    )
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            // Restore persisted sessions
            let restored = await store.loadSessions(availableModels: availableModels)
            if !restored.isEmpty {
                sessions = restored
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
        Task { await store.deleteSession(id: sessionId) }
    }

    func sendMessage(sessionId: UUID, text: String, imageData: Data?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageData != nil else { return }

        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) else {
            errorMessage = String(localized: "demo.error.sessionNotFound")
            return
        }
        let session = sessions[sessionIndex]

        guard session.activeRequestId == nil else {
            errorMessage = String(localized: "demo.error.activeStreamExists")
            return
        }
        guard let selectedModel = session.selectedModel else {
            errorMessage = String(localized: "demo.error.noModelSelected")
            return
        }

        let userMessage = ChatMessage(role: .user, content: trimmed, imageData: imageData)
        sessions[sessionIndex].messages.append(userMessage)

        if sessions[sessionIndex].title.hasPrefix(String(localized: "demo.session.autogeneratedPrefix")), !trimmed.isEmpty {
            sessions[sessionIndex].title = String(trimmed.prefix(32))
        }

        // Persist user message immediately
        Task { await store.saveSession(sessions[sessionIndex]) }

        let assistantMessage = ChatMessage(role: .assistant, content: "", isStreaming: true)
        sessions[sessionIndex].messages.append(assistantMessage)

        let requestMessages = sessions[sessionIndex].messages.dropLast().map(Self.toClientMessage(_:))
        let request = Client.ChatCompletionRequest(modelId: selectedModel.modelId, messages: requestMessages)

        do {
            let requestId = try await client.startChatCompletionStream(request: request) { [weak self] event in
                guard let self else { return }
                Task { @MainActor in
                    self.handleStreamEvent(event)
                }
            }
            sessions[sessionIndex].activeRequestId = requestId
            streamTargets[requestId] = StreamTarget(sessionId: sessionId, messageId: assistantMessage.id)
        } catch {
            sessions[sessionIndex].messages.removeAll { $0.id == assistantMessage.id }
            errorMessage = error.localizedDescription
        }
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

        switch event {
        case .started:
            break
        case .delta(_, let text):
            sessions[sessionIndex].messages[messageIndex].content += text
        case .reasoning(_, let text):
            if !text.isEmpty {
                sessions[sessionIndex].messages[messageIndex].content += text
            }
        case .usage:
            break
        case .completed(_, let response):
            sessions[sessionIndex].messages[messageIndex].content = response.message.content
            sessions[sessionIndex].messages[messageIndex].isStreaming = false
        case .error(_, let message):
            sessions[sessionIndex].messages[messageIndex].isStreaming = false
            if sessions[sessionIndex].messages[messageIndex].content.isEmpty {
                sessions[sessionIndex].messages[messageIndex].content = String(format: String(localized: "demo.stream.error.prefix"), locale: .current, message)
            } else {
                sessions[sessionIndex].messages[messageIndex].content += "\n" + String(format: String(localized: "demo.stream.error.prefix"), locale: .current, message)
            }
            errorMessage = message
        case .cancelled:
            sessions[sessionIndex].messages[messageIndex].isStreaming = false
            if sessions[sessionIndex].messages[messageIndex].content.isEmpty {
                sessions[sessionIndex].messages[messageIndex].content = String(localized: "demo.stream.cancelled")
            } else {
                sessions[sessionIndex].messages[messageIndex].content += "\n" + String(localized: "demo.stream.cancelled")
            }
        }

        if event.isTerminal {
            sessions[sessionIndex].activeRequestId = nil
            streamTargets[event.requestId] = nil
            // Persist after stream finishes
            Task { await store.saveSession(sessions[sessionIndex]) }
        }
    }

    private static func toClientMessage(_ message: ChatMessage) -> Client.ChatMessage {
        switch message.role {
        case .assistant:
            return Client.ChatMessage(role: .assistant, content: message.content, attachments: [])
        case .user:
            var attachments: [Client.ChatAttachment] = []
            if let imageData = message.imageData {
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
