import Foundation
import Client

// MARK: - JSONL Wire Types

/// Each line in a .jsonl session file is one of these event types.
/// Format follows the common agent/chat-log convention:
///   Line 0:  {"type":"session_header", ...}
///   Line 1+: {"type":"message", ...}
struct SessionHeaderRecord: Codable {
    let type: String // "session_header"
    let sessionId: String
    var title: String
    var isTitleLocked: Bool?
    var modelId: String?
    var reasoningEffortRawValue: Int32?
    let createdAt: String // ISO-8601
    var updatedAt: String

    init(session: ChatSession) {
        self.type = "session_header"
        self.sessionId = session.id.uuidString
        self.title = session.title
        self.isTitleLocked = session.isTitleLocked
        self.modelId = session.selectedModel?.modelId
        self.reasoningEffortRawValue = session.selectedReasoningEffort.rawValue
        self.createdAt = ISO8601DateFormatter().string(from: Date())
        self.updatedAt = self.createdAt
    }
}

struct MessageRecord: Codable {
    let type: String // "message"
    let messageId: String
    let role: String // "user" | "assistant"
    let content: String
    let reasoningContent: String?
    let hasImage: Bool
    let imageDataList: [Data]?
    let imageData: Data?
    let timestamp: String

    init(message: ChatMessage) {
        self.type = "message"
        self.messageId = message.id.uuidString
        self.role = message.role.rawValue
        self.content = message.content
        self.reasoningContent = message.reasoningContent.isEmpty ? nil : message.reasoningContent
        self.hasImage = !message.imageDataList.isEmpty
        self.imageDataList = message.imageDataList.isEmpty ? nil : message.imageDataList
        // Legacy single-image field kept for backward compatibility.
        self.imageData = message.imageDataList.first
        self.timestamp = ISO8601DateFormatter().string(from: Date())
    }
}

// MARK: - Session Store

/// Reads and writes chat sessions as JSONL files under ~/.agents/sessions/
actor SessionStore {
    private let sessionsDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDirectory = home
            .appendingPathComponent(".agents", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - Public API

    /// Load all persisted sessions from disk.
    func loadSessions(availableModels: [ModelOption]) -> [ChatSession] {
        ensureDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        let jsonlFiles = files
            .filter { $0.pathExtension == "jsonl" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 > d1 // newest first
            }

        return jsonlFiles.compactMap { url in
            parseSession(from: url, availableModels: availableModels)
        }
    }

    /// Persist an entire session (rewrite its file).
    func saveSession(_ session: ChatSession) {
        ensureDirectory()
        let fileURL = fileURL(for: session.id)

        var header = SessionHeaderRecord(session: session)
        header.updatedAt = ISO8601DateFormatter().string(from: Date())

        var lines: [Data] = []
        if let headerData = try? encoder.encode(header) {
            lines.append(headerData)
        }
        for message in session.messages {
            // Skip empty assistant placeholders from cancelled/error streams
            if message.role == .assistant &&
                message.content.isEmpty &&
                message.reasoningContent.isEmpty &&
                !message.isStreaming {
                continue
            }
            let record = MessageRecord(message: message)
            if let data = try? encoder.encode(record) {
                lines.append(data)
            }
        }

        let content = lines.map { String(data: $0, encoding: .utf8) ?? "" }.joined(separator: "\n") + "\n"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Append a single message record to an existing session file.
    func appendMessage(_ message: ChatMessage, sessionId: UUID) {
        ensureDirectory()
        let fileURL = fileURL(for: sessionId)
        let record = MessageRecord(message: message)
        guard let data = try? encoder.encode(record),
              let line = String(data: data, encoding: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                handle.closeFile()
            }
        }
    }

    /// Update the header line of a session (e.g. title change).
    func updateHeader(_ session: ChatSession) {
        // Full rewrite is simplest for header changes
        saveSession(session)
    }

    /// Delete a session's file from disk.
    func deleteSession(id: UUID) {
        let fileURL = fileURL(for: id)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Private

    private func fileURL(for sessionId: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(sessionId.uuidString).jsonl")
    }

    private func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sessionsDirectory.path) {
            try? fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        }
    }

    private func parseSession(from url: URL, availableModels: [ModelOption]) -> ChatSession? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        // First line must be the session header
        guard let headerData = lines[0].data(using: .utf8),
              let header = try? decoder.decode(SessionHeaderRecord.self, from: headerData),
              header.type == "session_header",
              let sessionUUID = UUID(uuidString: header.sessionId) else {
            return nil
        }

        let model = availableModels.first { $0.modelId == header.modelId }
        let reasoningEffort = Client.ReasoningEffort(rawValue: header.reasoningEffortRawValue ?? 0) ?? .default

        var messages: [ChatMessage] = []
        for line in lines.dropFirst() {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(MessageRecord.self, from: data),
                  record.type == "message" else {
                continue
            }
            let role: MessageRole = record.role == "assistant" ? .assistant : .user
            let imageDataList: [Data]
            if let list = record.imageDataList, !list.isEmpty {
                imageDataList = list
            } else if let single = record.imageData {
                imageDataList = [single]
            } else {
                imageDataList = []
            }
            let msg = ChatMessage(
                id: UUID(uuidString: record.messageId) ?? UUID(),
                role: role,
                content: record.content,
                reasoningContent: record.reasoningContent ?? "",
                imageDataList: imageDataList
            )
            messages.append(msg)
        }

        return ChatSession(
            id: sessionUUID,
            title: header.title,
            isTitleLocked: header.isTitleLocked ?? false,
            messages: messages,
            selectedModel: model,
            selectedReasoningEffort: reasoningEffort
        )
    }
}
