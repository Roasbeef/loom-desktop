import Foundation

/// The words a step is drawn with: a verb, what it acted on, and what it changed.
///
/// The figures come from the call's own arguments, so a running step already has
/// them, and a step never claims more than its arguments say.
public struct StepWords: Sendable, Equatable {
    public let verb: String
    public let subject: String
    /// Lines added and removed, for a step that changes a file.
    public let added: Int?
    public let removed: Int?
    /// The file a step changes, which a fold counts.
    public let file: String?

    /// Builds the words for one tool call. `isRunning` chooses the tense, because
    /// a step still going must not say it has finished.
    public static func of(name: String, arguments: JSONValue, isRunning: Bool) -> StepWords {
        func word(_ past: String, _ present: String) -> String { isRunning ? present : past }
        func first(_ keys: [String]) -> String {
            for key in keys {
                if let value = arguments[key]?.string, !value.isEmpty {
                    return value.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? value
                }
            }
            return ""
        }
        switch name {
        case "bash":
            return StepWords(verb: word("Ran", "Running"), subject: first(["command"]), added: nil, removed: nil, file: nil)
        case "fs_read":
            return StepWords(verb: word("Read", "Reading"), subject: first(["path"]), added: nil, removed: nil, file: nil)
        case "fs_write":
            let path = first(["path"])
            let lines = lineCount(arguments["content"]?.string ?? "")
            return StepWords(verb: word("Wrote", "Writing"), subject: path, added: lines, removed: nil, file: path)
        case "fs_edit":
            let path = first(["path"])
            let change: (added: Int, removed: Int)
            if let hunks = arguments["hunks"]?.array {
                change = hunkChange(hunks)
            } else {
                let old = arguments["old"]?.string ?? arguments["old_string"]?.string ?? ""
                let new = arguments["new"]?.string ?? arguments["new_string"]?.string ?? ""
                change = lineChange(old: old, new: new)
            }
            return StepWords(verb: word("Edited", "Editing"), subject: path, added: change.added, removed: change.removed, file: path)
        case "grep":
            return StepWords(verb: word("Searched", "Searching"), subject: first(["pattern", "query"]), added: nil, removed: nil, file: nil)
        case "history_search":
            return StepWords(verb: word("Searched history", "Searching history"), subject: first(["query"]), added: nil, removed: nil, file: nil)
        case "code_mode":
            return StepWords(verb: word("Ran a program", "Running a program"), subject: first(["program"]), added: nil, removed: nil, file: nil)
        case "agent_wait":
            return StepWords(verb: word("Waited for agents", "Waiting for agents"), subject: "", added: nil, removed: nil, file: nil)
        case "agent_spawn":
            return StepWords(verb: word("Started an agent", "Starting an agent"), subject: first(["purpose"]), added: nil, removed: nil, file: nil)
        default:
            return StepWords(verb: word("Used", "Using"), subject: name, added: nil, removed: nil, file: nil)
        }
    }

    /// A failed step in a sentence, then the raw result is for the rows below it.
    public static func failure(name: String, arguments: JSONValue, result: String?) -> String {
        let words = of(name: name, arguments: arguments, isRunning: false)
        let what = words.subject.isEmpty ? words.verb.lowercased() : "\(words.verb.lowercased()) \(words.subject)"
        let reason = (result ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let clipped = reason.count > 140 ? String(reason.prefix(140)) + "…" : reason
        return clipped.isEmpty ? "Did not complete: \(what)." : "Did not complete: \(what). \(clipped)"
    }

    static func lineCount(_ text: String) -> Int {
        // A final newline ends the last line and does not start another.
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return body.isEmpty ? 0 : body.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// The lines an `fs_edit` call adds and removes, read from its anchored hunks:
    /// a replace or delete removes the lines from its first anchor to its last, and
    /// every operation but a delete adds the lines it carries.
    static func hunkChange(_ hunks: [JSONValue]) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for hunk in hunks {
            let op = hunk["op"]?.string ?? ""
            added += op == "delete" ? 0 : (hunk["lines"]?.array?.count ?? 0)
            if op == "replace" || op == "delete" {
                let from = hunk["from"]?["line"]?.int ?? 0
                let to = hunk["to"]?["line"]?.int ?? from
                removed += max(1, to - from + 1)
            }
        }
        return (added, removed)
    }

    static func lineChange(old: String, new: String) -> (added: Int, removed: Int) {
        let before = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let after = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let difference = after.difference(from: before)
        var added = 0
        var removed = 0
        for change in difference {
            switch change {
            case .insert: added += 1
            case .remove: removed += 1
            }
        }
        return (added, removed)
    }

    /// The text of a duration in the words a person uses: `48s`, `3m 12s`.
    public static func duration(ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        if seconds < 1 { return "under 1s" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// One turn's work, folded behind a single line.
///
/// The fold holds what the strand did between a person's message and its answer:
/// reasoning, tool calls and the prose it wrote on the way. Its figures are read
/// from the records alone, so the line never states a duration the daemon did not
/// timestamp.
public struct Fold: Sendable, Equatable, Identifiable {
    public let id: String
    public let rows: [TranscriptRow]
    /// The turn's input and its last step, in milliseconds, when both are recorded.
    public let startedAt: Int?
    public let endedAt: Int?
    /// The turn is still running, so the fold stays open for the reader.
    public let isLive: Bool

    public var steps: Int { rows.filter { if case .tool = $0.kind { return true }; if case .spawned = $0.kind { return true }; return false }.count }

    public var failed: Int {
        rows.filter { if case .tool(_, _, _, let isError) = $0.kind { return isError }; return false }.count
    }

    /// The distinct files the steps changed.
    public var files: Int { Set(rows.compactMap(stepWords).compactMap(\.file)).count }

    public var added: Int { rows.compactMap(stepWords).reduce(0) { $0 + ($1.added ?? 0) } }
    public var removed: Int { rows.compactMap(stepWords).reduce(0) { $0 + ($1.removed ?? 0) } }

    private func stepWords(_ row: TranscriptRow) -> StepWords? {
        guard case .tool(let name, let arguments, _, let isError) = row.kind, !isError else { return nil }
        return StepWords.of(name: name, arguments: arguments, isRunning: false)
    }

    /// Whether a step is still without a result.
    public var isRunning: Bool { ToolSummary.status(rows) == .running }

    /// `Worked 48s · 4 steps · 2 files`, leaving out a figure the records did not give.
    public var title: String {
        var parts: [String] = []
        if let startedAt, let endedAt, endedAt > startedAt {
            parts.append(StepWords.duration(ms: endedAt - startedAt))
        }
        let steps = steps
        if steps > 0 { parts.append("\(steps) step\(steps == 1 ? "" : "s")") }
        let files = files
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        let failed = failed
        if failed > 0 { parts.append("\(failed) failed") }
        let head = isLive ? "Working" : "Worked"
        return parts.isEmpty ? head : "\(head) \(parts.joined(separator: " · "))"
    }

    /// The summed change across every step, `+12 −3`, or nil when no step changed a file.
    public var changeText: String? {
        let added = added
        let removed = removed
        guard added > 0 || removed > 0 else { return nil }
        return "+\(added) −\(removed)"
    }
}

/// A unit of the drawn transcript: one row, or a turn's work folded.
public enum TranscriptBlock: Sendable, Equatable, Identifiable {
    case row(TranscriptRow)
    case fold(Fold)

    public var id: String {
        switch self {
        case .row(let row): return row.id
        case .fold(let fold): return fold.id
        }
    }

    /// Cuts a strand's rows into turns and folds each turn's work.
    ///
    /// A turn starts at a person's message. Inside it, the last prose the strand
    /// wrote is the answer and stays outside the fold, along with anything the
    /// reader must not miss: a notice, a failure, a started agent or a report. The
    /// fold sits where the first folded row stood. A turn with nothing to fold
    /// draws as it was, and `running` keeps the last turn's fold open.
    public static func group(_ rows: [TranscriptRow], running: Bool = false) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var turn: [TranscriptRow] = []
        var inputAt: Int?

        func flush(isLast: Bool) {
            blocks.append(contentsOf: fold(turn, inputAt: inputAt, isLive: isLast && running))
            turn = []
        }
        for row in rows {
            if case .user = row.kind {
                flush(isLast: false)
                inputAt = row.at
                blocks.append(.row(row))
            } else {
                turn.append(row)
            }
        }
        flush(isLast: true)
        return blocks
    }

    private static func isWork(_ row: TranscriptRow) -> Bool {
        switch row.kind {
        case .thinking, .tool: return true
        default: return false
        }
    }

    private static func fold(_ rows: [TranscriptRow], inputAt: Int?, isLive: Bool) -> [TranscriptBlock] {
        guard !rows.isEmpty else { return [] }

        // The answer is the last prose with no work after it. Prose followed by a
        // step is narration, and it belongs to the fold.
        var answer: Int?
        if let last = rows.lastIndex(where: { if case .assistant = $0.kind { return true }; return false }),
           !rows[(last + 1)...].contains(where: isWork) {
            answer = last
        }
        func folded(_ index: Int) -> Bool {
            if index == answer { return false }
            switch rows[index].kind {
            case .thinking, .tool: return true
            case .assistant: return true
            default: return false
            }
        }
        let inside = rows.indices.filter(folded)
        guard inside.contains(where: { isWork(rows[$0]) }) else { return rows.map { .row($0) } }

        var blocks: [TranscriptBlock] = []
        var placed = false
        let members = inside.map { rows[$0] }
        let ended = members.compactMap { $0.settledAt ?? $0.at }.max()
                let fold = Fold(
            id: "fold/\(members.first?.id ?? "")",
            rows: members,
            startedAt: inputAt,
            endedAt: ended,
            isLive: isLive || members.contains { if case .tool(_, _, nil, _) = $0.kind { return true }; return false }
        )
        for index in rows.indices {
            if folded(index) {
                if !placed {
                    blocks.append(.fold(fold))
                    placed = true
                }
            } else {
                blocks.append(.row(rows[index]))
            }
        }
        return blocks
    }
}
