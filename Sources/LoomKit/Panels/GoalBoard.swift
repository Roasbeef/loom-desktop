import Foundation

/// The session's pinned goal, from the `goal` snapshot (protocol section 4.9.27).
///
/// A goal is read with `goal_get` and changed with `goal_set`, `goal_pause`,
/// `goal_resume`, `goal_check` and `goal_clear`, each of which answers with the
/// fresh board. `goal_changed` is only an invalidation, so a client that shows
/// the goal reads it again. The board carries the harness's own sentence for
/// why a stopped goal stopped (`because`), which is worded server-side so no
/// client has to word six cases.
public struct GoalBoard: Sendable, Equatable {
    public enum Status: String, Sendable {
        case none, active, paused
        case budgetLimited = "budget_limited"
        case complete
    }

    public struct Check: Sendable, Equatable {
        public let command: String
        public let status: Int?
        public let notFinished: String?
        public let output: String

        /// How the last run ended, in words. A run the harness stopped has no
        /// exit status, and a number invented for one would read as the
        /// command's own verdict on the work.
        public var result: String {
            if let status { return status == 0 ? "passed (exit status 0)" : "failed (exit status \(status))" }
            if let notFinished { return "no result — \(PanelWords.oneLine(notFinished))" }
            return "no result"
        }
    }

    public let status: Status
    /// The stop reason word when the daemon sent one this client does not know.
    public let unknownStatus: String?
    public let reason: String?
    public let because: String
    public let objective: String
    public let tokenBudget: Int
    public let tokensUsed: Int
    public let costUsed: Double
    public let evidence: UsageWords.Evidence
    public let continuations: Int
    public let createdMs: Int
    public let updatedMs: Int
    public let observedMs: Int
    public let reviewerNote: String?
    public let check: String?
    public let lastCheck: Check?

    /// Reads a goal board. A board whose status this client does not know is
    /// kept as unrecognized rather than refused, so a newer daemon's state is
    /// shown as the daemon spelled it.
    public init?(_ board: JSONValue?) {
        guard let board, let word = board["status"]?.string else { return nil }
        status = Status(rawValue: word) ?? .none
        unknownStatus = Status(rawValue: word) == nil ? word : nil
        reason = board["reason"]?.string
        because = board["because"]?.string ?? ""
        objective = board["objective"]?.string ?? ""
        tokenBudget = board["token_budget"]?.int ?? 0
        tokensUsed = board["tokens_used"]?.int ?? 0
        costUsed = board["cost_used"]?.double ?? 0
        evidence = UsageWords.Evidence(board["cost_evidence"])
        continuations = board["continuations"]?.int ?? 0
        createdMs = board["created_ms"]?.int ?? 0
        updatedMs = board["updated_ms"]?.int ?? 0
        observedMs = board["observed_at_ms"]?.int ?? 0
        reviewerNote = board["reviewer_note"]?.string
        check = board["check"]?.string
        lastCheck = board["last_check"].flatMap { run in
            guard run["command"]?.string != nil else { return nil }
            return Check(
                command: run["command"]?.string ?? "",
                status: run["status"]?.int,
                notFinished: run["not_finished"]?.string,
                output: run["output"]?.string ?? ""
            )
        }
    }

    public var isPinned: Bool { status != .none }

    /// Pause is offered only while the goal is running, and Resume while it is
    /// stopped by the operator, the harness or the budget. A complete goal is
    /// the reviewer's verdict, not a state to undo.
    public var canPause: Bool { status == .active }
    public var canResume: Bool { status == .paused || status == .budgetLimited }

    public var statusWord: String {
        switch status {
        case .active: return "active"
        case .paused: return "paused"
        case .budgetLimited: return "budget limited"
        case .complete: return "complete"
        case .none: return unknownStatus ?? "none"
        }
    }

    /// The short cause beside a stopped goal's status.
    public var causeWord: String? {
        switch (status, reason) {
        case (.paused, "operator"): return "you paused it"
        case (.paused, "aborted"): return "aborted"
        case (.paused, "zero_progress"): return "no progress"
        case (.paused, "reviewer_unresponsive"): return "reviewer silent"
        case (.budgetLimited, "token_budget"): return "token budget"
        case (.budgetLimited, "continuation_cap"): return "continuation cap"
        case (.paused, let word?), (.budgetLimited, let word?): return PanelWords.oneLine(word)
        default: return nil
        }
    }

    /// The row on the Session tab: `goal paused (you paused it) · 51200/400000 tokens · …`.
    public var row: String {
        let cause = causeWord.map { " (\($0))" } ?? ""
        return "goal \(statusWord)\(cause) · \(tokensUsed)/\(tokenBudget) tokens · "
            + "\(continuations) continuation\(continuations == 1 ? "" : "s") · "
            + PanelWords.clip(PanelWords.oneLine(objective), 72)
    }

    /// The spend line, with the cost worded as an estimate.
    public var spend: String {
        "\(PanelWords.count(tokensUsed)) of \(PanelWords.count(tokenBudget)) tokens · "
            + UsageWords.estimate(costUsed, evidence) + " · "
            + "\(continuations) continuation\(continuations == 1 ? "" : "s")"
    }

    /// How long ago the goal was pinned and last changed, on the daemon's clock.
    public var ages: String {
        "pinned \(PanelWords.age(milliseconds: observedMs - createdMs)) ago · "
            + "last change \(PanelWords.age(milliseconds: observedMs - updatedMs)) ago"
    }
}
