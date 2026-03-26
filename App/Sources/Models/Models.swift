import Foundation
import Client

enum ProviderType: String, CaseIterable, Identifiable, Codable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case gemini = "Gemini"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .openAI:
            return String(localized: "app.providerType.openAI")
        case .anthropic:
            return String(localized: "app.providerType.anthropic")
        case .gemini:
            return String(localized: "app.providerType.gemini")
        }
    }

    var clientValue: Client.ProviderType {
        switch self {
        case .openAI:
            return .openAI
        case .anthropic:
            return .anthropic
        case .gemini:
            return .gemini
        }
    }

    init(clientValue: Client.ProviderType) {
        switch clientValue {
        case .openAI:
            self = .openAI
        case .anthropic:
            self = .anthropic
        case .gemini:
            self = .gemini
        }
    }
}

enum RouteStrategy: String, CaseIterable, Identifiable, Codable {
    case ordered = "Ordered"
    case random = "Random"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .ordered:
            return String(localized: "app.routeStrategy.ordered")
        case .random:
            return String(localized: "app.routeStrategy.random")
        }
    }

    var clientValue: Client.RouteStrategy {
        switch self {
        case .ordered:
            return .ordered
        case .random:
            return .random
        }
    }

    init(clientValue: Client.RouteStrategy) {
        switch clientValue {
        case .ordered:
            self = .ordered
        case .random:
            self = .random
        }
    }
}

@Observable
final class Provider: Identifiable {
    let id: UUID
    var serviceID: Int32
    var name: String
    var type: ProviderType
    var baseURL: String
    var apiKey: String
    var models: [ModelInfo]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        serviceID: Int32 = 0,
        name: String = "",
        type: ProviderType = .openAI,
        baseURL: String = "",
        apiKey: String = "",
        models: [ModelInfo] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.serviceID = serviceID
        self.name = name
        self.type = type
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Observable
final class ModelInfo: Identifiable {
    let id: UUID
    var name: String
    var enabled: Bool

    init(id: UUID = UUID(), name: String, enabled: Bool = false) {
        self.id = id
        self.name = name
        self.enabled = enabled
    }
}

@Observable
final class RouteRule: Identifiable {
    let id: UUID
    var serviceID: Int32
    var routeId: String
    var strategy: RouteStrategy
    var capabilityReasoning: Bool
    var capabilityToolCalling: Bool
    var inputImage: Bool
    var inputVideo: Bool
    var inputAudio: Bool
    var outputImage: Bool
    var outputVideo: Bool
    var outputAudio: Bool
    var candidates: [CandidateTarget]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        serviceID: Int32 = 0,
        routeId: String = "",
        strategy: RouteStrategy = .ordered,
        capabilityReasoning: Bool = false,
        capabilityToolCalling: Bool = false,
        inputImage: Bool = false,
        inputVideo: Bool = false,
        inputAudio: Bool = false,
        outputImage: Bool = false,
        outputVideo: Bool = false,
        outputAudio: Bool = false,
        candidates: [CandidateTarget] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.serviceID = serviceID
        self.routeId = routeId
        self.strategy = strategy
        self.capabilityReasoning = capabilityReasoning
        self.capabilityToolCalling = capabilityToolCalling
        self.inputImage = inputImage
        self.inputVideo = inputVideo
        self.inputAudio = inputAudio
        self.outputImage = outputImage
        self.outputVideo = outputVideo
        self.outputAudio = outputAudio
        self.candidates = candidates
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Observable
final class CandidateTarget: Identifiable {
    let id: UUID
    var providerServiceID: Int32?
    var modelName: String

    init(id: UUID = UUID(), providerServiceID: Int32? = nil, modelName: String = "") {
        self.id = id
        self.providerServiceID = providerServiceID
        self.modelName = modelName
    }
}

struct XPCCallerSnapshot: Equatable {
    var pid: Int32
    var euid: UInt32
    var egid: UInt32
    var auditSession: Int32

    var friendlyLabel: String {
        String(
            format: String(localized: "app.caller.friendlyLabel.format"),
            locale: .current,
            Int(auditSession),
            euid,
            egid,
            Int(pid)
        )
    }
}

@Observable
final class ConnectionEntry: Identifiable {
    let id: UUID
    var connectionId: Int32
    var caller: XPCCallerSnapshot
    var connectedAt: Date
    var requestCount: Int64
    var hasActiveStream: Bool

    init(
        id: UUID = UUID(),
        connectionId: Int32,
        caller: XPCCallerSnapshot,
        connectedAt: Date,
        requestCount: Int64,
        hasActiveStream: Bool
    ) {
        self.id = id
        self.connectionId = connectionId
        self.caller = caller
        self.connectedAt = connectedAt
        self.requestCount = requestCount
        self.hasActiveStream = hasActiveStream
    }
}

@Observable
final class AllowlistEntry: Identifiable {
    let id: UUID
    var serviceID: Int32
    var caller: XPCCallerSnapshot
    var requestCount: Int64
    var firstSeenAt: Date
    var lastSeenAt: Date
    var allowed: Bool
    var deniedUntilUtc: Date?

    init(
        id: UUID = UUID(),
        serviceID: Int32,
        caller: XPCCallerSnapshot,
        requestCount: Int64,
        firstSeenAt: Date,
        lastSeenAt: Date,
        allowed: Bool,
        deniedUntilUtc: Date?
    ) {
        self.id = id
        self.serviceID = serviceID
        self.caller = caller
        self.requestCount = requestCount
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.allowed = allowed
        self.deniedUntilUtc = deniedUntilUtc
    }
}

struct DashboardStats {
    var todayRequests: Int64 = 0
    var todayTokens: Int64 = 0
    var todayCost: Double = 0
    var monthRequests: Int64 = 0
    var monthTokens: Int64 = 0
    var monthCost: Double = 0
}
