import Foundation

enum ProviderType: String, CaseIterable, Codable, Sendable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case gemini = "Gemini"

    static func parse(_ raw: String) -> ProviderType? {
        if let exact = ProviderType(rawValue: raw) {
            return exact
        }
        switch raw.lowercased() {
        case "openai":
            return .openAI
        case "anthropic":
            return .anthropic
        case "gemini", "google", "googlegenerativeai":
            return .gemini
        default:
            return nil
        }
    }
}

enum RouteStrategy: String, CaseIterable, Codable, Sendable {
    case ordered = "Ordered"
    case random = "Random"

    static func parse(_ raw: String) -> RouteStrategy? {
        if let exact = RouteStrategy(rawValue: raw) {
            return exact
        }
        switch raw.lowercased() {
        case "ordered":
            return .ordered
        case "random":
            return .random
        default:
            return nil
        }
    }
}

enum ReasoningEffort: Int, Sendable {
    case `default` = 0
    case low = 1
    case medium = 2
    case high = 3
    case max = 4
}

enum MediaFormat: Int32, CaseIterable, Sendable {
    case image = 0
    case video = 1
    case audio = 2

    var bit: Int32 {
        switch self {
        case .image: return 1
        case .video: return 2
        case .audio: return 4
        }
    }
}

struct ProviderConfiguration: Sendable, Hashable {
    var id: Int32
    var providerType: ProviderType
    var name: String
    var baseURL: String
    var apiKey: String
    var enabledModelIds: [String]
    var createdAt: Date
    var updatedAt: Date
}

struct RouteCandidate: Sendable, Hashable {
    var providerId: Int32
    var modelId: String
}

struct RouteConfiguration: Sendable, Hashable {
    var id: Int32
    var routeId: String
    var strategy: RouteStrategy
    var candidates: [RouteCandidate]
    var reasoning: Bool
    var toolCalling: Bool
    var inputFormatsMask: Int32
    var outputFormatsMask: Int32
    var createdAt: Date
    var updatedAt: Date
}

struct XPCCaller: Sendable, Hashable {
    var pid: Int32
    var euid: UInt32
    var egid: UInt32
    var auditSession: Int32
    var codeSigningIdentifier: String?
    var codeSigningTeamIdentifier: String?
    var codeSigningUnique: String?
    var executablePath: String?

    static func == (lhs: XPCCaller, rhs: XPCCaller) -> Bool {
        lhs.pid == rhs.pid &&
        lhs.euid == rhs.euid &&
        lhs.egid == rhs.egid &&
        lhs.auditSession == rhs.auditSession
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(euid)
        hasher.combine(egid)
        hasher.combine(auditSession)
    }

    var identityKey: String {
        if let identifier = normalized(codeSigningIdentifier) {
            if let team = normalized(codeSigningTeamIdentifier) {
                // Stable across restarts and normal app upgrades for properly signed apps.
                return "codesign:v3:uid:\(euid):team:\(team):id:\(identifier)"
            }
            if let unique = normalized(codeSigningUnique) {
                // For ad-hoc or incomplete signatures, include a code-unique fallback.
                return "codesign:v3:uid:\(euid):id:\(identifier):unique:\(unique)"
            }
            return "codesign:v3:uid:\(euid):id:\(identifier)"
        }

        if let unique = normalized(codeSigningUnique) {
            return "codesign:v3:uid:\(euid):unique:\(unique)"
        }

        if let path = normalized(executablePath) {
            return "path:v1:uid:\(euid):gid:\(egid):exe:\(path)"
        }

        // Last-resort fallback keeps persistence across process restarts.
        return "legacy:v1:uid:\(euid):gid:\(egid)"
    }

    var dictionary: NSDictionary {
        [
            "pid": pid,
            "euid": euid,
            "egid": egid,
            "auditSession": auditSession,
        ] as NSDictionary
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ConnectionSnapshot: Sendable {
    var connectionId: Int32
    var caller: XPCCaller
    var connectedAt: Date
    var requestCount: Int64
    var hasActiveStream: Bool
}

struct ClientAccessSnapshot: Sendable {
    var id: Int32
    var caller: XPCCaller
    var requestCount: Int64
    var firstSeenAt: Date
    var lastSeenAt: Date
    var isAllowed: Bool
    var deniedUntilUtc: Date?
}

struct StatsSnapshot: Sendable {
    var requestCount: Int64
    var promptTokens: Int64
    var completionTokens: Int64
    var totalTokens: Int64
    var estimatedCostUsd: Double
}

struct ResolvedCandidate: Sendable {
    var provider: ProviderConfiguration
    var modelId: String
}

struct ModelCapabilityInfo: Sendable {
    var modelId: String
    var reasoning: Bool
    var toolCalling: Bool
    var inputFormats: [MediaFormat]
    var outputFormats: [MediaFormat]
    var available: Bool
}

struct RestoredState: Sendable {
    var providerCount: Int
    var routeCount: Int
    var accessCount: Int
}

enum AccessDecision: Sendable {
    case allow
    case prompt
    case denyCooldown(until: Date)
}

struct MetricEvent: Sendable {
    var id: UUID
    var timestamp: Date
    var requestCount: Int
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int
    var estimatedCostUsd: Double

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        requestCount: Int = 1,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        totalTokens: Int = 0,
        estimatedCostUsd: Double = 0
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
