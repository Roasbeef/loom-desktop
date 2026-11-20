import Foundation
import LoomKit

// What the session page lifts out of one session for a person who looked away: the
// approvals waiting on them, the asks and stuck strands that wait on them too, and
// the finds worth a look. It mirrors the web view's live rail ("Lifted from this
// session": loom packages/session_view/src/session_view/attention.gleam and
// packages/web_view/src/web_view/view/lifted.gleam), in the part the desktop can
// read from the daemon today.
//
// The rule is pure. It reads no clock and draws nothing, so a test states every
// decision. Words that carry a time take the clock as an argument, as `InboxRule`
// does.
//
// ## Flow
//
// `LiftRule.rows` turns the lane's pending approvals, the approval times from
// `approval.read` and the session's feed row into rows, pinned ones first.
// `LiftRule.mayAct` says whether a connection may press a row's buttons.
// `ApprovalWords` words the card from `approval.read`'s evidence, and
// `StreamWords.state` words the stream head.
//
// ## Where this departs from the web
//
// - The web also lifts what the lane shows: failed tool calls and turns, sub-agent
//   results and peer messages, as insights. The desktop lifts none of them yet, so
//   its Insights group holds finds only.
// - An open ask is listed and cannot be answered here. The web answers from the
//   rail through a path that is in the web view's process (loom
//   docs/client-protocol.md section 3.34 says `attention.answer` is not a control
//   command), so the row says where to answer.

/// One row of the rail.
public struct LiftedRow: Sendable, Equatable, Identifiable {
    /// Why the row was lifted. The set is closed, as the daemon's feed is.
    public enum Kind: Sendable, Equatable {
        /// A pending approval, with the tool that asked.
        case approval(tool: String)
        /// An open ask routed to the owner.
        case ask
        /// A strand that stopped on a failed run and has not run since.
        case stuck(strand: String)
        /// An open find, by what the agent calls it.
        case find(FindKind)
    }

    /// Whether a row stays until it is answered or folds once the reader has seen it.
    public enum Hold: Sendable, Equatable {
        case pinned
        case folds
    }

    /// A daemon identity with its kind as a prefix (`approval:`, `ask:`, `stuck:`,
    /// `find:`), never text a model wrote.
    public let id: String
    public let kind: Kind
    /// One line. Model text for an ask, a find and an approval's action, so a view
    /// draws it with `Text(verbatim:)`.
    public let head: String
    /// When the record was raised, in Unix milliseconds, or nil when it carries no
    /// time. A row with no time draws none.
    public let at: Int?

    public init(id: String, kind: Kind, head: String, at: Int?) {
        self.id = id
        self.kind = kind
        self.head = head
        self.at = at
    }

    public var hold: Hold {
        switch kind {
        case .find: return .folds
        case .approval, .ask, .stuck: return .pinned
        }
    }

    /// The word on the row's chip.
    public var word: String {
        switch kind {
        case .approval: return "Approval"
        case .ask: return "Ask"
        case .stuck: return "Stuck"
        case .find: return "Find"
        }
    }

    /// The tool, strand or kind the row came from, for the header after the time.
    public var source: String {
        switch kind {
        case .approval(let tool): return tool
        case .ask: return ""
        case .stuck(let strand): return strand
        case .find(let kind): return kind.rawValue
        }
    }
}

public enum LiftRule {
    /// The words a Retry sends a stuck strand. They are the web's own, fixed
    /// (`thread_send.retry_prompt`), so a strand is asked the same thing from either
    /// client, and nothing a person or a model wrote reaches them.
    public static let retryPrompt = "The last run of this strand failed. Please retry it."

    /// The roles that may press a row's buttons: the owner and an operator. An
    /// observer and any role this client does not know read the rail and press
    /// nothing, as on the web.
    public static func mayAct(role: String) -> Bool {
        role == "owner" || role == "operator"
    }

    /// The rows of one session, pinned first.
    ///
    /// - `approvals` are the lane's pending requests, which are live, and `raised`
    ///   is each one's raise time from `approval.read` by id. An approval with no
    ///   time draws none and sorts after those that have one.
    /// - `feed` is the session's row from `sessions.attention`, or nil when it was
    ///   not read, which lifts no ask, stuck strand or find.
    ///
    /// Order: approvals by raise time, then asks oldest first, then stuck strands
    /// oldest failure first, then finds newest first. Each ends in the identity, so
    /// the same input in any order gives the same rows. The web hands the host's
    /// own ranking through instead, and this order is this client's.
    public static func rows(
        approvals: [Escalation], raised: [String: Int] = [:], feed: AttentionRow?,
        clock: (Int) -> String = ClockTime.local
    ) -> [LiftedRow] {
        let pending = approvals
            .map { LiftedRow(id: "approval:\($0.id)", kind: .approval(tool: $0.tool), head: approvalHead($0), at: raised[$0.id]) }
            .sorted(by: oldestFirst)
        guard let feed else { return pending }

        let asks = feed.asks.items
            .map { LiftedRow(id: "ask:\($0.id)", kind: .ask, head: InboxRule.cut(oneLine($0.head)), at: $0.createdAt) }
            .sorted(by: oldestFirst)
        let stuck = feed.stuck.items
            .map { LiftedRow(id: "stuck:\($0.strand)", kind: .stuck(strand: $0.strand), head: stuckHead($0, clock: clock), at: $0.failedAt) }
            .sorted(by: oldestFirst)
        let finds = feed.finds.items
            .map { LiftedRow(id: "find:\($0.id)", kind: .find($0.kind), head: InboxRule.cut(oneLine($0.head)), at: $0.createdAt) }
            .sorted { lhs, rhs in
                guard let left = lhs.at, let right = rhs.at, left != right else { return lhs.id < rhs.id }
                return left > right
            }
        return pending + asks + stuck + finds
    }

    /// Longest wait first, a row with no time after every row with one.
    private static func oldestFirst(_ lhs: LiftedRow, _ rhs: LiftedRow) -> Bool {
        switch (lhs.at, rhs.at) {
        case (let left?, let right?) where left != right: return left < right
        case (.some, .none): return true
        case (.none, .some): return false
        default: return lhs.id < rhs.id
        }
    }

    /// What a pending approval asks to do and, when the record names it, the action.
    private static func approvalHead(_ approval: Escalation) -> String {
        let action = oneLine(approval.action.isEmpty ? approval.preview : approval.action)
        return InboxRule.cut(action.isEmpty ? approval.wants : approval.wants + " \u{00B7} " + action)
    }

    /// A stuck strand's line: what stopped it and when, then the provider's wait
    /// when it named one.
    static func stuckHead(_ stuck: AttentionStuck, clock: (Int) -> String) -> String {
        let head = InboxRule.stuckHead(stuck, clock: clock)
        guard let wait = stuck.retryAfterMs, wait > 0 else { return head }
        return head + " \u{00B7} provider asks for \(span(wait)) before a retry"
    }

    /// A wait in the fewest words: "30s", "5m", "1h 02m".
    static func span(_ ms: Int) -> String {
        if ms < 60_000 { return "\(max(1, ms / 1000))s" }
        return InboxRule.shortAge(ms)
    }

    /// The first line, so a multi-line quote does not push the rail's rows apart.
    private static func oneLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// The pinned rows, in the order given.
    public static func pinned(_ rows: [LiftedRow]) -> [LiftedRow] {
        rows.filter { $0.hold == .pinned }
    }

    /// The rows worth knowing, in the order given.
    public static func insights(_ rows: [LiftedRow]) -> [LiftedRow] {
        rows.filter { $0.hold == .folds }
    }

    /// The count line, "2 need you · 1 insight", each part left out when it is zero.
    public static func countWords(needing: Int, insights: Int) -> String {
        var parts: [String] = []
        if needing == 1 { parts.append("1 needs you") } else if needing > 1 { parts.append("\(needing) need you") }
        if insights == 1 { parts.append("1 insight") } else if insights > 1 { parts.append("\(insights) insights") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The words of an approval's card that come from `approval.read`. Every part that
/// the daemon left out is left out here: nothing is worded that the daemon could not
/// say exactly.
public enum ApprovalWords {
    /// A title that names the tool and the authority, or nil when the call wants
    /// neither a write grant nor a network grant and the card keeps its own
    /// sentence. A write grant is worded first, since it names the place the call may
    /// change. The command, path and tool are text a model's call carried.
    public static func title(_ item: ApprovalEvidenceItem) -> String? {
        let write = item.wanted.first { $0.kind == "writable_root" }
        let wantsNetwork = item.wanted.contains { $0.kind == "network" }
        if let write {
            if let command = item.preview, !command.isEmpty {
                return "May this program run \(firstLine(command)) with write access to \(write.detail)?"
            }
            return "May this program have write access to \(write.detail)?"
        }
        if wantsNetwork {
            return "May \(item.tool.isEmpty ? "this program" : item.tool) reach the network?"
        }
        return nil
    }

    /// "Network on" or "Network off", or nil when the daemon could not say.
    public static func networkLine(_ item: ApprovalEvidenceItem) -> String? {
        item.network.map { "Network \($0.rawValue)" }
    }

    /// "Policy today: workspace-write \u{00B7} network off", or nil when no policy was lent.
    public static func policyLine(_ item: ApprovalEvidenceItem) -> String? {
        item.policy.map { "Policy today: \($0.sandbox) \u{00B7} network \($0.network)" }
    }

    /// "waiting since 12:58 \u{00B7} 4m", or nil for a record that carries no raise time:
    /// an approval is never aged from anything else.
    public static func waitingLine(raisedAt: Int?, now: Int, clock: (Int) -> String = ClockTime.local) -> String? {
        guard let raisedAt else { return nil }
        return "waiting since \(clock(raisedAt)) \u{00B7} \(InboxRule.shortAge(max(0, now - raisedAt)))"
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
    }
}

/// The strip above the transcript: what the strand is doing, in a few words.
public enum StreamWords {
    /// `stopped for an approval since 12:58`, `running, turn 14m`, or `idle`. An
    /// approval outranks a running turn, since a strand that asked is not running.
    /// The raise time and the turn's start come from the daemon, and a missing one
    /// leaves its words out rather than invented.
    public static func state(
        pendingApprovals: Int, raisedAt: Int?, isBusy: Bool, turnStartedAt: Int?, now: Int,
        clock: (Int) -> String = ClockTime.local
    ) -> String {
        if pendingApprovals > 0 {
            return raisedAt.map { "stopped for an approval since \(clock($0))" } ?? "stopped for an approval"
        }
        guard isBusy else { return "idle" }
        return turnStartedAt.map { "running, turn \(ClockTime.turn(now - $0))" } ?? "running"
    }
}
