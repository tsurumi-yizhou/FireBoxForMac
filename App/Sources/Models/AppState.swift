import Foundation
import SwiftUI
import Client

@MainActor
@Observable
final class AppState {
    var providers: [Provider] = []
    var routeRules: [RouteRule] = []
    var allowlist: [AllowlistEntry] = []
    var connections: [ConnectionEntry] = []
    var stats = DashboardStats()

    var quickToolProviderID: Int32?
    var quickToolModel: String = ""

    var isBootstrapping = false
    var isRefreshing = false
    var isServiceConnected = false
    var lastErrorMessage: String?

    private let client = Client()
    private var hasBootstrapped = false
    private var autoRefreshTask: Task<Void, Never>?
    private let autoRefreshInterval: Duration = .seconds(15)
    private var providerModelFetchInFlight: Set<Int32> = []

    var activeConnections: Int {
        connections.count
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        guard !isBootstrapping else { return }

        isBootstrapping = true
        defer {
            isBootstrapping = false
            hasBootstrapped = true
        }

        await refreshAll()
        startAutoRefresh()
    }

    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: autoRefreshInterval)
                if Task.isCancelled { break }
                await refreshAll()
            }
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await client.connect()
            async let providersTask: Void = refreshProviders()
            async let routesTask: Void = refreshRoutes()
            async let connectionsTask: Void = refreshConnections()
            async let allowlistTask: Void = refreshAllowlist()
            async let statsTask: Void = refreshStats()
            _ = try await (providersTask, routesTask, connectionsTask, allowlistTask, statsTask)
            isServiceConnected = true
        } catch {
            isServiceConnected = await client.isConnected
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshStatsOnly() async {
        do {
            try await refreshStats()
            isServiceConnected = true
        } catch {
            isServiceConnected = await client.isConnected
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshConnectionsOnly() async {
        do {
            try await refreshConnections()
            isServiceConnected = true
        } catch {
            isServiceConnected = await client.isConnected
            lastErrorMessage = error.localizedDescription
        }
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func addProvider(name: String, type: ProviderType, baseURL: String, apiKey: String) async {
        do {
            _ = try await client.addProvider(
                providerType: type.clientValue,
                name: name,
                baseUrl: baseURL,
                apiKey: apiKey
            )
            try await refreshProviders()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateProvider(_ provider: Provider, includeApiKey: Bool) async {
        do {
            try await client.updateProvider(
                providerId: provider.serviceID,
                name: provider.name,
                baseUrl: provider.baseURL,
                enabledModelIds: provider.models.filter(\.enabled).map(\.name),
                apiKey: includeApiKey ? provider.apiKey : nil
            )
            try await refreshProviders()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func deleteProvider(_ provider: Provider) async {
        do {
            try await client.deleteProvider(providerId: provider.serviceID)
            try await refreshProviders()
            try await refreshRoutes()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func fetchProviderModels(_ provider: Provider) async {
        await fetchProviderModels(providerServiceID: provider.serviceID)
    }

    func ensureProviderModelsLoaded(providerServiceID: Int32?) async {
        guard let providerServiceID else { return }
        guard let provider = providers.first(where: { $0.serviceID == providerServiceID }) else { return }
        if provider.models.isEmpty {
            await fetchProviderModels(providerServiceID: providerServiceID)
        }
    }

    func addProviderModelManually(providerServiceID: Int32, modelName: String) {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let providerIndex = providers.firstIndex(where: { $0.serviceID == providerServiceID }) else { return }
        if providers[providerIndex].models.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return
        }
        providers[providerIndex].models.append(ModelInfo(name: trimmed, enabled: true))
        providers[providerIndex].models.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func saveProviderModelSelection(_ provider: Provider) async {
        await updateProvider(provider, includeApiKey: false)
    }

    func addRoute(_ rule: RouteRule) async {
        do {
            _ = try await client.addRoute(
                routeId: rule.routeId,
                strategy: rule.strategy.clientValue,
                candidates: try encodeCandidates(rule.candidates),
                reasoning: rule.capabilityReasoning,
                toolCalling: rule.capabilityToolCalling,
                inputFormatsMask: inputMask(for: rule),
                outputFormatsMask: outputMask(for: rule)
            )
            try await refreshRoutes()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateRoute(_ rule: RouteRule) async {
        do {
            try await client.updateRoute(
                id: rule.serviceID,
                routeId: rule.routeId,
                strategy: rule.strategy.clientValue,
                candidates: try encodeCandidates(rule.candidates),
                reasoning: rule.capabilityReasoning,
                toolCalling: rule.capabilityToolCalling,
                inputFormatsMask: inputMask(for: rule),
                outputFormatsMask: outputMask(for: rule)
            )
            try await refreshRoutes()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func deleteRoute(_ rule: RouteRule) async {
        do {
            try await client.deleteRoute(id: rule.serviceID)
            try await refreshRoutes()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func updateClientAccess(_ entry: AllowlistEntry, allowed: Bool) async {
        do {
            try await client.updateClientAccessAllowed(accessId: entry.serviceID, isAllowed: allowed)
            try await refreshAllowlist()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func refreshProviders() async throws {
        let providerInfos = try await client.listProviders()
        let existingByServiceID = Dictionary(uniqueKeysWithValues: providers.map { ($0.serviceID, $0) })

        providers = providerInfos.map { info in
            let existing = existingByServiceID[info.id]
            let existingModelStates = Dictionary(uniqueKeysWithValues: (existing?.models ?? []).map { ($0.name, $0.enabled) })
            let mergedModels = Set(existingModelStates.keys).union(info.enabledModelIds)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { name in
                    let enabled = info.enabledModelIds.contains(name) || (existingModelStates[name] ?? false)
                    return ModelInfo(name: name, enabled: enabled)
                }

            return Provider(
                id: existing?.id ?? UUID(),
                serviceID: info.id,
                name: info.name,
                type: ProviderType(clientValue: info.providerType),
                baseURL: info.baseUrl,
                apiKey: existing?.apiKey ?? "",
                models: mergedModels,
                createdAt: info.createdAt,
                updatedAt: info.updatedAt
            )
        }
    }

    private func fetchProviderModels(providerServiceID: Int32) async {
        if providerModelFetchInFlight.contains(providerServiceID) {
            return
        }
        providerModelFetchInFlight.insert(providerServiceID)
        defer { providerModelFetchInFlight.remove(providerServiceID) }

        do {
            let fetchedModels = try await client.fetchProviderModels(providerId: providerServiceID)
            guard let providerIndex = providers.firstIndex(where: { $0.serviceID == providerServiceID }) else { return }
            let enabled = Set(providers[providerIndex].models.filter(\.enabled).map(\.name))
            providers[providerIndex].models = fetchedModels.map { model in
                ModelInfo(name: model, enabled: enabled.contains(model))
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func refreshRoutes() async throws {
        let routeInfos = try await client.listRoutes()
        let existingByServiceID = Dictionary(uniqueKeysWithValues: routeRules.map { ($0.serviceID, $0.id) })

        routeRules = routeInfos.map { info in
            let inputMask = info.inputFormatsMask
            let outputMask = info.outputFormatsMask
            let candidates = info.candidates.map { candidate in
                CandidateTarget(providerServiceID: candidate.providerId, modelName: candidate.modelId)
            }
            return RouteRule(
                id: existingByServiceID[info.id] ?? UUID(),
                serviceID: info.id,
                routeId: info.routeId,
                strategy: RouteStrategy(clientValue: info.strategy),
                capabilityReasoning: info.reasoning,
                capabilityToolCalling: info.toolCalling,
                inputImage: inputMask & 1 != 0,
                inputVideo: inputMask & 2 != 0,
                inputAudio: inputMask & 4 != 0,
                outputImage: outputMask & 1 != 0,
                outputVideo: outputMask & 2 != 0,
                outputAudio: outputMask & 4 != 0,
                candidates: candidates,
                createdAt: info.createdAt,
                updatedAt: info.updatedAt
            )
        }
    }

    private func refreshConnections() async throws {
        let connectionInfos = try await client.listConnections()
        connections = connectionInfos.map { info in
            ConnectionEntry(
                connectionId: info.connectionId,
                caller: XPCCallerSnapshot(
                    pid: info.xpcCaller.pid,
                    euid: info.xpcCaller.euid,
                    egid: info.xpcCaller.egid,
                    auditSession: info.xpcCaller.auditSession
                ),
                connectedAt: info.connectedAt,
                requestCount: info.requestCount,
                hasActiveStream: info.hasActiveStream
            )
        }
    }

    private func refreshAllowlist() async throws {
        let accessRecords = try await client.listClientAccess()
        allowlist = accessRecords.map { record in
            AllowlistEntry(
                serviceID: record.id,
                caller: XPCCallerSnapshot(
                    pid: record.xpcCaller.pid,
                    euid: record.xpcCaller.euid,
                    egid: record.xpcCaller.egid,
                    auditSession: record.xpcCaller.auditSession
                ),
                requestCount: record.requestCount,
                firstSeenAt: record.firstSeenAt,
                lastSeenAt: record.lastSeenAt,
                allowed: record.isAllowed,
                deniedUntilUtc: record.deniedUntilUtc
            )
        }
    }

    private func refreshStats() async throws {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw ClientError.decoding(String(localized: "app.error.calendarComponents"))
        }

        let daily = try await client.getDailyStats(year: Int32(year), month: Int32(month), day: Int32(day))
        let monthly = try await client.getMonthlyStats(year: Int32(year), month: Int32(month))
        stats = DashboardStats(
            todayRequests: daily.requestCount,
            todayTokens: daily.totalTokens,
            todayCost: daily.estimatedCostUsd,
            monthRequests: monthly.requestCount,
            monthTokens: monthly.totalTokens,
            monthCost: monthly.estimatedCostUsd
        )
    }

    private func encodeCandidates(_ candidates: [CandidateTarget]) throws -> [Client.RouteCandidateInfo] {
        if candidates.isEmpty {
            throw ClientError.decoding(String(localized: "app.error.routeNeedsCandidate"))
        }

        var result: [Client.RouteCandidateInfo] = []
        result.reserveCapacity(candidates.count)

        for (index, candidate) in candidates.enumerated() {
            guard let providerServiceID = candidate.providerServiceID else {
                throw ClientError.decoding(String(format: String(localized: "app.error.candidateMissingProvider"), locale: .current, index + 1))
            }
            let model = candidate.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                throw ClientError.decoding(String(format: String(localized: "app.error.candidateMissingModel"), locale: .current, index + 1))
            }
            result.append(Client.RouteCandidateInfo(providerId: providerServiceID, modelId: model))
        }

        return result
    }

    private func inputMask(for rule: RouteRule) -> Int32 {
        var value: Int32 = 0
        if rule.inputImage { value |= 1 }
        if rule.inputVideo { value |= 2 }
        if rule.inputAudio { value |= 4 }
        return value
    }

    private func outputMask(for rule: RouteRule) -> Int32 {
        var value: Int32 = 0
        if rule.outputImage { value |= 1 }
        if rule.outputVideo { value |= 2 }
        if rule.outputAudio { value |= 4 }
        return value
    }
}
