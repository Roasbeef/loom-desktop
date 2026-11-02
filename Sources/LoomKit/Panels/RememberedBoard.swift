import Foundation

/// What the session remembers for its operator: the permissions and exact-action
/// consents that "Allow for this session" left behind, each with who approved
/// it (protocol section 4.9.29). Forgetting is guarded by the sequence the
/// listing carried, so a stale listing is refused rather than applied.
public struct RememberedBoard: Sendable, Equatable {
    public struct Provenance: Sendable, Equatable {
        public let who: String
        public let via: String
        public let fingerprint: String?
        public let atMs: Int

        /// `Alice · sign-in 9c1e…`, saying which credential approved it.
        public var words: String {
            let kind: String
            switch via {
            case "login": kind = "browser sign-in"
            case "device": kind = "device credential"
            default: kind = "unrecorded credential"
            }
            return who + " · " + kind + (fingerprint.map { " " + String($0.prefix(8)) } ?? "")
        }
    }

    public struct Grant: Sendable, Equatable, Identifiable {
        public let grant: JSONValue
        public let provenance: Provenance?
        public var id: String { grant.compactText }
        public var words: String { Escalation.describe(grant) }
    }

    public struct Action: Sendable, Equatable, Identifiable {
        public let id: String
        public let seq: Int
        public let tool: String?
        public let strand: String?
        public let preview: String?
        public let provenance: Provenance?
    }

    /// The general fact's sequence, or nil while nothing is remembered.
    public let seq: Int?
    public let grants: [Grant]
    public let actions: [Action]

    public init?(_ board: JSONValue?) {
        guard let board, let grants = board["grants"]?.array, let actions = board["actions"]?.array else { return nil }
        seq = board["seq"]?.int
        self.grants = grants.compactMap { row in
            guard let grant = row["grant"] else { return nil }
            return Grant(grant: grant, provenance: Self.provenance(row["provenance"]))
        }
        self.actions = actions.compactMap { row in
            guard let id = row["id"]?.string else { return nil }
            return Action(
                id: id,
                seq: row["seq"]?.int ?? 0,
                tool: row["tool"]?.string,
                strand: row["strand"]?.string,
                preview: row["preview"]?.string,
                provenance: Self.provenance(row["provenance"])
            )
        }
    }

    private static func provenance(_ value: JSONValue?) -> Provenance? {
        guard let value, value != .null else { return nil }
        return Provenance(
            who: value["by"]?["name"]?.string ?? value["by"]?["principal"]?.string ?? "Someone",
            via: value["via"]?["kind"]?.string ?? "none",
            fingerprint: value["via"]?["fingerprint"]?.string,
            atMs: value["at_ms"]?.int ?? 0
        )
    }

    public var isEmpty: Bool { grants.isEmpty && actions.isEmpty }
    public var count: Int { grants.count + actions.count }

    /// The body of `permission_forget` for one remembered grant.
    public func forgetBody(grant: Grant) -> JSONValue {
        var body: [String: JSONValue] = ["target": ["kind": "grant", "grant": grant.grant]]
        if let seq { body["expected_seq"] = .int(Int64(seq)) }
        return .object(body)
    }

    /// The body of `permission_forget` for one exact-action consent.
    public func forgetBody(action: Action) -> JSONValue {
        .object([
            "target": ["kind": "action", "id": .string(action.id)],
            "expected_seq": .int(Int64(action.seq)),
        ])
    }

    /// The body of `permission_forget` for everything remembered.
    public var forgetAllBody: JSONValue {
        var body: [String: JSONValue] = ["target": ["kind": "all"]]
        if let seq { body["expected_seq"] = .int(Int64(seq)) }
        return .object(body)
    }
}
