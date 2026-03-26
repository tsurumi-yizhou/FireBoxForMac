import Foundation
import Shared

public enum ClientError: Error, LocalizedError, Sendable {
    case notConnected
    case connectionFailed
    case serviceUnavailable
    case rpc(String)
    case timeout(seconds: TimeInterval)
    case invalidEnvelope(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Client is not connected to the service."
        case .connectionFailed:
            return "Failed to establish connection to the service."
        case .serviceUnavailable:
            return "XPC service is unavailable."
        case .rpc(let message):
            return message
        case .timeout(let seconds):
            return "RPC timed out after \(seconds) seconds."
        case .invalidEnvelope(let message):
            return "Invalid envelope: \(message)"
        case .decoding(let message):
            return "Decoding error: \(message)"
        }
    }
}

public actor Client {
    public enum ReasoningEffort: Int32, Sendable, CaseIterable {
        case `default` = 0
        case low = 1
        case medium = 2
        case high = 3
        case max = 4
    }

    public enum MediaFormat: Int32, Sendable, CaseIterable {
        case image = 0
        case video = 1
        case audio = 2
    }

    public struct Usage: Sendable, Equatable {
        public var promptTokens: Int64
        public var completionTokens: Int64
        public var totalTokens: Int64

        public init(promptTokens: Int64, completionTokens: Int64, totalTokens: Int64) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
        }
    }

    public struct ModelCapabilities: Sendable, Equatable {
        public var reasoning: Bool
        public var toolCalling: Bool
        public var inputFormats: [MediaFormat]
        public var outputFormats: [MediaFormat]

        public init(reasoning: Bool, toolCalling: Bool, inputFormats: [MediaFormat], outputFormats: [MediaFormat]) {
            self.reasoning = reasoning
            self.toolCalling = toolCalling
            self.inputFormats = inputFormats
            self.outputFormats = outputFormats
        }
    }

    public struct CapabilityModelInfo: Sendable, Equatable {
        public var modelId: String
        public var capabilities: ModelCapabilities
        public var available: Bool

        public init(modelId: String, capabilities: ModelCapabilities, available: Bool) {
            self.modelId = modelId
            self.capabilities = capabilities
            self.available = available
        }
    }

    public enum ChatRole: String, Sendable {
        case system
        case user
        case assistant
    }

    public struct ChatAttachment: Sendable, Equatable {
        public var mediaFormat: MediaFormat
        public var mimeType: String
        public var fileName: String?
        public var data: Data
        public var sizeBytes: Int64

        public init(
            mediaFormat: MediaFormat,
            mimeType: String,
            fileName: String? = nil,
            data: Data,
            sizeBytes: Int64
        ) {
            self.mediaFormat = mediaFormat
            self.mimeType = mimeType
            self.fileName = fileName
            self.data = data
            self.sizeBytes = sizeBytes
        }
    }

    public struct ChatMessage: Sendable, Equatable {
        public var role: ChatRole
        public var content: String
        public var attachments: [ChatAttachment]

        public init(role: ChatRole, content: String, attachments: [ChatAttachment]) {
            self.role = role
            self.content = content
            self.attachments = attachments
        }
    }

    public struct ChatCompletionRequest: Sendable, Equatable {
        public var modelId: String
        public var messages: [ChatMessage]
        public var temperature: Double?
        public var maxOutputTokens: Int32?
        public var reasoningEffort: ReasoningEffort?

        public init(
            modelId: String,
            messages: [ChatMessage],
            temperature: Double? = nil,
            maxOutputTokens: Int32? = nil,
            reasoningEffort: ReasoningEffort? = nil
        ) {
            self.modelId = modelId
            self.messages = messages
            self.temperature = temperature
            self.maxOutputTokens = maxOutputTokens
            self.reasoningEffort = reasoningEffort
        }
    }

    public struct ChatCompletionResponse: Sendable, Equatable {
        public var modelId: String
        public var message: ChatMessage
        public var reasoningText: String?
        public var usage: Usage
        public var finishReason: String

        public init(modelId: String, message: ChatMessage, reasoningText: String?, usage: Usage, finishReason: String) {
            self.modelId = modelId
            self.message = message
            self.reasoningText = reasoningText
            self.usage = usage
            self.finishReason = finishReason
        }
    }

    public struct EmbeddingRequest: Sendable, Equatable {
        public var modelId: String
        public var input: [String]

        public init(modelId: String, input: [String]) {
            self.modelId = modelId
            self.input = input
        }
    }

    public struct Embedding: Sendable, Equatable {
        public var index: Int32
        public var vector: [Float]

        public init(index: Int32, vector: [Float]) {
            self.index = index
            self.vector = vector
        }
    }

    public struct EmbeddingResponse: Sendable, Equatable {
        public var modelId: String
        public var embeddings: [Embedding]
        public var usage: Usage

        public init(modelId: String, embeddings: [Embedding], usage: Usage) {
            self.modelId = modelId
            self.embeddings = embeddings
            self.usage = usage
        }
    }

    public struct FunctionCallRequest: Sendable, Equatable {
        public var modelId: String
        public var functionName: String
        public var functionDescription: String
        public var inputJson: String
        public var inputSchemaJson: String
        public var outputSchemaJson: String
        public var temperature: Double?
        public var maxOutputTokens: Int32?

        public init(
            modelId: String,
            functionName: String,
            functionDescription: String,
            inputJson: String,
            inputSchemaJson: String,
            outputSchemaJson: String,
            temperature: Double? = nil,
            maxOutputTokens: Int32? = nil
        ) {
            self.modelId = modelId
            self.functionName = functionName
            self.functionDescription = functionDescription
            self.inputJson = inputJson
            self.inputSchemaJson = inputSchemaJson
            self.outputSchemaJson = outputSchemaJson
            self.temperature = temperature
            self.maxOutputTokens = maxOutputTokens
        }
    }

    public struct FunctionCallResponse: Sendable, Equatable {
        public var modelId: String
        public var outputJson: String
        public var usage: Usage
        public var finishReason: String

        public init(modelId: String, outputJson: String, usage: Usage, finishReason: String) {
            self.modelId = modelId
            self.outputJson = outputJson
            self.usage = usage
            self.finishReason = finishReason
        }
    }

    public enum ChatStreamEvent: Sendable, Equatable {
        case started(requestId: Int64)
        case delta(requestId: Int64, text: String)
        case reasoning(requestId: Int64, text: String)
        case usage(requestId: Int64, usage: Usage)
        case completed(requestId: Int64, response: ChatCompletionResponse)
        case error(requestId: Int64, message: String)
        case cancelled(requestId: Int64)

        public var requestId: Int64 {
            switch self {
            case .started(let requestId):
                return requestId
            case .delta(let requestId, _):
                return requestId
            case .reasoning(let requestId, _):
                return requestId
            case .usage(let requestId, _):
                return requestId
            case .completed(let requestId, _):
                return requestId
            case .error(let requestId, _):
                return requestId
            case .cancelled(let requestId):
                return requestId
            }
        }

        public var isTerminal: Bool {
            switch self {
            case .completed, .error, .cancelled:
                return true
            case .started, .delta, .reasoning, .usage:
                return false
            }
        }
    }

    public typealias StreamEventHandler = @Sendable (ChatStreamEvent) -> Void

    public enum ProviderType: String, Sendable, CaseIterable {
        case openAI = "OpenAI"
        case anthropic = "Anthropic"
        case gemini = "Gemini"
    }

    public enum RouteStrategy: String, Sendable, CaseIterable {
        case ordered = "Ordered"
        case random = "Random"
    }

    public struct ProviderInfo: Sendable, Equatable {
        public var id: Int32
        public var providerType: ProviderType
        public var name: String
        public var baseUrl: String
        public var enabledModelIds: [String]
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: Int32,
            providerType: ProviderType,
            name: String,
            baseUrl: String,
            enabledModelIds: [String],
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.providerType = providerType
            self.name = name
            self.baseUrl = baseUrl
            self.enabledModelIds = enabledModelIds
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public struct RouteCandidateInfo: Sendable, Equatable {
        public var providerId: Int32
        public var modelId: String

        public init(providerId: Int32, modelId: String) {
            self.providerId = providerId
            self.modelId = modelId
        }
    }

    public struct RouteInfo: Sendable, Equatable {
        public var id: Int32
        public var routeId: String
        public var strategy: RouteStrategy
        public var candidates: [RouteCandidateInfo]
        public var reasoning: Bool
        public var toolCalling: Bool
        public var inputFormatsMask: Int32
        public var outputFormatsMask: Int32
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: Int32,
            routeId: String,
            strategy: RouteStrategy,
            candidates: [RouteCandidateInfo],
            reasoning: Bool,
            toolCalling: Bool,
            inputFormatsMask: Int32,
            outputFormatsMask: Int32,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.routeId = routeId
            self.strategy = strategy
            self.candidates = candidates
            self.reasoning = reasoning
            self.toolCalling = toolCalling
            self.inputFormatsMask = inputFormatsMask
            self.outputFormatsMask = outputFormatsMask
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public struct XPCCaller: Sendable, Equatable {
        public var pid: Int32
        public var euid: UInt32
        public var egid: UInt32
        public var auditSession: Int32

        public init(pid: Int32, euid: UInt32, egid: UInt32, auditSession: Int32) {
            self.pid = pid
            self.euid = euid
            self.egid = egid
            self.auditSession = auditSession
        }
    }

    public struct ConnectionInfo: Sendable, Equatable {
        public var connectionId: Int32
        public var xpcCaller: XPCCaller
        public var connectedAt: Date
        public var requestCount: Int64
        public var hasActiveStream: Bool

        public init(connectionId: Int32, xpcCaller: XPCCaller, connectedAt: Date, requestCount: Int64, hasActiveStream: Bool) {
            self.connectionId = connectionId
            self.xpcCaller = xpcCaller
            self.connectedAt = connectedAt
            self.requestCount = requestCount
            self.hasActiveStream = hasActiveStream
        }
    }

    public struct ClientAccessRecord: Sendable, Equatable {
        public var id: Int32
        public var xpcCaller: XPCCaller
        public var requestCount: Int64
        public var firstSeenAt: Date
        public var lastSeenAt: Date
        public var isAllowed: Bool
        public var deniedUntilUtc: Date?

        public init(
            id: Int32,
            xpcCaller: XPCCaller,
            requestCount: Int64,
            firstSeenAt: Date,
            lastSeenAt: Date,
            isAllowed: Bool,
            deniedUntilUtc: Date?
        ) {
            self.id = id
            self.xpcCaller = xpcCaller
            self.requestCount = requestCount
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
            self.isAllowed = isAllowed
            self.deniedUntilUtc = deniedUntilUtc
        }
    }

    public struct StatsResponse: Sendable, Equatable {
        public var requestCount: Int64
        public var promptTokens: Int64
        public var completionTokens: Int64
        public var totalTokens: Int64
        public var estimatedCostUsd: Double

        public init(
            requestCount: Int64,
            promptTokens: Int64,
            completionTokens: Int64,
            totalTokens: Int64,
            estimatedCostUsd: Double
        ) {
            self.requestCount = requestCount
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
            self.estimatedCostUsd = estimatedCostUsd
        }
    }

    private let rpcTimeoutSeconds: TimeInterval
    private let iso8601WithFractional: ISO8601DateFormatter
    private let iso8601: ISO8601DateFormatter

    private var connection: NSXPCConnection?
    private var isConnecting = false
    private var streamBridges: [Int64: ClientStreamSinkBridge] = [:]

    public var isConnected: Bool {
        get { connection != nil }
    }

    public init(rpcTimeoutSeconds: TimeInterval = 30) {
        self.rpcTimeoutSeconds = rpcTimeoutSeconds

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601WithFractional = fractional

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        self.iso8601 = plain
    }

    public func connect() async throws {
        guard connection == nil else { return }
        guard !isConnecting else { return }

        isConnecting = true
        defer { isConnecting = false }

        guard let newConnection = XPCConnectionHelper.shared.createConnection() else {
            throw ClientError.connectionFailed
        }

        newConnection.invalidationHandler = { [weak self] in
            Task { [weak self] in
                await self?.handleDisconnection()
            }
        }
        newConnection.interruptionHandler = { [weak self] in
            Task { [weak self] in
                await self?.handleDisconnection()
            }
        }

        connection = newConnection
    }

    public func disconnect() {
        connection?.invalidate()
        connection = nil
        streamBridges.removeAll()
    }

    public func ping(message: String = "hello") async throws -> String {
        try await invoke { service, finish in
            service.ping(message) { response in
                finish(.success(response))
            }
        }
    }

    public func listModels() async throws -> [CapabilityModelInfo] {
        let response = try await invokeEnvelope { service, finish in
            service.listModels(withReply: finish)
        }

        let modelsRaw = try Self.requiredArray(response["models"], key: "models")
        return try modelsRaw.map { item in
            guard let dict = item as? NSDictionary else {
                throw ClientError.decoding("models item must be an object")
            }
            return try Self.decodeCapabilityModelInfo(dict)
        }
    }

    public func chatCompletion(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let response = try await invokeEnvelope { service, finish in
            service.chatCompletion(request.dictionary, withReply: finish)
        }
        return try Self.decodeChatCompletionResponse(response)
    }

    public func startChatCompletionStream(
        request: ChatCompletionRequest,
        onEvent: @escaping StreamEventHandler
    ) async throws -> Int64 {
        let bridge = ClientStreamSinkBridge { [weak self] kind, event in
            guard let self else { return }
            Task {
                await self.forwardStreamEvent(kind: kind, event: event, onEvent: onEvent)
            }
        }

        let requestId: Int64 = try await invoke { service, finish in
            service.startChatCompletionStream(request.dictionary, sink: bridge) { requestId in
                finish(.success(requestId))
            }
        }

        streamBridges[requestId] = bridge
        return requestId
    }

    public func cancelChatCompletion(requestId: Int64) async throws {
        try await invoke { service, finish in
            service.cancelChatCompletion(requestId) {
                finish(.success(()))
            }
        }
    }

    public func createEmbeddings(request: EmbeddingRequest) async throws -> EmbeddingResponse {
        let response = try await invokeEnvelope { service, finish in
            service.createEmbeddings(request.dictionary, withReply: finish)
        }
        return try Self.decodeEmbeddingResponse(response)
    }

    public func callFunction(request: FunctionCallRequest) async throws -> FunctionCallResponse {
        let response = try await invokeEnvelope { service, finish in
            service.callFunction(request.dictionary, withReply: finish)
        }
        return try Self.decodeFunctionCallResponse(response)
    }

    public func shutdown() async throws {
        try await invokeControlVoid { service, finish in
            service.shutdown(withReply: finish)
        }
    }

    public func getVersionCode() async throws -> Int32 {
        try await invokeControl { service, finish in
            service.getVersionCode(withReply: finish)
        }
    }

    public func getDailyStats(year: Int32, month: Int32, day: Int32) async throws -> StatsResponse {
        let raw: NSDictionary = try await invokeControl { service, finish in
            service.getDailyStats(year: year, month: month, day: day, withReply: finish)
        }
        return try Self.decodeStats(raw)
    }

    public func getMonthlyStats(year: Int32, month: Int32) async throws -> StatsResponse {
        let raw: NSDictionary = try await invokeControl { service, finish in
            service.getMonthlyStats(year: year, month: month, withReply: finish)
        }
        return try Self.decodeStats(raw)
    }

    public func listProviders() async throws -> [ProviderInfo] {
        let raw: [NSDictionary] = try await invokeControl { service, finish in
            service.listProviders(withReply: finish)
        }
        return try raw.map(Self.decodeProviderInfo(_:))
    }

    public func addProvider(
        providerType: ProviderType,
        name: String,
        baseUrl: String,
        apiKey: String
    ) async throws -> Int32 {
        let request: NSDictionary = [
            "providerType": providerType.rawValue,
            "name": name,
            "baseUrl": baseUrl,
            "apiKey": apiKey,
        ]
        return try await invokeControl { service, finish in
            service.addProvider(request, withReply: finish)
        }
    }

    public func updateProvider(
        providerId: Int32,
        name: String,
        baseUrl: String,
        enabledModelIds: [String],
        apiKey: String? = nil
    ) async throws {
        var request: [String: Any] = [
            "providerId": providerId,
            "name": name,
            "baseUrl": baseUrl,
            "enabledModelIds": enabledModelIds,
        ]
        if let apiKey {
            request["apiKey"] = apiKey
        }
        try await invokeControlVoid { service, finish in
            service.updateProvider(request as NSDictionary, withReply: finish)
        }
    }

    public func deleteProvider(providerId: Int32) async throws {
        try await invokeControlVoid { service, finish in
            service.deleteProvider(providerId: providerId, withReply: finish)
        }
    }

    public func fetchProviderModels(providerId: Int32) async throws -> [String] {
        try await invokeControl { service, finish in
            service.fetchProviderModels(providerId: providerId, withReply: finish)
        }
    }

    public func listRoutes() async throws -> [RouteInfo] {
        let raw: [NSDictionary] = try await invokeControl { service, finish in
            service.listRoutes(withReply: finish)
        }
        return try raw.map(Self.decodeRouteInfo(_:))
    }

    public func addRoute(
        routeId: String,
        strategy: RouteStrategy,
        candidates: [RouteCandidateInfo],
        reasoning: Bool,
        toolCalling: Bool,
        inputFormatsMask: Int32,
        outputFormatsMask: Int32
    ) async throws -> Int32 {
        let request: NSDictionary = [
            "routeId": routeId,
            "strategy": strategy.rawValue,
            "candidates": candidates.map(\.dictionary),
            "reasoning": reasoning,
            "toolCalling": toolCalling,
            "inputFormatsMask": inputFormatsMask,
            "outputFormatsMask": outputFormatsMask,
        ]
        return try await invokeControl { service, finish in
            service.addRoute(request, withReply: finish)
        }
    }

    public func updateRoute(
        id: Int32,
        routeId: String,
        strategy: RouteStrategy,
        candidates: [RouteCandidateInfo],
        reasoning: Bool,
        toolCalling: Bool,
        inputFormatsMask: Int32,
        outputFormatsMask: Int32
    ) async throws {
        let request: NSDictionary = [
            "id": id,
            "routeId": routeId,
            "strategy": strategy.rawValue,
            "candidates": candidates.map(\.dictionary),
            "reasoning": reasoning,
            "toolCalling": toolCalling,
            "inputFormatsMask": inputFormatsMask,
            "outputFormatsMask": outputFormatsMask,
        ]
        try await invokeControlVoid { service, finish in
            service.updateRoute(request, withReply: finish)
        }
    }

    public func deleteRoute(id: Int32) async throws {
        try await invokeControlVoid { service, finish in
            service.deleteRoute(id: id, withReply: finish)
        }
    }

    public func listConnections() async throws -> [ConnectionInfo] {
        let raw: [NSDictionary] = try await invokeControl { service, finish in
            service.listConnections(withReply: finish)
        }
        return try raw.map(Self.decodeConnectionInfo(_:))
    }

    public func listClientAccess() async throws -> [ClientAccessRecord] {
        let raw: [NSDictionary] = try await invokeControl { service, finish in
            service.listClientAccess(withReply: finish)
        }
        return try raw.map(Self.decodeClientAccessRecord(_:))
    }

    public func updateClientAccessAllowed(accessId: Int32, isAllowed: Bool) async throws {
        try await invokeControlVoid { service, finish in
            service.updateClientAccessAllowed(accessId: accessId, isAllowed: isAllowed, withReply: finish)
        }
    }

    private func invoke<T>(
        timeout: TimeInterval? = nil,
        _ body: (ServiceProtocol, @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let service = try await ensureService()
        let timeoutSeconds = timeout ?? rpcTimeoutSeconds

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()

            body(service) { result in
                gate.resumeOnce {
                    continuation.resume(with: result)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                gate.resumeOnce {
                    continuation.resume(throwing: ClientError.timeout(seconds: timeoutSeconds))
                }
            }
        }
    }

    private func invokeEnvelope(
        _ body: (ServiceProtocol, @escaping (NSDictionary) -> Void) -> Void
    ) async throws -> NSDictionary {
        let envelope: NSDictionary = try await invoke { service, finish in
            body(service) { envelope in
                finish(.success(envelope))
            }
        }
        return try Self.parseEnvelope(envelope)
    }

    private func invokeControlVoid(
        _ body: (ServiceProtocol, @escaping (String?) -> Void) -> Void
    ) async throws {
        let _: Void = try await invoke { service, finish in
            body(service) { error in
                if let error {
                    finish(.failure(ClientError.rpc(error)))
                } else {
                    finish(.success(()))
                }
            }
        }
    }

    private func invokeControl<T>(
        _ body: (ServiceProtocol, @escaping (T, String?) -> Void) -> Void
    ) async throws -> T {
        try await invoke { service, finish in
            body(service) { value, error in
                if let error {
                    finish(.failure(ClientError.rpc(error)))
                } else {
                    finish(.success(value))
                }
            }
        }
    }

    private func ensureService() async throws -> ServiceProtocol {
        if connection == nil {
            try await connect()
        }
        guard let connection else {
            throw ClientError.notConnected
        }
        guard let service = XPCConnectionHelper.shared.getRemoteObject(from: connection) else {
            throw ClientError.serviceUnavailable
        }
        return service
    }

    private func handleDisconnection() {
        connection = nil
        streamBridges.removeAll()
    }

    private func forwardStreamEvent(
        kind: ClientStreamSinkBridge.Kind,
        event: NSDictionary,
        onEvent: @escaping StreamEventHandler
    ) {
        let parsed: ChatStreamEvent
        do {
            parsed = try Self.decodeStreamEvent(kind: kind, event: event)
        } catch {
            let requestId: Int64
            do { requestId = try Self.requiredInt64(event["requestId"], key: "requestId") } catch { requestId = -1 }
            parsed = .error(requestId: requestId, message: "Invalid stream event payload: \(error.localizedDescription)")
        }

        onEvent(parsed)

        if parsed.isTerminal {
            streamBridges[parsed.requestId] = nil
        }
    }

    private func parseDate(_ raw: Any?, key: String) throws -> Date {
        let string = try Self.requiredString(raw, key: key)
        if let date = iso8601WithFractional.date(from: string) {
            return date
        }
        if let date = iso8601.date(from: string) {
            return date
        }
        throw ClientError.decoding("\(key) must be an ISO8601 date")
    }

    private static func parseEnvelope(_ envelope: NSDictionary) throws -> NSDictionary {
        let response = envelope["response"]
        let error = envelope["error"]

        let hasResponse = response != nil && !(response is NSNull)
        let hasError = error != nil && !(error is NSNull)

        guard hasResponse != hasError else {
            throw ClientError.invalidEnvelope("exactly one of response/error must be present")
        }

        if hasError {
            throw ClientError.rpc(try requiredString(error, key: "error"))
        }
        guard let responseDict = response as? NSDictionary else {
            throw ClientError.invalidEnvelope("response must be an object")
        }
        return responseDict
    }

    private static func decodeCapabilityModelInfo(_ dict: NSDictionary) throws -> CapabilityModelInfo {
        let modelId = try requiredString(dict["modelId"], key: "modelId")
        let capabilities = try requiredDictionary(dict["capabilities"], key: "capabilities")
        let reasoning = try requiredBool(capabilities["reasoning"], key: "capabilities.reasoning")
        let toolCalling = try requiredBool(capabilities["toolCalling"], key: "capabilities.toolCalling")
        let inputFormats = try requiredMediaFormats(capabilities["inputFormats"], key: "capabilities.inputFormats")
        let outputFormats = try requiredMediaFormats(capabilities["outputFormats"], key: "capabilities.outputFormats")
        let available = try requiredBool(dict["available"], key: "available")
        return CapabilityModelInfo(
            modelId: modelId,
            capabilities: ModelCapabilities(
                reasoning: reasoning,
                toolCalling: toolCalling,
                inputFormats: inputFormats,
                outputFormats: outputFormats
            ),
            available: available
        )
    }

    private static func decodeChatCompletionResponse(_ dict: NSDictionary) throws -> ChatCompletionResponse {
        let modelId = try requiredString(dict["modelId"], key: "modelId")
        let message = try decodeChatMessage(try requiredDictionary(dict["message"], key: "message"), keyPrefix: "message")
        let usage = try decodeUsage(try requiredDictionary(dict["usage"], key: "usage"))
        let finishReason = try requiredString(dict["finishReason"], key: "finishReason")
        let reasoningText = optionalString(dict["reasoningText"])
        return ChatCompletionResponse(
            modelId: modelId,
            message: message,
            reasoningText: reasoningText,
            usage: usage,
            finishReason: finishReason
        )
    }

    private static func decodeEmbeddingResponse(_ dict: NSDictionary) throws -> EmbeddingResponse {
        let modelId = try requiredString(dict["modelId"], key: "modelId")
        let usage = try decodeUsage(try requiredDictionary(dict["usage"], key: "usage"))
        let rawEmbeddings = try requiredArray(dict["embeddings"], key: "embeddings")
        let embeddings = try rawEmbeddings.map { item -> Embedding in
            guard let embeddingDict = item as? NSDictionary else {
                throw ClientError.decoding("embeddings item must be an object")
            }
            let index = try requiredInt32(embeddingDict["index"], key: "embeddings.index")
            let rawVector = try requiredArray(embeddingDict["vector"], key: "embeddings.vector")
            let vector = try rawVector.map { value -> Float in
                if let floatValue = value as? Float { return floatValue }
                if let doubleValue = value as? Double { return Float(doubleValue) }
                if let number = value as? NSNumber, !isNSNumberBoolean(number) {
                    return number.floatValue
                }
                throw ClientError.decoding("embeddings.vector item must be a float")
            }
            return Embedding(index: index, vector: vector)
        }
        return EmbeddingResponse(modelId: modelId, embeddings: embeddings, usage: usage)
    }

    private static func decodeFunctionCallResponse(_ dict: NSDictionary) throws -> FunctionCallResponse {
        let modelId = try requiredString(dict["modelId"], key: "modelId")
        let outputJson = try requiredString(dict["outputJson"], key: "outputJson")
        let usage = try decodeUsage(try requiredDictionary(dict["usage"], key: "usage"))
        let finishReason = try requiredString(dict["finishReason"], key: "finishReason")
        return FunctionCallResponse(modelId: modelId, outputJson: outputJson, usage: usage, finishReason: finishReason)
    }

    private static func decodeUsage(_ dict: NSDictionary) throws -> Usage {
        Usage(
            promptTokens: try requiredInt64(dict["promptTokens"], key: "promptTokens"),
            completionTokens: try requiredInt64(dict["completionTokens"], key: "completionTokens"),
            totalTokens: try requiredInt64(dict["totalTokens"], key: "totalTokens")
        )
    }

    private static func decodeProviderInfo(_ dict: NSDictionary) throws -> ProviderInfo {
        let rawType = try requiredString(dict["providerType"], key: "providerType")
        guard let providerType = ProviderType(rawValue: rawType) else {
            throw ClientError.decoding("Invalid providerType: \(rawType)")
        }
        let enabledModelIdsRaw = try requiredArray(dict["enabledModelIds"], key: "enabledModelIds")
        let enabledModelIds = try enabledModelIdsRaw.map { value -> String in
            try requiredString(value, key: "enabledModelIds item")
        }
        return ProviderInfo(
            id: try requiredInt32(dict["id"], key: "id"),
            providerType: providerType,
            name: try requiredString(dict["name"], key: "name"),
            baseUrl: try requiredString(dict["baseUrl"], key: "baseUrl"),
            enabledModelIds: enabledModelIds,
            createdAt: try decodeDate(dict["createdAt"], key: "createdAt"),
            updatedAt: try decodeDate(dict["updatedAt"], key: "updatedAt")
        )
    }

    private static func decodeRouteInfo(_ dict: NSDictionary) throws -> RouteInfo {
        let rawStrategy = try requiredString(dict["strategy"], key: "strategy")
        guard let strategy = RouteStrategy(rawValue: rawStrategy) else {
            throw ClientError.decoding("Invalid route strategy: \(rawStrategy)")
        }
        let candidatesRaw = try requiredArray(dict["candidates"], key: "candidates")
        let candidates = try candidatesRaw.map { item -> RouteCandidateInfo in
            guard let candidateDict = item as? NSDictionary else {
                throw ClientError.decoding("candidates item must be an object")
            }
            return RouteCandidateInfo(
                providerId: try requiredInt32(candidateDict["providerId"], key: "candidates.providerId"),
                modelId: try requiredString(candidateDict["modelId"], key: "candidates.modelId")
            )
        }
        return RouteInfo(
            id: try requiredInt32(dict["id"], key: "id"),
            routeId: try requiredString(dict["routeId"], key: "routeId"),
            strategy: strategy,
            candidates: candidates,
            reasoning: try requiredBool(dict["reasoning"], key: "reasoning"),
            toolCalling: try requiredBool(dict["toolCalling"], key: "toolCalling"),
            inputFormatsMask: try requiredInt32(dict["inputFormatsMask"], key: "inputFormatsMask"),
            outputFormatsMask: try requiredInt32(dict["outputFormatsMask"], key: "outputFormatsMask"),
            createdAt: try decodeDate(dict["createdAt"], key: "createdAt"),
            updatedAt: try decodeDate(dict["updatedAt"], key: "updatedAt")
        )
    }

    private static func decodeConnectionInfo(_ dict: NSDictionary) throws -> ConnectionInfo {
        ConnectionInfo(
            connectionId: try requiredInt32(dict["connectionId"], key: "connectionId"),
            xpcCaller: try decodeXPCCaller(try requiredDictionary(dict["xpcCaller"], key: "xpcCaller")),
            connectedAt: try decodeDate(dict["connectedAt"], key: "connectedAt"),
            requestCount: try requiredInt64(dict["requestCount"], key: "requestCount"),
            hasActiveStream: try requiredBool(dict["hasActiveStream"], key: "hasActiveStream")
        )
    }

    private static func decodeClientAccessRecord(_ dict: NSDictionary) throws -> ClientAccessRecord {
        ClientAccessRecord(
            id: try requiredInt32(dict["id"], key: "id"),
            xpcCaller: try decodeXPCCaller(try requiredDictionary(dict["xpcCaller"], key: "xpcCaller")),
            requestCount: try requiredInt64(dict["requestCount"], key: "requestCount"),
            firstSeenAt: try decodeDate(dict["firstSeenAt"], key: "firstSeenAt"),
            lastSeenAt: try decodeDate(dict["lastSeenAt"], key: "lastSeenAt"),
            isAllowed: try requiredBool(dict["isAllowed"], key: "isAllowed"),
            deniedUntilUtc: try decodeOptionalDate(dict["deniedUntilUtc"], key: "deniedUntilUtc")
        )
    }

    private static func decodeXPCCaller(_ dict: NSDictionary) throws -> XPCCaller {
        XPCCaller(
            pid: try requiredInt32(dict["pid"], key: "xpcCaller.pid"),
            euid: try requiredUInt32(dict["euid"], key: "xpcCaller.euid"),
            egid: try requiredUInt32(dict["egid"], key: "xpcCaller.egid"),
            auditSession: try requiredInt32(dict["auditSession"], key: "xpcCaller.auditSession")
        )
    }

    private static func decodeStats(_ dict: NSDictionary) throws -> StatsResponse {
        StatsResponse(
            requestCount: try requiredInt64(dict["requestCount"], key: "requestCount"),
            promptTokens: try requiredInt64(dict["promptTokens"], key: "promptTokens"),
            completionTokens: try requiredInt64(dict["completionTokens"], key: "completionTokens"),
            totalTokens: try requiredInt64(dict["totalTokens"], key: "totalTokens"),
            estimatedCostUsd: try requiredDouble(dict["estimatedCostUsd"], key: "estimatedCostUsd")
        )
    }

    private static func decodeStreamEvent(kind: ClientStreamSinkBridge.Kind, event: NSDictionary) throws -> ChatStreamEvent {
        let requestId = try requiredInt64(event["requestId"], key: "requestId")
        switch kind {
        case .started:
            return .started(requestId: requestId)
        case .delta:
            let text = try requiredString(event["deltaText"], key: "deltaText")
            return .delta(requestId: requestId, text: text)
        case .reasoning:
            let text = try requiredString(event["reasoningText"], key: "reasoningText")
            return .reasoning(requestId: requestId, text: text)
        case .usage:
            let usageDict = try requiredDictionary(event["usage"], key: "usage")
            let usage = try decodeUsage(usageDict)
            return .usage(requestId: requestId, usage: usage)
        case .completed:
            let response = try decodeChatCompletionResponse(event)
            return .completed(requestId: requestId, response: response)
        case .error:
            let message = try requiredString(event["error"], key: "error")
            return .error(requestId: requestId, message: message)
        case .cancelled:
            return .cancelled(requestId: requestId)
        }
    }

    private static func decodeChatMessage(_ dict: NSDictionary, keyPrefix: String) throws -> ChatMessage {
        let roleRaw = try requiredString(dict["role"], key: "\(keyPrefix).role")
        guard let role = ChatRole(rawValue: roleRaw) else {
            throw ClientError.decoding("\(keyPrefix).role must be system/user/assistant")
        }
        let content = try requiredString(dict["content"], key: "\(keyPrefix).content")
        let attachmentsRaw = try requiredArray(dict["attachments"], key: "\(keyPrefix).attachments")
        let attachments = try attachmentsRaw.map { item -> ChatAttachment in
            guard let attachmentDict = item as? NSDictionary else {
                throw ClientError.decoding("\(keyPrefix).attachments item must be an object")
            }
            let mediaRaw = try requiredInt32(attachmentDict["mediaFormat"], key: "attachments.mediaFormat")
            guard let media = MediaFormat(rawValue: mediaRaw) else {
                throw ClientError.decoding("attachments.mediaFormat is invalid")
            }
            let mimeType = try requiredString(attachmentDict["mimeType"], key: "attachments.mimeType")
            let fileName = optionalString(attachmentDict["fileName"])
            guard let data = attachmentDict["data"] as? Data ?? (attachmentDict["data"] as? NSData as Data?) else {
                throw ClientError.decoding("attachments.data must be binary data")
            }
            let sizeBytes = try requiredInt64(attachmentDict["sizeBytes"], key: "attachments.sizeBytes")
            return ChatAttachment(mediaFormat: media, mimeType: mimeType, fileName: fileName, data: data, sizeBytes: sizeBytes)
        }
        return ChatMessage(role: role, content: content, attachments: attachments)
    }

    private static func decodeDate(_ raw: Any?, key: String) throws -> Date {
        let withFractional = iso8601WithFractionalStatic
        let plain = iso8601Static
        let string = try requiredString(raw, key: key)
        if let date = withFractional.date(from: string) { return date }
        if let date = plain.date(from: string) { return date }
        throw ClientError.decoding("\(key) must be an ISO8601 date")
    }

    private static func decodeOptionalDate(_ raw: Any?, key: String) throws -> Date? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let string = raw as? String else { throw ClientError.decoding("\(key) must be an ISO8601 date string") }
        if let date = iso8601WithFractionalStatic.date(from: string) { return date }
        if let date = iso8601Static.date(from: string) { return date }
        throw ClientError.decoding("\(key) must be an ISO8601 date string")
    }

    private static let iso8601WithFractionalStatic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Static: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func optionalString(_ raw: Any?) -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        return raw as? String
    }

    private static func requiredDictionary(_ raw: Any?, key: String) throws -> NSDictionary {
        guard let dict = raw as? NSDictionary else {
            throw ClientError.decoding("\(key) must be an object")
        }
        return dict
    }

    private static func requiredArray(_ raw: Any?, key: String) throws -> [Any] {
        guard let values = raw as? [Any] else {
            throw ClientError.decoding("\(key) must be an array")
        }
        return values
    }

    private static func requiredString(_ raw: Any?, key: String) throws -> String {
        guard let value = raw as? String else {
            throw ClientError.decoding("\(key) must be a string")
        }
        return value
    }

    private static func requiredBool(_ raw: Any?, key: String) throws -> Bool {
        if let value = raw as? Bool {
            return value
        }
        if let number = raw as? NSNumber, isNSNumberBoolean(number) {
            return number.boolValue
        }
        throw ClientError.decoding("\(key) must be a bool")
    }

    private static func requiredInt32(_ raw: Any?, key: String) throws -> Int32 {
        if let value = raw as? Int32 {
            return value
        }
        if let value = raw as? Int {
            guard value >= Int(Int32.min), value <= Int(Int32.max) else {
                throw ClientError.decoding("\(key) out of int32 range")
            }
            return Int32(value)
        }
        if let number = raw as? NSNumber, !isNSNumberBoolean(number) {
            let doubleValue = number.doubleValue
            guard doubleValue.rounded(.towardZero) == doubleValue else {
                throw ClientError.decoding("\(key) must be an int32")
            }
            guard doubleValue >= Double(Int32.min), doubleValue <= Double(Int32.max) else {
                throw ClientError.decoding("\(key) out of int32 range")
            }
            return Int32(doubleValue)
        }
        throw ClientError.decoding("\(key) must be an int32")
    }

    private static func requiredUInt32(_ raw: Any?, key: String) throws -> UInt32 {
        if let value = raw as? UInt32 {
            return value
        }
        if let value = raw as? Int {
            guard value >= 0 else {
                throw ClientError.decoding("\(key) must be >= 0")
            }
            guard value <= Int(UInt32.max) else {
                throw ClientError.decoding("\(key) out of uint32 range")
            }
            return UInt32(value)
        }
        if let number = raw as? NSNumber, !isNSNumberBoolean(number) {
            let doubleValue = number.doubleValue
            guard doubleValue.rounded(.towardZero) == doubleValue else {
                throw ClientError.decoding("\(key) must be an uint32")
            }
            guard doubleValue >= 0, doubleValue <= Double(UInt32.max) else {
                throw ClientError.decoding("\(key) out of uint32 range")
            }
            return UInt32(doubleValue)
        }
        throw ClientError.decoding("\(key) must be an uint32")
    }

    private static func requiredInt64(_ raw: Any?, key: String) throws -> Int64 {
        if let value = raw as? Int64 {
            return value
        }
        if let value = raw as? Int {
            return Int64(value)
        }
        if let value = raw as? Int32 {
            return Int64(value)
        }
        if let number = raw as? NSNumber, !isNSNumberBoolean(number) {
            let doubleValue = number.doubleValue
            guard doubleValue.rounded(.towardZero) == doubleValue else {
                throw ClientError.decoding("\(key) must be an int64")
            }
            return number.int64Value
        }
        throw ClientError.decoding("\(key) must be an int64")
    }

    private static func requiredDouble(_ raw: Any?, key: String) throws -> Double {
        if let value = raw as? Double {
            return value
        }
        if let value = raw as? Float {
            return Double(value)
        }
        if let value = raw as? Int {
            return Double(value)
        }
        if let value = raw as? Int32 {
            return Double(value)
        }
        if let number = raw as? NSNumber, !isNSNumberBoolean(number) {
            return number.doubleValue
        }
        throw ClientError.decoding("\(key) must be a number")
    }

    private static func requiredMediaFormats(_ raw: Any?, key: String) throws -> [MediaFormat] {
        let values = try requiredArray(raw, key: key)
        return try values.map { rawValue in
            let intValue = try requiredInt32(rawValue, key: key)
            guard let format = MediaFormat(rawValue: intValue) else {
                throw ClientError.decoding("\(key) contains invalid MediaFormat")
            }
            return format
        }
    }

    private static func isNSNumberBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        block()
    }
}

private final class ClientStreamSinkBridge: NSObject, ChatStreamSinkProtocol {
    enum Kind {
        case started
        case delta
        case reasoning
        case usage
        case completed
        case error
        case cancelled
    }

    private let lock = NSLock()
    private var terminated = false
    private let forward: @Sendable (Kind, NSDictionary) -> Void

    init(forward: @escaping @Sendable (Kind, NSDictionary) -> Void) {
        self.forward = forward
    }

    func onStarted(_ event: NSDictionary) {
        emit(kind: .started, event: event, terminal: false)
    }

    func onDelta(_ event: NSDictionary) {
        emit(kind: .delta, event: event, terminal: false)
    }

    func onReasoningDelta(_ event: NSDictionary) {
        emit(kind: .reasoning, event: event, terminal: false)
    }

    func onUsage(_ event: NSDictionary) {
        emit(kind: .usage, event: event, terminal: false)
    }

    func onCompleted(_ event: NSDictionary) {
        emit(kind: .completed, event: event, terminal: true)
    }

    func onError(_ event: NSDictionary) {
        emit(kind: .error, event: event, terminal: true)
    }

    func onCancelled(_ event: NSDictionary) {
        emit(kind: .cancelled, event: event, terminal: true)
    }

    private func emit(kind: Kind, event: NSDictionary, terminal: Bool) {
        lock.lock()
        if terminated {
            lock.unlock()
            return
        }
        if terminal {
            terminated = true
        }
        lock.unlock()

        forward(kind, event)
    }
}

private extension Client.ChatAttachment {
    var dictionary: NSDictionary {
        var payload: [String: Any] = [
            "mediaFormat": mediaFormat.rawValue,
            "mimeType": mimeType,
            "data": data,
            "sizeBytes": sizeBytes,
        ]
        if let fileName {
            payload["fileName"] = fileName
        }
        return payload as NSDictionary
    }
}

private extension Client.ChatMessage {
    var dictionary: NSDictionary {
        [
            "role": role.rawValue,
            "content": content,
            "attachments": attachments.map(\.dictionary),
        ] as NSDictionary
    }
}

private extension Client.ChatCompletionRequest {
    var dictionary: NSDictionary {
        var payload: [String: Any] = [
            "modelId": modelId,
            "messages": messages.map(\.dictionary),
        ]
        if let temperature {
            payload["temperature"] = temperature
        }
        if let maxOutputTokens {
            payload["maxOutputTokens"] = maxOutputTokens
        }
        if let reasoningEffort {
            payload["reasoningEffort"] = reasoningEffort.rawValue
        }
        return payload as NSDictionary
    }
}

private extension Client.EmbeddingRequest {
    var dictionary: NSDictionary {
        [
            "modelId": modelId,
            "input": input,
        ] as NSDictionary
    }
}

private extension Client.FunctionCallRequest {
    var dictionary: NSDictionary {
        var payload: [String: Any] = [
            "modelId": modelId,
            "functionName": functionName,
            "functionDescription": functionDescription,
            "inputJson": inputJson,
            "inputSchemaJson": inputSchemaJson,
            "outputSchemaJson": outputSchemaJson,
        ]
        if let temperature {
            payload["temperature"] = temperature
        }
        if let maxOutputTokens {
            payload["maxOutputTokens"] = maxOutputTokens
        }
        return payload as NSDictionary
    }
}

private extension Client.RouteCandidateInfo {
    var dictionary: NSDictionary {
        [
            "providerId": providerId,
            "modelId": modelId,
        ] as NSDictionary
    }
}
