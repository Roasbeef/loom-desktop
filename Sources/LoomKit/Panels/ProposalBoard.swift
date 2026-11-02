import Foundation

/// The standing rules a model suggested with its `propose` tool, awaiting a
/// person (protocol section 4.9.32). Nothing is written until a person approves.
public struct ProposalBoard: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        /// `rule`, `config`, or a kind this client does not know.
        public let kind: String
        public let target: String
        public let old: String
        public let new: String
        public let rationale: String
        public let session: String
        public let entry: String?
        public let state: String

        public var isPending: Bool { state == "pending" }

        /// A kind this client does not know is shown as unknown and offered no
        /// decision, because approving it would be approving a change unseen.
        public var isKnownKind: Bool { kind == "rule" || kind == "config" }

        public var canDecide: Bool { isPending && isKnownKind }

        /// `rule` or `config edit`, the noun the buttons and sentence use.
        public var kindWords: String {
            switch kind {
            case "rule": return "rule"
            case "config": return "config edit"
            default: return "unknown change"
            }
        }

        /// What the change does to the target: appends a rule, or replaces text.
        public var changeCounts: String {
            old.isEmpty ? "adds \(new.split(separator: "\n").count) line(s)" : "replaces existing text"
        }
    }

    public let rows: [Row]
    public let pending: Int
    public let limit: Int
    public let omitted: Int

    public init?(_ board: JSONValue?) {
        guard let board, let rows = board["proposals"]?.array else { return nil }
        self.rows = rows.compactMap { row in
            guard let id = row["id"]?.string, let state = row["state"]?.string else { return nil }
            return Row(
                id: id,
                kind: row["kind"]?.string ?? "unknown",
                target: row["target"]?.string ?? "",
                old: row["old"]?.string ?? "",
                new: row["new"]?.string ?? "",
                rationale: row["rationale"]?.string ?? "",
                session: row["source"]?["session"]?.string ?? "",
                entry: row["source"]?["entry"]?.string,
                state: state
            )
        }
        pending = board["pending"]?.int ?? self.rows.filter(\.isPending).count
        limit = board["limit"]?.int ?? 0
        omitted = board["omitted"]?.int ?? 0
    }

    public var pendingRows: [Row] { rows.filter(\.isPending) }
    public var decidedRows: [Row] { rows.filter { !$0.isPending } }
}
