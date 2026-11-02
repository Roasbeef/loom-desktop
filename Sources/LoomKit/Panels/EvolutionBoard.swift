import Foundation

/// The evolution catalogue: extensions, programs and prompts a session proposed
/// to extend itself, with the evidence for each and what is published.
///
/// The board is read with the `evolution` command and action `board`, and the
/// daemon announces a change with `evolution_changed`. A nested row that does
/// not decode fails its candidate, because dropping an approval or a piece of
/// evidence would draw a different candidate from the one the daemon sent, and
/// the difference is the one a person acts on.
public struct EvolutionBoard: Sendable, Equatable {
    public struct Evidence: Sendable, Equatable, Identifiable {
        public let id: String
        public let purpose: String
        public let verdict: String
        public let reason: String
        public let isCurrent: Bool

        public var purposeWords: String {
            switch purpose {
            case "author_tests": return "author's tests"
            case "independent_rollout": return "independent rollout"
            default: return purpose
            }
        }
    }

    public struct Candidate: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let kind: String
        public let scope: String
        public let description: String
        public let isCurrent: Bool
        public let approvedBy: String?
        public let selectedGeneration: Int?
        public let evidence: [Evidence]

        public var kindWords: String {
            switch kind {
            case "extension", "program", "prompt": return kind
            default: return "unknown kind"
            }
        }

        /// The evidence an approval would rest on: the newest passed result that
        /// still describes this candidate's current text.
        public var approvable: Evidence? {
            evidence.last { $0.verdict == "passed" && $0.isCurrent }
        }

        public var isApproved: Bool { approvedBy != nil }
    }

    public struct Selection: Sendable, Equatable, Identifiable {
        public let name: String
        public let scope: String
        public let candidate: String
        public let generation: Int
        public let isLive: Bool
        public var id: String { scope + "/" + name }
    }

    public struct Event: Sendable, Equatable, Identifiable {
        public let seq: Int
        public let decision: String
        public let name: String
        public let principal: String
        public let reason: String
        public var id: Int { seq }
    }

    public let candidates: [Candidate]
    public let selections: [Selection]
    public let history: [Event]
    public let pending: Int
    public let omittedCandidates: Int
    public let omittedHistory: Int

    public init?(_ board: JSONValue?) {
        guard let board, board["version"]?.int != nil else { return nil }
        var candidates: [Candidate] = []
        for row in board["candidates"]?.array ?? [] {
            guard let id = row["candidate_id"]?.string, let name = row["name"]?.string,
                  let kind = row["kind"]?.string, let scope = row["scope"] else { continue }
            var evidence: [Evidence] = []
            var intact = true
            for item in row["evidence"]?.array ?? [] {
                guard let eid = item["evidence_id"]?.string, let verdict = item["verdict"]?.string else {
                    intact = false
                    break
                }
                evidence.append(Evidence(
                    id: eid, purpose: item["purpose"]?.string ?? "", verdict: verdict,
                    reason: item["reason"]?.string ?? "", isCurrent: item["identity_current"]?.bool ?? false))
            }
            guard intact else { continue }
            candidates.append(Candidate(
                id: id, name: name, kind: kind, scope: Self.scopeWords(scope),
                description: row["description"]?.string ?? "",
                isCurrent: row["identity_current"]?.bool ?? false,
                approvedBy: row["approval"] == nil || row["approval"] == .null
                    ? nil : (row["approval"]?["by"]?.string ?? "someone"),
                selectedGeneration: row["selected"]?["generation"]?.int,
                evidence: evidence))
        }
        self.candidates = candidates
        selections = (board["selections"]?.array ?? []).compactMap { row in
            guard let name = row["name"]?.string, let candidate = row["candidate_id"]?.string,
                  let generation = row["generation"]?.int else { return nil }
            return Selection(name: name, scope: Self.scopeWords(row["scope"] ?? .null), candidate: candidate,
                             generation: generation, isLive: row["published"]?.bool ?? false)
        }
        history = (board["history"]?.array ?? []).compactMap { row in
            guard let seq = row["seq"]?.int, let decision = row["event"]?.string else { return nil }
            return Event(seq: seq, decision: decision, name: row["name"]?.string ?? row["candidate_id"]?.string ?? "",
                         principal: row["principal"]?.string ?? "", reason: row["reason"]?.string ?? "")
        }
        pending = board["pending"]?.array?.count ?? 0
        omittedCandidates = board["omitted"]?["candidates"]?.int ?? 0
        omittedHistory = board["omitted"]?["history"]?.int ?? 0
    }

    /// How many candidates are waiting for an approval, the figure on the tab.
    public var awaitingApproval: Int {
        candidates.filter { !$0.isApproved && $0.approvable != nil }.count
    }

    private static func scopeWords(_ scope: JSONValue) -> String {
        switch scope["kind"]?.string {
        case "session": return "this session"
        case "workspace": return "workspace " + (scope["workspace"]?.string ?? "")
        case "model": return "model " + (scope["model"]?.string ?? "")
        case let other?: return other
        case nil: return "unknown scope"
        }
    }
}

/// What the daemon's core reports about itself, from `core_status`. Its fields
/// are an open set, so they are shown as the daemon spelled them.
public struct CoreStatus: Sendable, Equatable {
    public let rows: [(name: String, value: String)]

    public init?(_ board: JSONValue?) {
        guard case .object(let fields)? = board else { return nil }
        rows = fields.keys.sorted().map { key in
            (key, fields[key]?.string ?? fields[key]?.compactText ?? "")
        }
    }

    public static func == (lhs: CoreStatus, rhs: CoreStatus) -> Bool {
        lhs.rows.count == rhs.rows.count && zip(lhs.rows, rhs.rows).allSatisfy { $0 == $1 }
    }
}
