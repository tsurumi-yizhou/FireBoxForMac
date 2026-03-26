import Foundation
import SwiftData

@Model
final class ProviderEntity {
    @Attribute(.unique) var id: Int32
    var providerTypeRawValue: String
    var name: String
    var baseURL: String
    var apiKey: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ProviderModelEntity.provider)
    var models: [ProviderModelEntity]

    init(
        id: Int32,
        providerTypeRawValue: String,
        name: String,
        baseURL: String,
        apiKey: String,
        createdAt: Date,
        updatedAt: Date,
        models: [ProviderModelEntity] = []
    ) {
        self.id = id
        self.providerTypeRawValue = providerTypeRawValue
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.models = models
    }
}

@Model
final class ProviderModelEntity {
    @Attribute(.unique) var rowID: UUID
    var modelId: String
    var provider: ProviderEntity?

    init(rowID: UUID = UUID(), modelId: String, provider: ProviderEntity? = nil) {
        self.rowID = rowID
        self.modelId = modelId
        self.provider = provider
    }
}

@Model
final class RouteEntity {
    @Attribute(.unique) var id: Int32
    var routeId: String
    var strategyRawValue: String
    var reasoning: Bool
    var toolCalling: Bool
    var inputFormatsMask: Int32
    var outputFormatsMask: Int32
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \RouteCandidateEntity.route)
    var candidates: [RouteCandidateEntity]

    init(
        id: Int32,
        routeId: String,
        strategyRawValue: String,
        reasoning: Bool,
        toolCalling: Bool,
        inputFormatsMask: Int32,
        outputFormatsMask: Int32,
        createdAt: Date,
        updatedAt: Date,
        candidates: [RouteCandidateEntity] = []
    ) {
        self.id = id
        self.routeId = routeId
        self.strategyRawValue = strategyRawValue
        self.reasoning = reasoning
        self.toolCalling = toolCalling
        self.inputFormatsMask = inputFormatsMask
        self.outputFormatsMask = outputFormatsMask
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.candidates = candidates
    }
}

@Model
final class RouteCandidateEntity {
    @Attribute(.unique) var rowID: UUID
    var providerId: Int32
    var modelId: String
    var route: RouteEntity?

    init(rowID: UUID = UUID(), providerId: Int32, modelId: String, route: RouteEntity? = nil) {
        self.rowID = rowID
        self.providerId = providerId
        self.modelId = modelId
        self.route = route
    }
}

@Model
final class ClientAccessEntity {
    @Attribute(.unique) var id: Int32
    @Attribute(.unique) var identityKey: String
    var pid: Int32
    var euid: Int64
    var egid: Int64
    var auditSession: Int32
    var requestCount: Int64
    var firstSeenAt: Date
    var lastSeenAt: Date
    var isAllowed: Bool
    var deniedUntilUtc: Date?

    init(
        id: Int32,
        identityKey: String,
        pid: Int32,
        euid: Int64,
        egid: Int64,
        auditSession: Int32,
        requestCount: Int64,
        firstSeenAt: Date,
        lastSeenAt: Date,
        isAllowed: Bool,
        deniedUntilUtc: Date?
    ) {
        self.id = id
        self.identityKey = identityKey
        self.pid = pid
        self.euid = euid
        self.egid = egid
        self.auditSession = auditSession
        self.requestCount = requestCount
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.isAllowed = isAllowed
        self.deniedUntilUtc = deniedUntilUtc
    }
}

@Model
final class MetricEventEntity {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var requestCount: Int64
    var promptTokens: Int64
    var completionTokens: Int64
    var totalTokens: Int64
    var estimatedCostUsd: Double

    init(
        id: UUID,
        timestamp: Date,
        requestCount: Int64,
        promptTokens: Int64,
        completionTokens: Int64,
        totalTokens: Int64,
        estimatedCostUsd: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.requestCount = requestCount
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.estimatedCostUsd = estimatedCostUsd
    }
}

extension ProviderEntity {
    func toDomain() throws -> ProviderConfiguration {
        guard let providerType = ProviderType.parse(providerTypeRawValue) else {
            throw ServiceCoreError.invalidProviderType(providerTypeRawValue)
        }

        let enabledModelIds = models
            .map(\.modelId)
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return ProviderConfiguration(
            id: id,
            providerType: providerType,
            name: name,
            baseURL: baseURL,
            apiKey: apiKey,
            enabledModelIds: enabledModelIds,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

extension RouteEntity {
    func toDomain() throws -> RouteConfiguration {
        guard let strategy = RouteStrategy.parse(strategyRawValue) else {
            throw ServiceCoreError.invalidRouteStrategy(strategyRawValue)
        }

        let mappedCandidates = candidates.map { RouteCandidate(providerId: $0.providerId, modelId: $0.modelId) }

        return RouteConfiguration(
            id: id,
            routeId: routeId,
            strategy: strategy,
            candidates: mappedCandidates,
            reasoning: reasoning,
            toolCalling: toolCalling,
            inputFormatsMask: inputFormatsMask,
            outputFormatsMask: outputFormatsMask,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

extension ClientAccessEntity {
    func toDomain() -> ClientAccessSnapshot {
        ClientAccessSnapshot(
            id: id,
            caller: XPCCaller(
                pid: pid,
                euid: UInt32(clamping: euid),
                egid: UInt32(clamping: egid),
                auditSession: auditSession
            ),
            requestCount: requestCount,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            isAllowed: isAllowed,
            deniedUntilUtc: deniedUntilUtc
        )
    }
}

extension MetricEventEntity {
    func toDomain() -> MetricEvent {
        MetricEvent(
            id: id,
            timestamp: timestamp,
            requestCount: Int(requestCount),
            promptTokens: Int(promptTokens),
            completionTokens: Int(completionTokens),
            totalTokens: Int(totalTokens),
            estimatedCostUsd: estimatedCostUsd
        )
    }
}
