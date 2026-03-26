import Foundation
import SwiftData

enum ServiceCoreError: Error, LocalizedError {
    case invalidProviderType(String)
    case invalidRouteStrategy(String)
    case providerNotFound(Int32)
    case routeNotFound(Int32)
    case accessNotFound(Int32)
    case duplicateRouteID(String)
    case invalidDateComponents
    case noRouteCandidate(String)
    case routeCandidateProviderNotFound(routeID: String, providerID: Int32, modelID: String)
    case routeCandidateModelNotEnabled(routeID: String, providerID: Int32, modelID: String)

    var errorDescription: String? {
        switch self {
        case .invalidProviderType(let raw):
            return "Invalid provider type: \(raw)"
        case .invalidRouteStrategy(let raw):
            return "Invalid route strategy: \(raw)"
        case .providerNotFound(let id):
            return "Provider not found: \(id)"
        case .routeNotFound(let id):
            return "Route not found: \(id)"
        case .accessNotFound(let id):
            return "Client access record not found: \(id)"
        case .duplicateRouteID(let routeID):
            return "Route ID already exists: \(routeID)"
        case .invalidDateComponents:
            return "Invalid date components"
        case .noRouteCandidate(let model):
            return "No available provider candidate for model: \(model)"
        case .routeCandidateProviderNotFound(let routeID, let providerID, let modelID):
            return "Route \(routeID) references missing provider \(providerID) for model \(modelID)"
        case .routeCandidateModelNotEnabled(let routeID, let providerID, let modelID):
            return "Route \(routeID) candidate provider \(providerID) does not enable model \(modelID)"
        }
    }
}

private final class ProviderRouteStore {
    private let container: ModelContainer

    init() throws {
        let cloud = ModelConfiguration("ProviderRouteStore", cloudKitDatabase: .automatic)
        container = try ModelContainer(
            for: ProviderEntity.self,
            ProviderModelEntity.self,
            RouteEntity.self,
            RouteCandidateEntity.self,
            configurations: cloud
        )
    }

    func loadProviders() throws -> [ProviderConfiguration] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ProviderEntity>(
            sortBy: [SortDescriptor(\.id, order: .forward)]
        )
        return try context.fetch(descriptor).map { try $0.toDomain() }
    }

    func loadRoutes() throws -> [RouteConfiguration] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RouteEntity>(
            sortBy: [SortDescriptor(\.id, order: .forward)]
        )
        return try context.fetch(descriptor).map { try $0.toDomain() }
    }

    func upsertProvider(_ provider: ProviderConfiguration) throws {
        let context = ModelContext(container)
        let providerID = provider.id
        var descriptor = FetchDescriptor<ProviderEntity>(
            predicate: #Predicate<ProviderEntity> { $0.id == providerID }
        )
        descriptor.fetchLimit = 1

        let entity: ProviderEntity
        if let existing = try context.fetch(descriptor).first {
            entity = existing
        } else {
            entity = ProviderEntity(
                id: provider.id,
                providerTypeRawValue: provider.providerType.rawValue,
                name: provider.name,
                baseURL: provider.baseURL,
                apiKey: provider.apiKey,
                createdAt: provider.createdAt,
                updatedAt: provider.updatedAt
            )
            context.insert(entity)
        }

        entity.providerTypeRawValue = provider.providerType.rawValue
        entity.name = provider.name
        entity.baseURL = provider.baseURL
        entity.apiKey = provider.apiKey
        entity.createdAt = provider.createdAt
        entity.updatedAt = provider.updatedAt

        for model in entity.models {
            context.delete(model)
        }
        entity.models.removeAll()

        for modelId in provider.enabledModelIds {
            let modelEntity = ProviderModelEntity(modelId: modelId, provider: entity)
            context.insert(modelEntity)
            entity.models.append(modelEntity)
        }

        try context.save()
    }

    func deleteProvider(id: Int32) throws {
        let context = ModelContext(container)
        let providerID = id
        var descriptor = FetchDescriptor<ProviderEntity>(
            predicate: #Predicate<ProviderEntity> { $0.id == providerID }
        )
        descriptor.fetchLimit = 1

        guard let entity = try context.fetch(descriptor).first else {
            throw ServiceCoreError.providerNotFound(id)
        }

        context.delete(entity)
        try context.save()
    }

    func upsertRoute(_ route: RouteConfiguration) throws {
        let context = ModelContext(container)
        let routeInternalID = route.id
        var descriptor = FetchDescriptor<RouteEntity>(
            predicate: #Predicate<RouteEntity> { $0.id == routeInternalID }
        )
        descriptor.fetchLimit = 1

        let entity: RouteEntity
        if let existing = try context.fetch(descriptor).first {
            entity = existing
        } else {
            entity = RouteEntity(
                id: route.id,
                routeId: route.routeId,
                strategyRawValue: route.strategy.rawValue,
                reasoning: route.reasoning,
                toolCalling: route.toolCalling,
                inputFormatsMask: route.inputFormatsMask,
                outputFormatsMask: route.outputFormatsMask,
                createdAt: route.createdAt,
                updatedAt: route.updatedAt
            )
            context.insert(entity)
        }

        entity.routeId = route.routeId
        entity.strategyRawValue = route.strategy.rawValue
        entity.reasoning = route.reasoning
        entity.toolCalling = route.toolCalling
        entity.inputFormatsMask = route.inputFormatsMask
        entity.outputFormatsMask = route.outputFormatsMask
        entity.createdAt = route.createdAt
        entity.updatedAt = route.updatedAt

        for candidate in entity.candidates {
            context.delete(candidate)
        }
        entity.candidates.removeAll()

        for candidate in route.candidates {
            let candidateEntity = RouteCandidateEntity(
                providerId: candidate.providerId,
                modelId: candidate.modelId,
                route: entity
            )
            context.insert(candidateEntity)
            entity.candidates.append(candidateEntity)
        }

        try context.save()
    }

    func deleteRoute(id: Int32) throws {
        let context = ModelContext(container)
        let routeInternalID = id
        var descriptor = FetchDescriptor<RouteEntity>(
            predicate: #Predicate<RouteEntity> { $0.id == routeInternalID }
        )
        descriptor.fetchLimit = 1

        guard let entity = try context.fetch(descriptor).first else {
            throw ServiceCoreError.routeNotFound(id)
        }

        context.delete(entity)
        try context.save()
    }
}

private final class AccessStore {
    private let container: ModelContainer

    init() throws {
        let local = ModelConfiguration("AccessStore", cloudKitDatabase: .none)
        container = try ModelContainer(for: ClientAccessEntity.self, configurations: local)
    }

    func loadAll() throws -> [ClientAccessEntity] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ClientAccessEntity>(
            sortBy: [SortDescriptor(\.id, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func save(_ update: (ModelContext) throws -> Void) throws {
        let context = ModelContext(container)
        try update(context)
        try context.save()
    }
}

private final class MetricsStore {
    private let container: ModelContainer

    init() throws {
        let local = ModelConfiguration("MetricsStore", cloudKitDatabase: .none)
        container = try ModelContainer(for: MetricEventEntity.self, configurations: local)
    }

    func record(_ event: MetricEvent) throws {
        let context = ModelContext(container)
        let entity = MetricEventEntity(
            id: event.id,
            timestamp: event.timestamp,
            requestCount: Int64(event.requestCount),
            promptTokens: Int64(event.promptTokens),
            completionTokens: Int64(event.completionTokens),
            totalTokens: Int64(event.totalTokens),
            estimatedCostUsd: event.estimatedCostUsd
        )
        context.insert(entity)
        try context.save()
    }

    func stats(from start: Date, to end: Date) throws -> StatsSnapshot {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<MetricEventEntity>(
            predicate: #Predicate<MetricEventEntity> {
                $0.timestamp >= start && $0.timestamp < end
            }
        )
        let events = try context.fetch(descriptor)

        var result = StatsSnapshot(
            requestCount: 0,
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: 0,
            estimatedCostUsd: 0
        )

        for event in events {
            result.requestCount += event.requestCount
            result.promptTokens += event.promptTokens
            result.completionTokens += event.completionTokens
            result.totalTokens += event.totalTokens
            result.estimatedCostUsd += event.estimatedCostUsd
        }

        return result
    }
}

private struct ConnectionRuntime: Sendable {
    var connectionId: Int32
    var caller: XPCCaller
    var connectedAt: Date
    var requestCount: Int64
    var activeStreamCount: Int32
}

actor ServiceCore {
    private let providerRouteStore: ProviderRouteStore
    private let accessStore: AccessStore
    private let metricsStore: MetricsStore
    private let calendar: Calendar

    private var connectionIDSeed: Int32 = 1
    private var requestIDSeed: Int64 = 1
    private var streamOwnerConnectionByRequestID: [Int64: Int32] = [:]
    private var connectionsByID: [Int32: ConnectionRuntime] = [:]

    init(calendar: Calendar = .current) throws {
        self.providerRouteStore = try ProviderRouteStore()
        self.accessStore = try AccessStore()
        self.metricsStore = try MetricsStore()
        self.calendar = calendar
    }

    func restoreState() throws -> RestoredState {
        let providerCount = try providerRouteStore.loadProviders().count
        let routeCount = try providerRouteStore.loadRoutes().count
        let accessCount = try accessStore.loadAll().count

        return RestoredState(providerCount: providerCount, routeCount: routeCount, accessCount: accessCount)
    }

    // MARK: Connection / Stream Runtime

    func registerConnection(caller: XPCCaller) -> Int32 {
        let id = connectionIDSeed
        connectionIDSeed += 1

        connectionsByID[id] = ConnectionRuntime(
            connectionId: id,
            caller: caller,
            connectedAt: Date(),
            requestCount: 0,
            activeStreamCount: 0
        )
        return id
    }

    func unregisterConnection(connectionID: Int32) {
        connectionsByID.removeValue(forKey: connectionID)

        var staleRequestIDs: [Int64] = []
        for (requestID, owner) in streamOwnerConnectionByRequestID where owner == connectionID {
            staleRequestIDs.append(requestID)
        }
        for requestID in staleRequestIDs {
            streamOwnerConnectionByRequestID.removeValue(forKey: requestID)
        }
    }

    func recordRequest(caller: XPCCaller) {
        if let connectionID = matchingConnectionID(for: caller), var connection = connectionsByID[connectionID] {
            connection.requestCount += 1
            connectionsByID[connectionID] = connection
        }
    }

    func allocateRequestID() -> Int64 {
        let id = requestIDSeed
        requestIDSeed += 1
        return id
    }

    func registerActiveStream(requestID: Int64, caller: XPCCaller) {
        guard let connectionID = matchingConnectionID(for: caller) else { return }
        streamOwnerConnectionByRequestID[requestID] = connectionID

        if var connection = connectionsByID[connectionID] {
            connection.activeStreamCount += 1
            connectionsByID[connectionID] = connection
        }
    }

    func finishActiveStream(requestID: Int64) {
        guard let connectionID = streamOwnerConnectionByRequestID.removeValue(forKey: requestID) else {
            return
        }

        if var connection = connectionsByID[connectionID] {
            connection.activeStreamCount = max(0, connection.activeStreamCount - 1)
            connectionsByID[connectionID] = connection
        }
    }

    func listConnections() -> [ConnectionSnapshot] {
        connectionsByID.values
            .sorted { $0.connectionId < $1.connectionId }
            .map {
                ConnectionSnapshot(
                    connectionId: $0.connectionId,
                    caller: $0.caller,
                    connectedAt: $0.connectedAt,
                    requestCount: $0.requestCount,
                    hasActiveStream: $0.activeStreamCount > 0
                )
            }
    }

    private func matchingConnectionID(for caller: XPCCaller) -> Int32? {
        for (id, runtime) in connectionsByID {
            if runtime.caller == caller {
                return id
            }
        }
        return nil
    }

    // MARK: Authorization

    func evaluateAccess(caller: XPCCaller) throws -> AccessDecision {
        let now = Date()
        let all = try accessStore.loadAll()

        if let existing = all.first(where: { $0.identityKey == caller.identityKey }) {
            let existingID = existing.id
            try accessStore.save { context in
                let accessEntityID = existingID
                var descriptor = FetchDescriptor<ClientAccessEntity>(
                    predicate: #Predicate<ClientAccessEntity> { $0.id == accessEntityID }
                )
                descriptor.fetchLimit = 1
                guard let entity = try context.fetch(descriptor).first else {
                    return
                }
                entity.pid = caller.pid
                entity.euid = Int64(caller.euid)
                entity.egid = Int64(caller.egid)
                entity.auditSession = caller.auditSession
                entity.requestCount += 1
                entity.lastSeenAt = now
            }

            if existing.isAllowed {
                return .allow
            }
            if let deniedUntil = existing.deniedUntilUtc, deniedUntil > now {
                return .denyCooldown(until: deniedUntil)
            }
            return .prompt
        }

        let newID = (all.map(\.id).max() ?? 0) + 1
        try accessStore.save { context in
            context.insert(
                ClientAccessEntity(
                    id: newID,
                    identityKey: caller.identityKey,
                    pid: caller.pid,
                    euid: Int64(caller.euid),
                    egid: Int64(caller.egid),
                    auditSession: caller.auditSession,
                    requestCount: 1,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    isAllowed: false,
                    deniedUntilUtc: nil
                )
            )
        }

        return .prompt
    }

    func applyAccessPromptDecision(caller: XPCCaller, isAllowed: Bool) throws {
        let now = Date()
        let deniedUntil = isAllowed ? nil : now.addingTimeInterval(24 * 60 * 60)

        let all = try accessStore.loadAll()
        if let existing = all.first(where: { $0.identityKey == caller.identityKey }) {
            let existingID = existing.id
            try accessStore.save { context in
                let accessEntityID = existingID
                var descriptor = FetchDescriptor<ClientAccessEntity>(
                    predicate: #Predicate<ClientAccessEntity> { $0.id == accessEntityID }
                )
                descriptor.fetchLimit = 1
                guard let entity = try context.fetch(descriptor).first else {
                    return
                }
                entity.isAllowed = isAllowed
                entity.deniedUntilUtc = deniedUntil
                entity.lastSeenAt = now
                entity.pid = caller.pid
                entity.euid = Int64(caller.euid)
                entity.egid = Int64(caller.egid)
                entity.auditSession = caller.auditSession
            }
            return
        }

        let newID = (all.map(\.id).max() ?? 0) + 1
        try accessStore.save { context in
            context.insert(
                ClientAccessEntity(
                    id: newID,
                    identityKey: caller.identityKey,
                    pid: caller.pid,
                    euid: Int64(caller.euid),
                    egid: Int64(caller.egid),
                    auditSession: caller.auditSession,
                    requestCount: 1,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    isAllowed: isAllowed,
                    deniedUntilUtc: deniedUntil
                )
            )
        }
    }

    func listClientAccess() throws -> [ClientAccessSnapshot] {
        try accessStore.loadAll()
            .map { $0.toDomain() }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    func updateClientAccessAllowed(accessID: Int32, isAllowed: Bool) throws {
        let deniedUntil = isAllowed ? nil : Date().addingTimeInterval(24 * 60 * 60)
        let accessEntityID = accessID

        try accessStore.save { context in
            var descriptor = FetchDescriptor<ClientAccessEntity>(
                predicate: #Predicate<ClientAccessEntity> { $0.id == accessEntityID }
            )
            descriptor.fetchLimit = 1

            guard let entity = try context.fetch(descriptor).first else {
                throw ServiceCoreError.accessNotFound(accessID)
            }

            entity.isAllowed = isAllowed
            entity.deniedUntilUtc = deniedUntil
            entity.lastSeenAt = Date()
        }
    }

    // MARK: Provider CRUD

    func listProviders() throws -> [ProviderConfiguration] {
        try providerRouteStore.loadProviders().sorted { $0.id < $1.id }
    }

    func addProvider(
        providerType: ProviderType,
        name: String,
        baseURL: String,
        apiKey: String
    ) throws -> Int32 {
        let providers = try providerRouteStore.loadProviders()
        let newID = (providers.map(\.id).max() ?? 0) + 1
        let now = Date()

        let provider = ProviderConfiguration(
            id: newID,
            providerType: providerType,
            name: name,
            baseURL: baseURL,
            apiKey: apiKey,
            enabledModelIds: [],
            createdAt: now,
            updatedAt: now
        )
        try providerRouteStore.upsertProvider(provider)
        return newID
    }

    func updateProvider(
        providerID: Int32,
        name: String,
        baseURL: String,
        enabledModelIds: [String],
        apiKey: String?
    ) throws {
        let providers = try providerRouteStore.loadProviders()
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
            throw ServiceCoreError.providerNotFound(providerID)
        }

        var provider = providers[index]
        provider.name = name
        provider.baseURL = baseURL
        provider.enabledModelIds = Array(Set(enabledModelIds)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        provider.updatedAt = Date()
        if let apiKey {
            provider.apiKey = apiKey
        }

        try providerRouteStore.upsertProvider(provider)
    }

    func deleteProvider(providerID: Int32) throws {
        try providerRouteStore.deleteProvider(id: providerID)
    }

    func providerByID(_ providerID: Int32) throws -> ProviderConfiguration {
        guard let provider = try providerRouteStore.loadProviders().first(where: { $0.id == providerID }) else {
            throw ServiceCoreError.providerNotFound(providerID)
        }
        return provider
    }

    // MARK: Route CRUD

    func listRoutes() throws -> [RouteConfiguration] {
        try providerRouteStore.loadRoutes().sorted { $0.id < $1.id }
    }

    func addRoute(
        routeId: String,
        strategy: RouteStrategy,
        candidates: [RouteCandidate],
        reasoning: Bool,
        toolCalling: Bool,
        inputFormatsMask: Int32,
        outputFormatsMask: Int32
    ) throws -> Int32 {
        let routes = try providerRouteStore.loadRoutes()
        let providers = try providerRouteStore.loadProviders()
        if routes.contains(where: { $0.routeId == routeId }) {
            throw ServiceCoreError.duplicateRouteID(routeId)
        }
        try Self.validateRouteCandidates(candidates, routeID: routeId, providers: providers)

        let newID = (routes.map(\.id).max() ?? 0) + 1
        let now = Date()

        let route = RouteConfiguration(
            id: newID,
            routeId: routeId,
            strategy: strategy,
            candidates: candidates,
            reasoning: reasoning,
            toolCalling: toolCalling,
            inputFormatsMask: inputFormatsMask,
            outputFormatsMask: outputFormatsMask,
            createdAt: now,
            updatedAt: now
        )

        try providerRouteStore.upsertRoute(route)
        return newID
    }

    func updateRoute(
        id: Int32,
        routeId: String,
        strategy: RouteStrategy,
        candidates: [RouteCandidate],
        reasoning: Bool,
        toolCalling: Bool,
        inputFormatsMask: Int32,
        outputFormatsMask: Int32
    ) throws {
        let routes = try providerRouteStore.loadRoutes()
        let providers = try providerRouteStore.loadProviders()
        guard let index = routes.firstIndex(where: { $0.id == id }) else {
            throw ServiceCoreError.routeNotFound(id)
        }
        if routes.contains(where: { $0.routeId == routeId && $0.id != id }) {
            throw ServiceCoreError.duplicateRouteID(routeId)
        }
        try Self.validateRouteCandidates(candidates, routeID: routeId, providers: providers)

        var route = routes[index]
        route.routeId = routeId
        route.strategy = strategy
        route.candidates = candidates
        route.reasoning = reasoning
        route.toolCalling = toolCalling
        route.inputFormatsMask = inputFormatsMask
        route.outputFormatsMask = outputFormatsMask
        route.updatedAt = Date()

        try providerRouteStore.upsertRoute(route)
    }

    func deleteRoute(id: Int32) throws {
        try providerRouteStore.deleteRoute(id: id)
    }

    // MARK: Capability routing

    func listModelCapabilities() throws -> [ModelCapabilityInfo] {
        let providers = try providerRouteStore.loadProviders()
        let routes = try providerRouteStore.loadRoutes()
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })

        struct Aggregate {
            var reasoning: Bool = false
            var toolCalling: Bool = false
            var inputMask: Int32 = 0
            var outputMask: Int32 = 0
            var available: Bool = false
        }

        var byModel: [String: Aggregate] = [:]

        for route in routes {
            for candidate in route.candidates {
                guard let provider = providersByID[candidate.providerId] else {
                    throw ServiceCoreError.routeCandidateProviderNotFound(
                        routeID: route.routeId,
                        providerID: candidate.providerId,
                        modelID: candidate.modelId
                    )
                }
                guard provider.enabledModelIds.contains(candidate.modelId) else {
                    throw ServiceCoreError.routeCandidateModelNotEnabled(
                        routeID: route.routeId,
                        providerID: candidate.providerId,
                        modelID: candidate.modelId
                    )
                }

                var aggregate = byModel[route.routeId, default: Aggregate()]
                aggregate.reasoning = aggregate.reasoning || route.reasoning
                aggregate.toolCalling = aggregate.toolCalling || route.toolCalling
                aggregate.inputMask |= route.inputFormatsMask
                aggregate.outputMask |= route.outputFormatsMask
                aggregate.available = true
                byModel[route.routeId] = aggregate
            }
        }

        return byModel
            .map { modelID, aggregate in
                ModelCapabilityInfo(
                    modelId: modelID,
                    reasoning: aggregate.reasoning,
                    toolCalling: aggregate.toolCalling,
                    inputFormats: Self.mediaFormats(from: aggregate.inputMask),
                    outputFormats: Self.mediaFormats(from: aggregate.outputMask),
                    available: aggregate.available
                )
            }
            .sorted { $0.modelId.localizedStandardCompare($1.modelId) == .orderedAscending }
    }

    func resolveCandidates(for modelID: String) throws -> [ResolvedCandidate] {
        let providers = try providerRouteStore.loadProviders()
        let routes = try providerRouteStore.loadRoutes()
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })

        var resolved: [ResolvedCandidate] = []
        var seenKeys: Set<String> = []

        for route in routes {
            var matched = route.routeId == modelID ? route.candidates : []
            if !matched.isEmpty {
                if route.strategy == .random {
                    matched.shuffle()
                }

                for candidate in matched {
                    guard let provider = providersByID[candidate.providerId] else {
                        throw ServiceCoreError.routeCandidateProviderNotFound(
                            routeID: route.routeId,
                            providerID: candidate.providerId,
                            modelID: candidate.modelId
                        )
                    }
                    guard provider.enabledModelIds.contains(candidate.modelId) else {
                        throw ServiceCoreError.routeCandidateModelNotEnabled(
                            routeID: route.routeId,
                            providerID: candidate.providerId,
                            modelID: candidate.modelId
                        )
                    }

                    let key = "\(provider.id)::\(candidate.modelId)"
                    if seenKeys.insert(key).inserted {
                        resolved.append(ResolvedCandidate(provider: provider, modelId: candidate.modelId))
                    }
                }
            }
        }

        if resolved.isEmpty {
            throw ServiceCoreError.noRouteCandidate(modelID)
        }

        return resolved
    }

    private static func mediaFormats(from mask: Int32) -> [MediaFormat] {
        MediaFormat.allCases.filter { mask & $0.bit != 0 }
    }

    private static func validateRouteCandidates(
        _ candidates: [RouteCandidate],
        routeID: String,
        providers: [ProviderConfiguration]
    ) throws {
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        for candidate in candidates {
            guard let provider = providersByID[candidate.providerId] else {
                throw ServiceCoreError.routeCandidateProviderNotFound(
                    routeID: routeID,
                    providerID: candidate.providerId,
                    modelID: candidate.modelId
                )
            }
            guard provider.enabledModelIds.contains(candidate.modelId) else {
                throw ServiceCoreError.routeCandidateModelNotEnabled(
                    routeID: routeID,
                    providerID: candidate.providerId,
                    modelID: candidate.modelId
                )
            }
        }
    }

    // MARK: Metrics

    func recordMetric(_ event: MetricEvent) throws {
        try metricsStore.record(event)
    }

    func getDailyStats(year: Int32, month: Int32, day: Int32) throws -> StatsSnapshot {
        var components = DateComponents()
        components.year = Int(year)
        components.month = Int(month)
        components.day = Int(day)
        components.hour = 0
        components.minute = 0
        components.second = 0

        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw ServiceCoreError.invalidDateComponents
        }

        return try metricsStore.stats(from: start, to: end)
    }

    func getMonthlyStats(year: Int32, month: Int32) throws -> StatsSnapshot {
        var components = DateComponents()
        components.year = Int(year)
        components.month = Int(month)
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0

        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else {
            throw ServiceCoreError.invalidDateComponents
        }

        return try metricsStore.stats(from: start, to: end)
    }
}
