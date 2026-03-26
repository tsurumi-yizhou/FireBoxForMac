import Foundation
import CoreFoundation
import Security
import Shared
import SwiftAISDK
import OpenAIProvider
import AnthropicProvider
import GoogleProvider

private struct CallerCodeIdentity {
    var signingIdentifier: String?
    var teamIdentifier: String?
    var uniqueHash: String?
    var executablePath: String?
}

private func makeXPCCaller(from connection: NSXPCConnection) -> XPCCaller {
    let pid = Int32(connection.processIdentifier)
    let codeIdentity = resolveCallerCodeIdentity(pid: pid)
    return XPCCaller(
        pid: pid,
        euid: connection.effectiveUserIdentifier,
        egid: connection.effectiveGroupIdentifier,
        auditSession: Int32(connection.auditSessionIdentifier),
        codeSigningIdentifier: codeIdentity.signingIdentifier,
        codeSigningTeamIdentifier: codeIdentity.teamIdentifier,
        codeSigningUnique: codeIdentity.uniqueHash,
        executablePath: codeIdentity.executablePath
    )
}

private func resolveCallerCodeIdentity(pid: Int32) -> CallerCodeIdentity {
    let attributes: [CFString: Any] = [
        kSecGuestAttributePid: NSNumber(value: pid),
    ]

    var code: SecCode?
    let codeStatus = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &code)
    guard codeStatus == errSecSuccess, let code else {
        return CallerCodeIdentity()
    }

    var staticCode: SecStaticCode?
    let staticStatus = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
    guard staticStatus == errSecSuccess, let staticCode else {
        return CallerCodeIdentity()
    }

    var executablePath: String?
    var pathRef: CFURL?
    if SecCodeCopyPath(staticCode, SecCSFlags(), &pathRef) == errSecSuccess, let pathRef {
        executablePath = (pathRef as URL).path
    }

    var signingIdentifier: String?
    var teamIdentifier: String?
    var uniqueHash: String?
    var informationRef: CFDictionary?
    let informationFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
    if SecCodeCopySigningInformation(staticCode, informationFlags, &informationRef) == errSecSuccess,
       let informationRef,
       let information = informationRef as? [String: Any]
    {
        signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String
        teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String

        if let uniqueData = information[kSecCodeInfoUnique as String] as? Data {
            uniqueHash = uniqueData.hexEncodedString()
        } else if let uniqueData = information[kSecCodeInfoUnique as String] as? NSData {
            uniqueHash = (uniqueData as Data).hexEncodedString()
        }

        if executablePath == nil, let mainExecutable = information[kSecCodeInfoMainExecutable as String] as? URL {
            executablePath = mainExecutable.path
        }
    }

    return CallerCodeIdentity(
        signingIdentifier: signingIdentifier,
        teamIdentifier: teamIdentifier,
        uniqueHash: uniqueHash,
        executablePath: executablePath
    )
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service: Service

    init(service: Service) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let caller = makeXPCCaller(from: newConnection)
        let connectionID = service.registerConnection(caller: caller)

        newConnection.exportedInterface = XPCInterfaceFactory.makeServiceInterface()
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [weak service] in
            service?.unregisterConnection(connectionID: connectionID)
        }
        newConnection.interruptionHandler = { [weak service] in
            service?.unregisterConnection(connectionID: connectionID)
        }
        newConnection.resume()
        return true
    }
}

final class Service: NSObject, ServiceProtocol {
    private let core: ServiceCore
    private let iso8601: ISO8601DateFormatter
    private let streamTaskQueue = DispatchQueue(label: "com.firebox.service.stream-tasks")
    private var streamTasks: [Int64: Task<Void, Never>] = [:]

    init(core: ServiceCore) {
        self.core = core
        self.iso8601 = ISO8601DateFormatter()
        self.iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        super.init()
    }

    // MARK: Connection runtime bridge

    func registerConnection(caller: XPCCaller) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var value: Int32 = 0
        Task {
            value = await core.registerConnection(caller: caller)
            semaphore.signal()
        }
        semaphore.wait()
        return value
    }

    func unregisterConnection(connectionID: Int32) {
        Task { await core.unregisterConnection(connectionID: connectionID) }
    }

    // MARK: Common

    func ping(_ message: String, withReply reply: @escaping (String) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(denial)
                return
            }
            reply("Pong: \(message)")
        }
    }

    // MARK: Capability

    func listModels(withReply reply: @escaping (NSDictionary) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(Self.errorEnvelope(denial))
                return
            }

            do {
                let models = try await core.listModelCapabilities()
                let payload: [NSDictionary] = models.map { info -> NSDictionary in
                    [
                        "modelId": info.modelId,
                        "capabilities": [
                            "reasoning": info.reasoning,
                            "toolCalling": info.toolCalling,
                            "inputFormats": info.inputFormats.map(\.rawValue),
                            "outputFormats": info.outputFormats.map(\.rawValue),
                        ] as NSDictionary,
                        "available": info.available,
                    ] as NSDictionary
                }
                reply(Self.responseEnvelope(["models": payload] as NSDictionary))
            } catch {
                reply(Self.errorEnvelope(error.localizedDescription))
            }
        }
    }

    func chatCompletion(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(Self.errorEnvelope(denial))
                return
            }

            do {
                let parsed = try Self.parseChatRequest(request)
                let candidates = try await core.resolveCandidates(for: parsed.modelId)
                guard let candidate = candidates.first else {
                    throw RPCValidationError.invalidArgument("No route candidate resolved for model \(parsed.modelId)")
                }

                let model = try makeLanguageModel(provider: candidate.provider, modelID: candidate.modelId)
                let providerOptions = try Self.providerOptions(
                    for: candidate.provider.providerType,
                    reasoningEffort: parsed.reasoningEffort
                )
                let result: DefaultGenerateTextResult<JSONValue> = try await generateText(
                    model: model,
                    messages: parsed.messages,
                    providerOptions: providerOptions,
                    settings: parsed.settings
                )

                let usage = try Self.usageDictionary(from: result.usage)
                try await core.recordMetric(
                    MetricEvent(
                        requestCount: 1,
                        promptTokens: try Self.requiredUsageToken(usage, key: "promptTokens"),
                        completionTokens: try Self.requiredUsageToken(usage, key: "completionTokens"),
                        totalTokens: try Self.requiredUsageToken(usage, key: "totalTokens"),
                        estimatedCostUsd: 0
                    )
                )

                var response: [String: Any] = [
                    "modelId": parsed.modelId,
                    "message": [
                        "role": "assistant",
                        "content": result.text,
                        "attachments": [],
                    ] as NSDictionary,
                    "usage": usage,
                    "finishReason": result.finishReason.rawValue,
                ]
                if let reasoning = result.reasoningText, !reasoning.isEmpty {
                    response["reasoningText"] = reasoning
                }

                reply(Self.responseEnvelope(response as NSDictionary))
            } catch {
                reply(Self.errorEnvelope(error.localizedDescription))
            }
        }
    }

    func startChatCompletionStream(
        _ request: NSDictionary,
        sink: ChatStreamSinkProtocol,
        withReply reply: @escaping (Int64) -> Void
    ) {
        let caller = Self.currentCaller()
        Task {
            let requestID = await core.allocateRequestID()
            reply(requestID)
            if let denial = await authorize(caller: caller) {
                sink.onError(["requestId": requestID, "error": denial] as NSDictionary)
                return
            }

            do {
                let parsed = try Self.parseChatRequest(request)
                let candidates = try await core.resolveCandidates(for: parsed.modelId)
                guard let candidate = candidates.first else {
                    throw RPCValidationError.invalidArgument("No route candidate resolved for model \(parsed.modelId)")
                }
                guard let caller else {
                    throw RPCValidationError.invalidArgument("Missing XPC caller context.")
                }
                await core.registerActiveStream(requestID: requestID, caller: caller)

                let task: Task<Void, Never> = Task { [weak self] in
                    guard let self else { return }
                    await self.runStream(
                        requestID: requestID,
                        parsed: parsed,
                        candidate: candidate,
                        sink: sink
                    )
                }
                setStreamTask(task, for: requestID)
            } catch {
                sink.onError(["requestId": requestID, "error": error.localizedDescription] as NSDictionary)
            }
        }
    }

    func cancelChatCompletion(_ requestId: Int64, withReply reply: @escaping () -> Void) {
        let caller = Self.currentCaller()
        Task {
            if await authorize(caller: caller) == nil {
                if let task = removeStreamTask(for: requestId) {
                    task.cancel()
                }
            }
            reply()
        }
    }

    func createEmbeddings(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(Self.errorEnvelope(denial))
                return
            }

            do {
                let parsed = try Self.parseEmbeddingRequest(request)
                let candidates = try await core.resolveCandidates(for: parsed.modelId)
                guard let candidate = candidates.first else {
                    throw RPCValidationError.invalidArgument("No route candidate resolved for model \(parsed.modelId)")
                }

                let model = try makeEmbeddingModel(provider: candidate.provider, modelID: candidate.modelId)
                let result = try await embedMany(model: model, values: parsed.input)

                let usage: NSDictionary = [
                    "promptTokens": Int64(result.usage.tokens),
                    "completionTokens": Int64(0),
                    "totalTokens": Int64(result.usage.tokens),
                ]

                let embeddings = result.embeddings.enumerated().map { index, vector -> NSDictionary in
                    [
                        "index": Int32(index),
                        "vector": vector.map { Float($0) },
                    ] as NSDictionary
                }

                try await core.recordMetric(
                    MetricEvent(
                        requestCount: 1,
                        promptTokens: result.usage.tokens,
                        completionTokens: 0,
                        totalTokens: result.usage.tokens,
                        estimatedCostUsd: 0
                    )
                )

                let response: NSDictionary = [
                    "modelId": parsed.modelId,
                    "embeddings": embeddings,
                    "usage": usage,
                ]
                reply(Self.responseEnvelope(response))
            } catch {
                reply(Self.errorEnvelope(error.localizedDescription))
            }
        }
    }

    func callFunction(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(Self.errorEnvelope(denial))
                return
            }

            do {
                let parsed = try Self.parseFunctionRequest(request)
                let candidates = try await core.resolveCandidates(for: parsed.modelId)
                guard let candidate = candidates.first else {
                    throw RPCValidationError.invalidArgument("No route candidate resolved for model \(parsed.modelId)")
                }

                let model = try makeLanguageModel(provider: candidate.provider, modelID: candidate.modelId)
                let prompt = """
                Function Name:
                \(parsed.functionName)

                Function Description:
                \(parsed.functionDescription)

                Input JSON:
                \(parsed.inputJSON)

                Input Schema JSON:
                \(parsed.inputSchemaJSON)

                Output Schema JSON:
                \(parsed.outputSchemaJSON)

                Return strictly valid JSON that matches Output Schema JSON.
                """

                let result = try await generateObjectNoSchema(
                    model: model,
                    prompt: prompt,
                    settings: parsed.settings
                )

                let outputData = try JSONEncoder().encode(result.object)
                let outputJSON = String(decoding: outputData, as: UTF8.self)
                let usage = try Self.usageDictionary(from: result.usage)

                try await core.recordMetric(
                    MetricEvent(
                        requestCount: 1,
                        promptTokens: try Self.requiredUsageToken(usage, key: "promptTokens"),
                        completionTokens: try Self.requiredUsageToken(usage, key: "completionTokens"),
                        totalTokens: try Self.requiredUsageToken(usage, key: "totalTokens"),
                        estimatedCostUsd: 0
                    )
                )

                let response: NSDictionary = [
                    "modelId": parsed.modelId,
                    "outputJson": outputJSON,
                    "usage": usage,
                    "finishReason": result.finishReason.rawValue,
                ]
                reply(Self.responseEnvelope(response))
            } catch {
                reply(Self.errorEnvelope(error.localizedDescription))
            }
        }
    }

    // MARK: Control

    func shutdown(withReply reply: @escaping (String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(denial)
                return
            }

            reply(nil)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
                exit(EXIT_SUCCESS)
            }
        }
    }

    func getVersionCode(withReply reply: @escaping (Int32, String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(0, denial)
                return
            }
            reply(1, nil)
        }
    }

    func getDailyStats(
        year: Int32,
        month: Int32,
        day: Int32,
        withReply reply: @escaping (NSDictionary, String?) -> Void
    ) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply([:] as NSDictionary, denial)
                return
            }

            do {
                let stats = try await core.getDailyStats(year: year, month: month, day: day)
                reply(Self.statsDictionary(stats), nil)
            } catch {
                reply([:] as NSDictionary, error.localizedDescription)
            }
        }
    }

    func getMonthlyStats(
        year: Int32,
        month: Int32,
        withReply reply: @escaping (NSDictionary, String?) -> Void
    ) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply([:] as NSDictionary, denial)
                return
            }

            do {
                let stats = try await core.getMonthlyStats(year: year, month: month)
                reply(Self.statsDictionary(stats), nil)
            } catch {
                reply([:] as NSDictionary, error.localizedDescription)
            }
        }
    }

    func listProviders(withReply reply: @escaping ([NSDictionary], String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply([], denial)
                return
            }

            do {
                let providers = try await core.listProviders()
                let payload = providers.map { provider -> NSDictionary in
                    [
                        "id": provider.id,
                        "providerType": provider.providerType.rawValue,
                        "name": provider.name,
                        "baseUrl": provider.baseURL,
                        "enabledModelIds": provider.enabledModelIds,
                        "createdAt": iso8601.string(from: provider.createdAt),
                        "updatedAt": iso8601.string(from: provider.updatedAt),
                    ] as NSDictionary
                }
                reply(payload, nil)
            } catch {
                reply([], error.localizedDescription)
            }
        }
    }

    func addProvider(_ request: NSDictionary, withReply reply: @escaping (Int32, String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(0, denial)
                return
            }

            do {
                let providerTypeRaw = try Self.requiredString(request, key: "providerType")
                guard let providerType = ProviderType.parse(providerTypeRaw) else {
                    throw RPCValidationError.invalidArgument("Invalid providerType: \(providerTypeRaw)")
                }

                let id = try await core.addProvider(
                    providerType: providerType,
                    name: try Self.requiredString(request, key: "name"),
                    baseURL: try Self.requiredString(request, key: "baseUrl"),
                    apiKey: try Self.requiredString(request, key: "apiKey")
                )
                reply(id, nil)
            } catch {
                reply(0, error.localizedDescription)
            }
        }
    }

    func updateProvider(_ request: NSDictionary, withReply reply: @escaping (String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(denial)
                return
            }

            do {
                let providerID = try Self.requiredInt32(request, key: "providerId")
                let name = try Self.requiredString(request, key: "name")
                let baseURL = try Self.requiredString(request, key: "baseUrl")
                let enabledModelIDs = try Self.requiredStringArray(request, key: "enabledModelIds")

                let apiKey: String?
                if request.allKeys.contains(where: { ($0 as? String) == "apiKey" }) {
                    let rawApiKey = request["apiKey"]
                    if rawApiKey is NSNull {
                        apiKey = nil
                    } else if let stringApiKey = rawApiKey as? String {
                        apiKey = stringApiKey
                    } else {
                        throw RPCValidationError.invalidArgument("apiKey must be a string, null, or omitted")
                    }
                } else {
                    apiKey = nil
                }

                try await core.updateProvider(
                    providerID: providerID,
                    name: name,
                    baseURL: baseURL,
                    enabledModelIds: enabledModelIDs,
                    apiKey: apiKey
                )
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func deleteProvider(providerId: Int32, withReply reply: @escaping (String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(denial)
                return
            }

            do {
                try await core.deleteProvider(providerID: providerId)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func fetchProviderModels(providerId: Int32, withReply reply: @escaping ([String], String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply([], denial)
                return
            }

            do {
                let provider = try await core.providerByID(providerId)
                let modelIDs = try await fetchProviderModelIDs(provider: provider)
                reply(modelIDs, nil)
            } catch {
                reply([], error.localizedDescription)
            }
        }
    }

    func listRoutes(withReply reply: @escaping ([NSDictionary], String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply([], denial)
                return
            }

            do {
                let routes = try await core.listRoutes()
                let payload = routes.map { route -> NSDictionary in
                    [
                        "id": route.id,
                        "routeId": route.routeId,
                        "strategy": route.strategy.rawValue,
                        "candidates": route.candidates.map {
                            [
                                "providerId": $0.providerId,
                                "modelId": $0.modelId,
                            ] as NSDictionary
                        },
                        "reasoning": route.reasoning,
                        "toolCalling": route.toolCalling,
                        "inputFormatsMask": route.inputFormatsMask,
                        "outputFormatsMask": route.outputFormatsMask,
                        "createdAt": iso8601.string(from: route.createdAt),
                        "updatedAt": iso8601.string(from: route.updatedAt),
                    ] as NSDictionary
                }
                reply(payload, nil)
            } catch {
                reply([], error.localizedDescription)
            }
        }
    }

    func addRoute(_ request: NSDictionary, withReply reply: @escaping (Int32, String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(0, denial)
                return
            }

            do {
                let strategyRaw = try Self.requiredString(request, key: "strategy")
                guard let strategy = RouteStrategy.parse(strategyRaw) else {
                    throw RPCValidationError.invalidArgument("Invalid strategy: \(strategyRaw)")
                }

                let candidates = try Self.parseRouteCandidates(request["candidates"])
                let id = try await core.addRoute(
                    routeId: try Self.requiredString(request, key: "routeId"),
                    strategy: strategy,
                    candidates: candidates,
                    reasoning: try Self.requiredBool(request, key: "reasoning"),
                    toolCalling: try Self.requiredBool(request, key: "toolCalling"),
                    inputFormatsMask: try Self.requiredInt32(request, key: "inputFormatsMask"),
                    outputFormatsMask: try Self.requiredInt32(request, key: "outputFormatsMask")
                )
                reply(id, nil)
            } catch {
                reply(0, error.localizedDescription)
            }
        }
    }

    func updateRoute(_ request: NSDictionary, withReply reply: @escaping (String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(denial)
                return
            }

            do {
                let strategyRaw = try Self.requiredString(request, key: "strategy")
                guard let strategy = RouteStrategy.parse(strategyRaw) else {
                    throw RPCValidationError.invalidArgument("Invalid strategy: \(strategyRaw)")
                }

                try await core.updateRoute(
                    id: try Self.requiredInt32(request, key: "id"),
                    routeId: try Self.requiredString(request, key: "routeId"),
                    strategy: strategy,
                    candidates: try Self.parseRouteCandidates(request["candidates"]),
                    reasoning: try Self.requiredBool(request, key: "reasoning"),
                    toolCalling: try Self.requiredBool(request, key: "toolCalling"),
                    inputFormatsMask: try Self.requiredInt32(request, key: "inputFormatsMask"),
                    outputFormatsMask: try Self.requiredInt32(request, key: "outputFormatsMask")
                )
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func deleteRoute(id: Int32, withReply reply: @escaping (String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(denial)
                return
            }

            do {
                try await core.deleteRoute(id: id)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    func listConnections(withReply reply: @escaping ([NSDictionary], String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply([], denial)
                return
            }

            let payload = await core.listConnections().map { info -> NSDictionary in
                [
                    "connectionId": info.connectionId,
                    "xpcCaller": info.caller.dictionary,
                    "connectedAt": iso8601.string(from: info.connectedAt),
                    "requestCount": info.requestCount,
                    "hasActiveStream": info.hasActiveStream,
                ] as NSDictionary
            }
            reply(payload, nil)
        }
    }

    func listClientAccess(withReply reply: @escaping ([NSDictionary], String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply([], denial)
                return
            }

            do {
                let payload = try await core.listClientAccess().map { record -> NSDictionary in
                    var dictionary: [String: Any] = [
                        "id": record.id,
                        "xpcCaller": record.caller.dictionary,
                        "requestCount": record.requestCount,
                        "firstSeenAt": iso8601.string(from: record.firstSeenAt),
                        "lastSeenAt": iso8601.string(from: record.lastSeenAt),
                        "isAllowed": record.isAllowed,
                    ]
                    if let deniedUntil = record.deniedUntilUtc {
                        dictionary["deniedUntilUtc"] = iso8601.string(from: deniedUntil)
                    }
                    return dictionary as NSDictionary
                }
                reply(payload, nil)
            } catch {
                reply([], error.localizedDescription)
            }
        }
    }

    func updateClientAccessAllowed(accessId: Int32, isAllowed: Bool, withReply reply: @escaping (String?) -> Void) {
        let caller = Self.currentCaller()
        Task {
            if let denial = await authorize(caller: caller) {
                reply(denial)
                return
            }

            do {
                try await core.updateClientAccessAllowed(accessID: accessId, isAllowed: isAllowed)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // MARK: Private - Stream

    private func runStream(
        requestID: Int64,
        parsed: ChatRequest,
        candidate: ResolvedCandidate,
        sink: ChatStreamSinkProtocol
    ) async {
        defer {
            _ = removeStreamTask(for: requestID)
            Task { await core.finishActiveStream(requestID: requestID) }
        }

        do {
            let model = try makeLanguageModel(provider: candidate.provider, modelID: candidate.modelId)
            let providerOptions = try Self.providerOptions(
                for: candidate.provider.providerType,
                reasoningEffort: parsed.reasoningEffort
            )
            let result = try streamText(
                model: model,
                messages: parsed.messages,
                providerOptions: providerOptions,
                settings: parsed.settings
            )

            var assembledText = ""
            var assembledReasoning = ""
            var didEmitStarted = false

            func emitStartedIfNeeded() {
                guard !didEmitStarted else { return }
                sink.onStarted(["requestId": requestID] as NSDictionary)
                didEmitStarted = true
            }

            func emitReasoningDelta(_ text: String) {
                assembledReasoning += text
                sink.onReasoningDelta([
                    "requestId": requestID,
                    "reasoningText": text,
                ] as NSDictionary)
            }

            for try await part in result.fullStream {
                if Task.isCancelled {
                    throw CancellationError()
                }

                switch part {
                case .start:
                    emitStartedIfNeeded()
                case .startStep:
                    emitStartedIfNeeded()
                case .finishStep(_, let usage, _, _, _):
                    emitStartedIfNeeded()
                    let usageDict = try Self.usageDictionary(from: usage)
                    let totalTokens = try Self.requiredUsageInt64(usageDict, key: "totalTokens")
                    if totalTokens > 0 {
                        sink.onUsage([
                            "requestId": requestID,
                            "usage": usageDict,
                        ] as NSDictionary)
                    }
                case .textStart:
                    emitStartedIfNeeded()
                case .textEnd:
                    emitStartedIfNeeded()
                case .textDelta(_, let delta, _):
                    emitStartedIfNeeded()
                    assembledText += delta
                    sink.onDelta([
                        "requestId": requestID,
                        "deltaText": delta,
                    ] as NSDictionary)
                case .reasoningStart:
                    emitStartedIfNeeded()
                case .reasoningEnd:
                    emitStartedIfNeeded()
                case .reasoningDelta(_, let delta, _):
                    emitStartedIfNeeded()
                    emitReasoningDelta(delta)
                case .toolInputStart(_, let toolName, _, _, _, let title):
                    emitStartedIfNeeded()
                    let header = title.map { "[\($0)] " } ?? ""
                    emitReasoningDelta("\(header)tool input start: \(toolName)\n")
                case .toolInputDelta(_, let delta, _):
                    emitStartedIfNeeded()
                    emitReasoningDelta(delta)
                case .toolInputEnd:
                    emitStartedIfNeeded()
                    emitReasoningDelta("\n")
                case .source(let source):
                    emitStartedIfNeeded()
                    emitReasoningDelta("[source] \(String(describing: source))\n")
                case .file(let file):
                    emitStartedIfNeeded()
                    emitReasoningDelta("[file] \(String(describing: file))\n")
                case .toolCall(let toolCall):
                    emitStartedIfNeeded()
                    emitReasoningDelta("[tool-call] \(String(describing: toolCall))\n")
                case .toolResult(let toolResult):
                    emitStartedIfNeeded()
                    emitReasoningDelta("[tool-result] \(String(describing: toolResult))\n")
                case .toolError(let toolError):
                    emitStartedIfNeeded()
                    emitReasoningDelta("[tool-error] \(String(describing: toolError))\n")
                case .toolOutputDenied(let denied):
                    emitStartedIfNeeded()
                    emitReasoningDelta("[tool-output-denied] \(String(describing: denied))\n")
                case .toolApprovalRequest(let approval):
                    emitStartedIfNeeded()
                    emitReasoningDelta("[tool-approval-request] \(String(describing: approval))\n")
                case .raw(let rawValue):
                    emitStartedIfNeeded()
                    emitReasoningDelta("[raw] \(String(describing: rawValue))\n")
                case .finish(let finishReason, let rawFinishReason, let totalUsage):
                    emitStartedIfNeeded()
                    let usage = try Self.usageDictionary(from: totalUsage)
                    _ = try Self.requiredUsageInt64(usage, key: "totalTokens")
                    sink.onUsage([
                        "requestId": requestID,
                        "usage": usage,
                    ] as NSDictionary)

                    var completed: [String: Any] = [
                        "requestId": requestID,
                        "modelId": parsed.modelId,
                        "message": [
                            "role": "assistant",
                            "content": assembledText,
                            "attachments": [],
                        ] as NSDictionary,
                        "finishReason": rawFinishReason ?? finishReason.rawValue,
                        "usage": usage,
                    ]
                    if !assembledReasoning.isEmpty {
                        completed["reasoningText"] = assembledReasoning
                    }
                    sink.onCompleted(completed as NSDictionary)

                    try await core.recordMetric(
                        MetricEvent(
                            requestCount: 1,
                            promptTokens: try Self.requiredUsageToken(usage, key: "promptTokens"),
                            completionTokens: try Self.requiredUsageToken(usage, key: "completionTokens"),
                            totalTokens: try Self.requiredUsageToken(usage, key: "totalTokens"),
                            estimatedCostUsd: 0
                        )
                    )
                    return
                case .error(let error):
                    throw error
                case .abort(let reason):
                    throw RPCValidationError.invalidArgument("Stream aborted: \(reason ?? "unknown reason")")
                }
            }

            throw RPCValidationError.invalidArgument("Streaming terminated unexpectedly.")
        } catch is CancellationError {
            sink.onCancelled(["requestId": requestID] as NSDictionary)
            return
        } catch {
            sink.onError([
                "requestId": requestID,
                "error": error.localizedDescription,
            ] as NSDictionary)
        }
    }

    // MARK: Private - Auth

    private func authorize(caller: XPCCaller?) async -> String? {
        guard let caller else {
            return "Missing XPC caller context."
        }
        await core.recordRequest(caller: caller)

        do {
            switch try await core.evaluateAccess(caller: caller) {
            case .allow:
                return nil
            case .denyCooldown(let until):
                return "Access denied until \(iso8601.string(from: until))"
            case .prompt:
                let allowed = promptForAccess(caller: caller)
                try await core.applyAccessPromptDecision(caller: caller, isAllowed: allowed)
                return allowed ? nil : "Access denied by user."
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func promptForAccess(caller: XPCCaller) -> Bool {
        let title = "FireBox Authorization Request" as CFString
        let identity = caller.codeSigningIdentifier ?? caller.executablePath ?? "uid:\(caller.euid)"
        let message = "Allow XPC caller \(identity) pid:\(caller.pid) uid:\(caller.euid) to use FireBox?" as CFString
        var responseFlags: CFOptionFlags = 0
        let status = CFUserNotificationDisplayAlert(
            0,
            CFOptionFlags(kCFUserNotificationNoteAlertLevel),
            nil,
            nil,
            nil,
            title,
            message,
            "Allow" as CFString,
            "Deny" as CFString,
            nil,
            &responseFlags
        )
        if status != 0 {
            return false
        }
        return responseFlags == CFOptionFlags(kCFUserNotificationDefaultResponse)
    }

    // MARK: Private - Providers

    private func makeLanguageModel(provider: ProviderConfiguration, modelID: String) throws -> any LanguageModelV3 {
        switch provider.providerType {
        case .openAI:
            let openAI = createOpenAIProvider(
                settings: OpenAIProviderSettings(baseURL: provider.baseURL, apiKey: provider.apiKey)
            )
            return try openAI.languageModel(modelId: modelID)
        case .anthropic:
            let anthropic = createAnthropicProvider(
                settings: AnthropicProviderSettings(baseURL: provider.baseURL, apiKey: provider.apiKey)
            )
            return try anthropic.languageModel(modelId: modelID)
        case .gemini:
            let google = createGoogleGenerativeAI(
                settings: GoogleProviderSettings(baseURL: provider.baseURL, apiKey: provider.apiKey)
            )
            return try google.languageModel(modelId: modelID)
        }
    }

    private func makeEmbeddingModel(provider: ProviderConfiguration, modelID: String) throws -> any EmbeddingModelV3<String> {
        switch provider.providerType {
        case .openAI:
            let openAI = createOpenAIProvider(
                settings: OpenAIProviderSettings(baseURL: provider.baseURL, apiKey: provider.apiKey)
            )
            return try openAI.textEmbeddingModel(modelId: modelID)
        case .anthropic:
            let anthropic = createAnthropicProvider(
                settings: AnthropicProviderSettings(baseURL: provider.baseURL, apiKey: provider.apiKey)
            )
            return try anthropic.textEmbeddingModel(modelId: modelID)
        case .gemini:
            let google = createGoogleGenerativeAI(
                settings: GoogleProviderSettings(baseURL: provider.baseURL, apiKey: provider.apiKey)
            )
            return try google.textEmbeddingModel(modelId: modelID)
        }
    }

    private func fetchProviderModelIDs(provider: ProviderConfiguration) async throws -> [String] {
        let response = try await fetchModelsJSON(provider: provider)
        let modelIDs: [String]

        switch provider.providerType {
        case .openAI:
            modelIDs = try parseOpenAIModelIDs(from: response)
        case .anthropic:
            modelIDs = try parseAnthropicModelIDs(from: response)
        case .gemini:
            modelIDs = try parseGeminiModelIDs(from: response)
        }

        let unique = Array(Set(modelIDs))
        if unique.isEmpty {
            throw RPCValidationError.invalidArgument("No model IDs returned by \(provider.providerType.rawValue) /models endpoint.")
        }
        return unique.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func parseOpenAIModelIDs(from json: [String: Any]) throws -> [String] {
        guard let data = json["data"] as? [Any] else {
            throw RPCValidationError.invalidArgument("OpenAI /models response missing data array.")
        }
        return try data.enumerated().map { index, item in
            guard let dict = item as? [String: Any] else {
                throw RPCValidationError.invalidArgument("OpenAI /models data[\(index)] is not an object.")
            }
            guard let id = dict["id"] as? String else {
                throw RPCValidationError.invalidArgument("OpenAI /models data[\(index)] missing id.")
            }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw RPCValidationError.invalidArgument("OpenAI /models data[\(index)] has empty id.")
            }
            return trimmed
        }
    }

    private func parseAnthropicModelIDs(from json: [String: Any]) throws -> [String] {
        guard let data = json["data"] as? [Any] else {
            throw RPCValidationError.invalidArgument("Anthropic /models response missing data array.")
        }
        return try data.enumerated().map { index, item in
            guard let dict = item as? [String: Any] else {
                throw RPCValidationError.invalidArgument("Anthropic /models data[\(index)] is not an object.")
            }
            guard let id = dict["id"] as? String else {
                throw RPCValidationError.invalidArgument("Anthropic /models data[\(index)] missing id.")
            }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw RPCValidationError.invalidArgument("Anthropic /models data[\(index)] has empty id.")
            }
            return trimmed
        }
    }

    private func parseGeminiModelIDs(from json: [String: Any]) throws -> [String] {
        guard let data = json["models"] as? [Any] else {
            throw RPCValidationError.invalidArgument("Gemini /models response missing models array.")
        }
        return try data.enumerated().map { index, item in
            guard let dict = item as? [String: Any] else {
                throw RPCValidationError.invalidArgument("Gemini /models models[\(index)] is not an object.")
            }
            guard let name = dict["name"] as? String else {
                throw RPCValidationError.invalidArgument("Gemini /models models[\(index)] missing name.")
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw RPCValidationError.invalidArgument("Gemini /models models[\(index)] has empty name.")
            }
            return trimmed.hasPrefix("models/") ? String(trimmed.dropFirst("models/".count)) : trimmed
        }
    }

    private func fetchModelsJSON(provider: ProviderConfiguration) async throws -> [String: Any] {
        let base = provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/models") else {
            throw RPCValidationError.invalidArgument("Invalid provider base URL: \(provider.baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        switch provider.providerType {
        case .openAI:
            request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(provider.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(provider.apiKey, forHTTPHeaderField: "x-goog-api-key")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RPCValidationError.invalidArgument("Invalid upstream response.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let text = String(decoding: data, as: UTF8.self)
            throw RPCValidationError.invalidArgument(text.isEmpty ? "Upstream request failed with status \(http.statusCode)." : text)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCValidationError.invalidArgument("Invalid JSON from provider models endpoint.")
        }
        return json
    }

    // MARK: Private - Stream task registry

    private func setStreamTask(_ task: Task<Void, Never>, for requestID: Int64) {
        streamTaskQueue.sync {
            streamTasks[requestID] = task
        }
    }

    private func removeStreamTask(for requestID: Int64) -> Task<Void, Never>? {
        streamTaskQueue.sync {
            let task = streamTasks[requestID]
            streamTasks[requestID] = nil
            return task
        }
    }

    // MARK: Private - Parsing helpers

    private struct ChatRequest {
        let modelId: String
        let messages: [ModelMessage]
        let settings: CallSettings
        let reasoningEffort: ReasoningEffort?
    }

    private struct EmbeddingRequest {
        let modelId: String
        let input: [String]
    }

    private struct FunctionRequest {
        let modelId: String
        let functionName: String
        let functionDescription: String
        let inputJSON: String
        let inputSchemaJSON: String
        let outputSchemaJSON: String
        let settings: CallSettings
    }

    private static func parseChatRequest(_ request: NSDictionary) throws -> ChatRequest {
        let modelID = try requiredString(request, key: "modelId")
        guard let messageObjects = request["messages"] as? [Any], !messageObjects.isEmpty else {
            throw RPCValidationError.invalidArgument("messages must be non-empty")
        }

        var modelMessages: [ModelMessage] = []
        for item in messageObjects {
            guard let message = item as? NSDictionary else {
                throw RPCValidationError.invalidArgument("messages contains invalid item")
            }
            let role = try requiredString(message, key: "role")
            let content = try requiredStringAllowEmpty(message, key: "content")
            let attachments = try parseAttachments(message["attachments"])

            switch role {
            case "system":
                modelMessages.append(.system(SystemModelMessage(content: content)))
            case "assistant":
                modelMessages.append(.assistant(AssistantModelMessage(content: .text(content))))
            case "user":
                if attachments.isEmpty {
                    modelMessages.append(.user(UserModelMessage(content: .text(content))))
                } else {
                    var parts: [UserContentPart] = []
                    if !content.isEmpty {
                        parts.append(.text(TextPart(text: content)))
                    }
                    for attachment in attachments {
                        switch attachment.mediaFormat {
                        case .image:
                            parts.append(
                                .image(
                                    ImagePart(
                                        image: .data(attachment.data),
                                        mediaType: attachment.mimeType
                                    )
                                )
                            )
                        case .video, .audio:
                            parts.append(
                                .file(
                                    FilePart(
                                        data: .data(attachment.data),
                                        mediaType: attachment.mimeType,
                                        filename: attachment.fileName
                                    )
                                )
                            )
                        }
                    }
                    modelMessages.append(.user(UserModelMessage(content: .parts(parts))))
                }
            default:
                throw RPCValidationError.invalidArgument("message.role must be one of system/user/assistant")
            }
        }

        var settings = CallSettings()
        if let temperature = try optionalDouble(request, key: "temperature") {
            if temperature < 0 {
                throw RPCValidationError.invalidArgument("temperature must be >= 0")
            }
            settings.temperature = temperature
        }
        if let maxOutput = try optionalInt(request, key: "maxOutputTokens") {
            if maxOutput < 0 {
                throw RPCValidationError.invalidArgument("maxOutputTokens must be >= 0")
            }
            settings.maxOutputTokens = maxOutput
        }

        return ChatRequest(
            modelId: modelID,
            messages: modelMessages,
            settings: settings,
            reasoningEffort: try optionalReasoningEffort(request, key: "reasoningEffort")
        )
    }

    private static func parseEmbeddingRequest(_ request: NSDictionary) throws -> EmbeddingRequest {
        let modelID = try requiredString(request, key: "modelId")
        guard let rawInputs = request["input"] as? [Any], !rawInputs.isEmpty else {
            throw RPCValidationError.invalidArgument("input must be non-empty")
        }

        let inputs = rawInputs.compactMap { $0 as? String }
        guard inputs.count == rawInputs.count else {
            throw RPCValidationError.invalidArgument("input contains non-string item")
        }

        let totalCharacters = inputs.reduce(0) { $0 + $1.count }
        if totalCharacters > 200_000 {
            throw RPCValidationError.invalidArgument("Total input character count exceeds 200000")
        }

        return EmbeddingRequest(modelId: modelID, input: inputs)
    }

    private static func parseFunctionRequest(_ request: NSDictionary) throws -> FunctionRequest {
        let modelID = try requiredString(request, key: "modelId")
        let functionName = try requiredString(request, key: "functionName")
        let functionDescription = try requiredString(request, key: "functionDescription")
        let inputJSON = try requiredString(request, key: "inputJson")
        let inputSchema = try requiredString(request, key: "inputSchemaJson")
        let outputSchema = try requiredString(request, key: "outputSchemaJson")

        var settings = CallSettings()
        if let temperature = try optionalDouble(request, key: "temperature") {
            if temperature < 0 {
                throw RPCValidationError.invalidArgument("temperature must be >= 0")
            }
            settings.temperature = temperature
        }
        if let maxOutput = try optionalInt(request, key: "maxOutputTokens") {
            if maxOutput < 0 {
                throw RPCValidationError.invalidArgument("maxOutputTokens must be >= 0")
            }
            settings.maxOutputTokens = maxOutput
        }

        return FunctionRequest(
            modelId: modelID,
            functionName: functionName,
            functionDescription: functionDescription,
            inputJSON: inputJSON,
            inputSchemaJSON: inputSchema,
            outputSchemaJSON: outputSchema,
            settings: settings
        )
    }

    private struct ParsedAttachment {
        let mediaFormat: MediaFormat
        let mimeType: String
        let fileName: String?
        let data: Data
    }

    private static func parseAttachments(_ raw: Any?) throws -> [ParsedAttachment] {
        guard let raw else { throw RPCValidationError.invalidArgument("attachments must be an array") }
        guard let array = raw as? [Any] else {
            throw RPCValidationError.invalidArgument("attachments must be an array")
        }

        return try array.map { item in
            guard let dict = item as? NSDictionary else {
                throw RPCValidationError.invalidArgument("attachment is not an object")
            }
            let mediaRaw = try requiredInt32(dict, key: "mediaFormat")
            guard let media = MediaFormat(rawValue: mediaRaw) else {
                throw RPCValidationError.invalidArgument("attachment.mediaFormat is invalid")
            }

            let mimeType = try requiredString(dict, key: "mimeType")
            let fileName = dict["fileName"] as? String
            let data = try dataValue(dict["data"], key: "data")

            let sizeBytes: Int64
            if let explicit = dict["sizeBytes"] as? Int64 {
                sizeBytes = explicit
            } else if let explicit32 = dict["sizeBytes"] as? Int32 {
                sizeBytes = Int64(explicit32)
            } else {
                throw RPCValidationError.invalidArgument("attachment.sizeBytes must be provided")
            }

            if sizeBytes < 0 {
                throw RPCValidationError.invalidArgument("attachment.sizeBytes must be >= 0")
            }
            if sizeBytes > 8 * 1024 * 1024 {
                throw RPCValidationError.invalidArgument("attachment exceeds 8 MiB")
            }
            if data.count > 8 * 1024 * 1024 {
                throw RPCValidationError.invalidArgument("attachment data exceeds 8 MiB")
            }

            return ParsedAttachment(
                mediaFormat: media,
                mimeType: mimeType,
                fileName: fileName,
                data: data
            )
        }
    }

    private static func parseRouteCandidates(_ raw: Any?) throws -> [RouteCandidate] {
        guard let array = raw as? [Any] else {
            throw RPCValidationError.invalidArgument("candidates must be an array")
        }
        return try array.map { item in
            guard let dict = item as? NSDictionary else {
                throw RPCValidationError.invalidArgument("candidate is not an object")
            }
            return RouteCandidate(
                providerId: try requiredInt32(dict, key: "providerId"),
                modelId: try requiredString(dict, key: "modelId")
            )
        }
    }

    private static func requiredString(_ dictionary: NSDictionary, key: String) throws -> String {
        guard let value = dictionary[key] as? String else {
            throw RPCValidationError.invalidArgument("\(key) must be a string")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RPCValidationError.invalidArgument("\(key) must be non-empty")
        }
        return trimmed
    }

    private static func requiredStringAllowEmpty(_ dictionary: NSDictionary, key: String) throws -> String {
        guard let value = dictionary[key] as? String else {
            throw RPCValidationError.invalidArgument("\(key) must be a string")
        }
        return value
    }

    private static func requiredStringArray(_ dictionary: NSDictionary, key: String) throws -> [String] {
        guard let values = dictionary[key] as? [Any] else {
            throw RPCValidationError.invalidArgument("\(key) must be an array")
        }
        let strings = values.compactMap { $0 as? String }
        if strings.count != values.count {
            throw RPCValidationError.invalidArgument("\(key) contains non-string value")
        }
        return strings
    }

    private static func optionalDouble(_ dictionary: NSDictionary, key: String) throws -> Double? {
        let value = dictionary[key]
        if value == nil || value is NSNull {
            return nil
        }
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let floatValue = value as? Float {
            return Double(floatValue)
        }
        if let intValue = value as? Int {
            return Double(intValue)
        }
        if let int32Value = value as? Int32 {
            return Double(int32Value)
        }
        if let number = value as? NSNumber {
            if isNSNumberBoolean(number) {
                throw RPCValidationError.invalidArgument("\(key) must be a number")
            }
            return number.doubleValue
        }
        throw RPCValidationError.invalidArgument("\(key) must be a number")
    }

    private static func optionalInt(_ dictionary: NSDictionary, key: String) throws -> Int? {
        let value = dictionary[key]
        if value == nil || value is NSNull {
            return nil
        }
        if let intValue = value as? Int {
            return intValue
        }
        if let int32Value = value as? Int32 {
            return Int(int32Value)
        }
        if let number = value as? NSNumber {
            if isNSNumberBoolean(number) {
                throw RPCValidationError.invalidArgument("\(key) must be an int")
            }
            let doubleValue = number.doubleValue
            if doubleValue.rounded(.towardZero) != doubleValue {
                throw RPCValidationError.invalidArgument("\(key) must be an int")
            }
            let int64Value = number.int64Value
            if int64Value < Int64(Int.min) || int64Value > Int64(Int.max) {
                throw RPCValidationError.invalidArgument("\(key) is out of range")
            }
            return Int(int64Value)
        }
        throw RPCValidationError.invalidArgument("\(key) must be an int")
    }

    private static func optionalReasoningEffort(_ dictionary: NSDictionary, key: String) throws -> ReasoningEffort? {
        let value = dictionary[key]
        if value == nil || value is NSNull {
            return nil
        }
        let raw: Int
        if let intValue = value as? Int {
            raw = intValue
        } else if let int32Value = value as? Int32 {
            raw = Int(int32Value)
        } else if let number = value as? NSNumber {
            raw = number.intValue
        } else {
            throw RPCValidationError.invalidArgument("\(key) must be an int32")
        }
        guard let effort = ReasoningEffort(rawValue: raw) else {
            throw RPCValidationError.invalidArgument("\(key) must be one of 0,1,2,3,4")
        }
        return effort
    }

    private static func requiredInt32(_ dictionary: NSDictionary, key: String) throws -> Int32 {
        if let value = dictionary[key] as? Int32 { return value }
        if let value = dictionary[key] as? Int {
            if value < Int(Int32.min) || value > Int(Int32.max) {
                throw RPCValidationError.invalidArgument("\(key) is out of int32 range")
            }
            return Int32(value)
        }
        if let value = dictionary[key] as? NSNumber {
            if isNSNumberBoolean(value) {
                throw RPCValidationError.invalidArgument("\(key) must be an int32")
            }
            let doubleValue = value.doubleValue
            if doubleValue.rounded(.towardZero) != doubleValue {
                throw RPCValidationError.invalidArgument("\(key) must be an int32")
            }
            if doubleValue < Double(Int32.min) || doubleValue > Double(Int32.max) {
                throw RPCValidationError.invalidArgument("\(key) is out of int32 range")
            }
            return Int32(doubleValue)
        }
        throw RPCValidationError.invalidArgument("\(key) must be an int32")
    }

    private static func requiredBool(_ dictionary: NSDictionary, key: String) throws -> Bool {
        if let value = dictionary[key] as? Bool { return value }
        if let value = dictionary[key] as? NSNumber, isNSNumberBoolean(value) { return value.boolValue }
        throw RPCValidationError.invalidArgument("\(key) must be a bool")
    }

    private static func isNSNumberBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func dataValue(_ value: Any?, key: String) throws -> Data {
        if let data = value as? Data {
            return data
        }
        if let nsData = value as? NSData {
            return nsData as Data
        }
        throw RPCValidationError.invalidArgument("\(key) must be binary data")
    }

    private static func providerOptions(
        for providerType: ProviderType,
        reasoningEffort: ReasoningEffort?
    ) throws -> ProviderOptions? {
        guard let reasoningEffort else {
            return nil
        }
        guard reasoningEffort != .default else {
            return nil
        }

        switch providerType {
        case .openAI:
            let effortValue: String
            switch reasoningEffort {
            case .low:
                effortValue = "low"
            case .medium:
                effortValue = "medium"
            case .high:
                effortValue = "high"
            case .max:
                throw RPCValidationError.invalidArgument("reasoningEffort=4 is not supported by OpenAI provider mapping")
            case .default:
                return nil
            }
            return ["openai": ["reasoningEffort": .string(effortValue)]]
        case .anthropic, .gemini:
            throw RPCValidationError.invalidArgument(
                "reasoningEffort is not supported for provider \(providerType.rawValue) in this protocol implementation"
            )
        }
    }

    private static func currentCaller() -> XPCCaller? {
        guard let connection = NSXPCConnection.current() else {
            return nil
        }
        return makeXPCCaller(from: connection)
    }

    private static func responseEnvelope(_ response: NSDictionary) -> NSDictionary {
        ["response": response] as NSDictionary
    }

    private static func errorEnvelope(_ message: String) -> NSDictionary {
        ["error": message] as NSDictionary
    }

    private static func usageDictionary(from usage: LanguageModelUsage) throws -> NSDictionary {
        guard let inputTokens = usage.inputTokens else {
            throw RPCValidationError.invalidArgument("Upstream usage is missing inputTokens")
        }
        guard let outputTokens = usage.outputTokens else {
            throw RPCValidationError.invalidArgument("Upstream usage is missing outputTokens")
        }
        guard let totalTokens = usage.totalTokens else {
            throw RPCValidationError.invalidArgument("Upstream usage is missing totalTokens")
        }
        let input = Int64(inputTokens)
        let output = Int64(outputTokens)
        let total = Int64(totalTokens)

        return [
            "promptTokens": input,
            "completionTokens": output,
            "totalTokens": total,
        ] as NSDictionary
    }

    private static func requiredUsageInt64(_ dictionary: NSDictionary, key: String) throws -> Int64 {
        if let value = dictionary[key] as? Int64 {
            return value
        }
        if let value = dictionary[key] as? Int {
            return Int64(value)
        }
        if let value = dictionary[key] as? NSNumber {
            if isNSNumberBoolean(value) {
                throw RPCValidationError.invalidArgument("usage.\(key) must be an int64")
            }
            let doubleValue = value.doubleValue
            if doubleValue.rounded(.towardZero) != doubleValue {
                throw RPCValidationError.invalidArgument("usage.\(key) must be an int64")
            }
            return value.int64Value
        }
        throw RPCValidationError.invalidArgument("usage.\(key) must be an int64")
    }

    private static func requiredUsageToken(_ dictionary: NSDictionary, key: String) throws -> Int {
        let value = try requiredUsageInt64(dictionary, key: key)
        if value < Int64(Int.min) || value > Int64(Int.max) {
            throw RPCValidationError.invalidArgument("usage.\(key) is out of range")
        }
        return Int(value)
    }

    private static func statsDictionary(_ stats: StatsSnapshot) -> NSDictionary {
        [
            "requestCount": stats.requestCount,
            "promptTokens": stats.promptTokens,
            "completionTokens": stats.completionTokens,
            "totalTokens": stats.totalTokens,
            "estimatedCostUsd": stats.estimatedCostUsd,
        ] as NSDictionary
    }
}

private enum RPCValidationError: Error, LocalizedError {
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message):
            return message
        }
    }
}
