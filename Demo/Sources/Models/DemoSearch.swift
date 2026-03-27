import Foundation

enum DemoSearchMatchedField: String, Sendable {
    case title
    case message
}

enum DemoSearchTarget: Hashable, Sendable {
    case session(sessionID: UUID, messageID: UUID?)

    var sessionID: UUID? {
        switch self {
        case .session(let sessionID, _):
            return sessionID
        }
    }

    var messageID: UUID? {
        switch self {
        case .session(_, let messageID):
            return messageID
        }
    }
}

struct DemoSearchMessageSnapshot: Sendable {
    let id: UUID
    let content: String
}

struct DemoSearchSessionSnapshot: Sendable {
    let id: UUID
    let order: Int
    let title: String
    let messages: [DemoSearchMessageSnapshot]
}

struct DemoSearchRequest: Sendable {
    let query: String
    let limit: Int?
    let sessionSnapshot: [DemoSearchSessionSnapshot]
}

struct DemoSearchHit: Hashable, Sendable {
    let sourceID: String
    let target: DemoSearchTarget
    let score: Double
    let snippet: String
    let matchedField: DemoSearchMatchedField
}

struct DemoSearchSourceError: Identifiable, Hashable, Sendable {
    var id: String { sourceID }
    let sourceID: String
    let message: String
}

struct DemoSearchResponse: Sendable {
    let hits: [DemoSearchHit]
    let sourceErrors: [DemoSearchSourceError]

    static let empty = DemoSearchResponse(hits: [], sourceErrors: [])
}

protocol DemoSearchSource: Sendable {
    var sourceID: String { get }
    func search(_ request: DemoSearchRequest) async throws -> [DemoSearchHit]
}

actor DemoSearchCoordinator {
    private struct SourceRunResult: Sendable {
        let sourceID: String
        let hits: [DemoSearchHit]
        let error: String?
    }

    private let sources: [any DemoSearchSource]

    init(sources: [any DemoSearchSource]) {
        self.sources = sources
    }

    func search(_ request: DemoSearchRequest) async -> DemoSearchResponse {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .empty
        }

        let sourceResults = await withTaskGroup(of: SourceRunResult.self, returning: [SourceRunResult].self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let hits = try await source.search(request)
                        return SourceRunResult(sourceID: source.sourceID, hits: hits, error: nil)
                    } catch {
                        return SourceRunResult(
                            sourceID: source.sourceID,
                            hits: [],
                            error: error.localizedDescription
                        )
                    }
                }
            }

            var collected: [SourceRunResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        var dedupedByTarget: [DemoSearchTarget: DemoSearchHit] = [:]
        var sourceErrors: [DemoSearchSourceError] = []
        for result in sourceResults {
            if let error = result.error {
                sourceErrors.append(DemoSearchSourceError(sourceID: result.sourceID, message: error))
            }
            for hit in result.hits {
                if let current = dedupedByTarget[hit.target] {
                    if shouldReplace(existing: current, with: hit) {
                        dedupedByTarget[hit.target] = hit
                    }
                } else {
                    dedupedByTarget[hit.target] = hit
                }
            }
        }

        let sessionOrderByID = Dictionary(
            uniqueKeysWithValues: request.sessionSnapshot.map { ($0.id, $0.order) }
        )
        var mergedHits = Array(dedupedByTarget.values)
        mergedHits.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }

            let lhsOrder = lhs.target.sessionID.flatMap { sessionOrderByID[$0] } ?? Int.max
            let rhsOrder = rhs.target.sessionID.flatMap { sessionOrderByID[$0] } ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }

            return lhs.snippet.localizedStandardCompare(rhs.snippet) == .orderedAscending
        }

        if let limit = request.limit, limit > 0, mergedHits.count > limit {
            mergedHits = Array(mergedHits.prefix(limit))
        }

        return DemoSearchResponse(
            hits: mergedHits,
            sourceErrors: sourceErrors.sorted { $0.sourceID < $1.sourceID }
        )
    }

    private func shouldReplace(existing: DemoSearchHit, with candidate: DemoSearchHit) -> Bool {
        if candidate.score != existing.score {
            return candidate.score > existing.score
        }
        if candidate.matchedField != existing.matchedField {
            return candidate.matchedField == .title
        }
        return candidate.snippet.count < existing.snippet.count
    }
}

struct LocalSessionSearchSource: DemoSearchSource {
    let sourceID = "local.session"

    func search(_ request: DemoSearchRequest) async throws -> [DemoSearchHit] {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return []
        }

        var hits: [DemoSearchHit] = []
        hits.reserveCapacity(request.sessionSnapshot.count)
        for session in request.sessionSnapshot {
            if let hit = buildHit(for: session, query: query) {
                hits.append(hit)
            }
        }
        return hits
    }

    private func buildHit(for session: DemoSearchSessionSnapshot, query: String) -> DemoSearchHit? {
        let titleMatch = firstMatch(in: session.title, query: query)

        var bestMessageMatch: (
            id: UUID,
            score: Double,
            snippet: String,
            index: Int
        )?

        for (index, message) in session.messages.enumerated() {
            guard let range = firstMatch(in: message.content, query: query) else {
                continue
            }
            let score = messageScore(text: message.content, range: range, messageIndex: index)
            let snippet = snippet(text: message.content, around: range)
            if let current = bestMessageMatch {
                if score > current.score || (score == current.score && index < current.index) {
                    bestMessageMatch = (message.id, score, snippet, index)
                }
            } else {
                bestMessageMatch = (message.id, score, snippet, index)
            }
        }

        guard titleMatch != nil || bestMessageMatch != nil else {
            return nil
        }

        if let titleMatch {
            let messageID = bestMessageMatch?.id
            return DemoSearchHit(
                sourceID: sourceID,
                target: .session(sessionID: session.id, messageID: messageID),
                score: titleScore(text: session.title, range: titleMatch),
                snippet: session.title,
                matchedField: .title
            )
        }

        guard let bestMessageMatch else {
            return nil
        }

        return DemoSearchHit(
            sourceID: sourceID,
            target: .session(sessionID: session.id, messageID: bestMessageMatch.id),
            score: bestMessageMatch.score,
            snippet: bestMessageMatch.snippet,
            matchedField: .message
        )
    }

    private func firstMatch(in text: String, query: String) -> Range<String.Index>? {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func titleScore(text: String, range: Range<String.Index>) -> Double {
        let base = 200.0
        let position = positionBonus(text: text, range: range, maxBonus: 24.0)
        let length = lengthBonus(text: text, range: range, maxBonus: 16.0)
        return base + position + length
    }

    private func messageScore(text: String, range: Range<String.Index>, messageIndex: Int) -> Double {
        let base = 100.0
        let position = positionBonus(text: text, range: range, maxBonus: 18.0)
        let length = lengthBonus(text: text, range: range, maxBonus: 8.0)
        let messagePenalty = Double(messageIndex) * 0.05
        return base + position + length - messagePenalty
    }

    private func positionBonus(text: String, range: Range<String.Index>, maxBonus: Double) -> Double {
        let utf16Count = max(text.utf16.count, 1)
        let location = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let ratio = Double(location) / Double(utf16Count)
        return max(0.0, (1.0 - ratio) * maxBonus)
    }

    private func lengthBonus(text: String, range: Range<String.Index>, maxBonus: Double) -> Double {
        let utf16Count = max(text.utf16.count, 1)
        let matchedCount = max(text.utf16.distance(from: range.lowerBound, to: range.upperBound), 1)
        let ratio = Double(matchedCount) / Double(utf16Count)
        return ratio * maxBonus
    }

    private func snippet(text: String, around range: Range<String.Index>, maxLength: Int = 90) -> String {
        guard text.count > maxLength else {
            return text
        }

        let radius = maxLength / 2
        let lower = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex

        var value = String(text[lower..<upper])
        if lower > text.startIndex {
            value = "..." + value
        }
        if upper < text.endIndex {
            value += "..."
        }
        return value
    }
}
