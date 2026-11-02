import Foundation

/// A strand's glance: the title and one-line summary the daemon keeps for it
/// in a `client/glance/<strand>` cell, and the context size it last reported.
public struct Glance: Sendable, Equatable {
    public static let keyPrefix = "client/glance/"

    public let operation: String
    public let title: String
    public let summary: String
    public let tokens: Int

    init?(_ value: JSONValue?) {
        guard let operation = value?["operation"]?.string,
              let title = value?["title"]?.string,
              let summary = value?["summary"]?.string else { return nil }
        self.operation = operation
        self.title = title
        self.summary = summary
        tokens = value?["tokens"]?.int ?? 0
    }
}

/// One strand as a strip draws it: a name, a state and one line saying what
/// it is doing, with the detail the strand's page shows beneath.
///
/// The line follows `session_view/strand_card.status_line`. A working strand
/// says what it is doing, a finished one says how long it ran, a failed one
/// says why, and a strand waiting on a person says so. Everything here is a
/// pure function of the cut, so a card can be tested from captured frames.
public struct StrandLine: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case working, needsApproval, finished, failed, halted, idle

        /// The word the state is announced by, and the group it sorts into.
        public var label: String {
            switch self {
            case .working: return "Working"
            case .needsApproval: return "Needs approval"
            case .finished: return "Finished"
            case .failed: return "Failed"
            case .halted: return "Halted"
            case .idle: return "Idle"
            }
        }

        /// A settled strand has ended its last run and is not waiting on anyone.
        public var isSettled: Bool {
            switch self {
            case .finished, .failed, .halted: return true
            case .working, .needsApproval, .idle: return false
            }
        }
    }

    /// One tool call from the strand's recent history.
    public struct Call: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let summary: String
        public let isRunning: Bool
        public let isError: Bool
    }

    public let id: String
    public let status: Status
    /// The activity text, as the card's one line.
    public let line: String
    public let task: String?
    public let model: String?
    public let contextTokens: Int?
    public let running: [String]
    public let recent: [Call]
    public let approvals: Int
    /// How the last run ended, in words, for a settled strand.
    public let ending: String?

    /// The strand's display name: `sub:^main/build-1a2b` reads as `build`.
    public var name: String {
        guard id.hasPrefix("sub:") else { return id }
        let last = id.split(separator: "/").last.map(String.init) ?? id
        if let dash = last.lastIndex(of: "-"), last.distance(from: dash, to: last.endIndex) <= 6 {
            return String(last[..<dash])
        }
        return last
    }

    /// The word a card puts under the name. `now` is the run's start, which this
    /// client observed, so a duration is never taken from a daemon clock.
    public func statusLine(elapsed: Int?) -> String {
        switch status {
        case .needsApproval:
            return "Needs approval"
        case .working:
            return line.isEmpty ? "Working" : "Working · \(line)"
        case .finished:
            return elapsed.map { "Finished " + PanelWords.duration(seconds: $0) } ?? "Finished"
        case .failed:
            return ending.map { "Failed · \($0)" } ?? "Failed"
        case .halted, .idle:
            return status.label
        }
    }

    /// Builds the line for a strand from what a cut holds.
    static func make(
        strand: Strand,
        glance: Glance?,
        rows: [TranscriptRow],
        approvals: Int,
        hasHeldInput: Bool
    ) -> StrandLine {
        let calls: [Call] = rows.compactMap { row in
            guard case .tool(let name, let arguments, let result, let isError) = row.kind else { return nil }
            return Call(
                id: row.callID ?? row.id,
                name: name,
                summary: PanelWords.clip(PanelWords.oneLine(callTarget(arguments)), 80),
                isRunning: result == nil,
                isError: isError
            )
        }
        let running = calls.filter(\.isRunning).map(\.name)
        let status: Status
        if approvals > 0 {
            status = .needsApproval
        } else if strand.isBusy {
            status = .working
        } else {
            switch strand.lastOutcome {
            case "completed": status = .finished
            case "failed": status = .failed
            case "aborted": status = .halted
            default: status = hasHeldInput ? .halted : .idle
            }
        }

        // What the strand is doing: the tool it has in flight, else the daemon's
        // own summary. A bare "tool" or "running" says nothing, so it is dropped.
        var line = ""
        if let first = running.first {
            line = first + (running.count > 1 ? " + \(running.count - 1) active" : "")
        } else if let summary = glance?.summary, !["", "tool", "running tools", "running"].contains(summary) {
            line = summary == "assistant" || summary == "streaming" ? "thinking" : summary
        } else if strand.isBusy {
            line = "thinking"
        }
        return StrandLine(
            id: strand.id,
            status: status,
            line: PanelWords.oneLine(line),
            task: glance.flatMap { Self.taskWords($0.title) },
            model: strand.model.map(PanelWords.modelName),
            contextTokens: (glance?.tokens).flatMap { $0 > 0 ? $0 : nil },
            running: running,
            recent: Array(calls.suffix(5).reversed()),
            approvals: approvals,
            ending: strand.lastError.map { PanelWords.clip(PanelWords.oneLine($0), 120) }
        )
    }

    /// A glance title is the task's first sentence, unless it is the advisor
    /// feed's header, which the engine wrote for the model and is no task.
    static func taskWords(_ title: String) -> String? {
        let line = PanelWords.oneLine(title)
        if line.isEmpty || line.hasPrefix("[advisor feed") { return nil }
        let sentence = line.range(of: ". ").map { String(line[..<$0.lowerBound]) + "." } ?? line
        return PanelWords.clip(sentence, 120)
    }

    private static func callTarget(_ arguments: JSONValue) -> String {
        for key in ["command", "path", "pattern", "query", "url", "op", "task", "name"] {
            if let value = arguments[key]?.string { return value }
        }
        return ""
    }
}
