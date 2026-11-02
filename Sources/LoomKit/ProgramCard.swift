import Foundation

/// A `code_mode` program as one card: what it did in a sentence, the calls it
/// made on a time axis, the program, and its result or its error.
///
/// Everything is read from the call's arguments (`program`, `within_ms`) and from
/// the result's `details`: its `status`, and the call record the host writes
/// (`calls`, itemised with each call's capability, status and timing). The record
/// names no file and no host, so the card names none. While the program runs, the
/// host has written no record, and a running card holds the program alone.
public struct ProgramCard: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running, completed, compileFailed, rejected, runFailed, programFailed
    }

    public struct Call: Sendable, Equatable, Identifiable {
        public let id: Int
        public let capability: String
        public let count: Int
        public let failed: Bool
        /// Where the run starts and how long it lasts, as whole percentages of the
        /// program's span, so a view draws a bar with two numbers.
        public let offset: Int
        public let width: Int
    }

    public let state: State
    public let statusWord: String
    /// The one sentence a scan of the transcript reads.
    public let outcome: String
    /// `7 calls · 1 failed`, when the result carries a call record.
    public let countWords: String?
    public let elapsedMs: Int?
    public let lines: Int
    public let program: String
    public let calls: [Call]
    /// The error when the program did not complete, or its value when it did.
    public let failure: String?
    public let value: String?

    /// Reads a program call and the result joined to it.
    public static func read(arguments: JSONValue, result: String?, isError: Bool, details: JSONValue?) -> ProgramCard {
        let program = arguments["program"]?.string ?? ""
        let lines = program.isEmpty ? 0 : program.split(separator: "\n", omittingEmptySubsequences: false).count
        guard let result else {
            return ProgramCard(
                state: .running, statusWord: "running", outcome: "Running a program", countWords: nil,
                elapsedMs: nil, lines: lines, program: program, calls: [], failure: nil, value: nil
            )
        }
        let log = details?["calls"]
        let items = (log?["items"]?.array ?? [])
        let elapsed = log?["elapsed_ms"]?.int
        let span = max(elapsed ?? 0, items.compactMap { ($0["start_ms"]?.int ?? 0) + ($0["duration_ms"]?.int ?? 0) }.max() ?? 0, 1)
        let table = Self.table(items, span: span)
        let status = details?["status"]?.string ?? ""
        let failed = log?["failed"]?.int ?? 0
        let total = log?["total"]?.int
        let count = total.map { "\($0) call\($0 == 1 ? "" : "s")" + (failed > 0 ? " · \(failed) failed" : "") }

        if isError || ["compile_failed", "vetting_rejected", "program_failed", "run_failed"].contains(status) {
            let state: State
            let word: String
            switch status {
            case "compile_failed": (state, word) = (.compileFailed, "compile error")
            case "vetting_rejected": (state, word) = (.rejected, "refused by vetting")
            case "program_failed": (state, word) = (.programFailed, "program failed")
            default: (state, word) = (.runFailed, "stopped")
            }
            let said = details?["detail"]?.string ?? details?["message"]?.string ?? result
            let outcome: String
            switch state {
            case .compileFailed: outcome = "The program did not compile"
            case .rejected: outcome = "The program was refused before it ran"
            default: outcome = items.isEmpty ? "The program did not finish" : "\(sentence(table)); the program did not finish"
            }
            return ProgramCard(
                state: state, statusWord: word, outcome: outcome, countWords: count, elapsedMs: elapsed,
                lines: lines, program: program, calls: table, failure: said, value: nil
            )
        }
        return ProgramCard(
            state: .completed, statusWord: status.isEmpty ? "completed" : status,
            outcome: items.isEmpty ? "Ran a program" : sentence(table), countWords: count, elapsedMs: elapsed,
            lines: lines, program: program, calls: table, failure: nil, value: result
        )
    }

    // MARK: The call table

    /// The closed table that sorts a capability into what it does to the world. A
    /// capability not listed is counted as an other call, never guessed at.
    static func family(_ capability: String) -> String {
        switch capability {
        case _ where capability.hasPrefix("fs.read"), "fs.list", "fs.stat": return "read"
        case _ where capability.hasPrefix("fs.write"), _ where capability.hasPrefix("fs.edit"): return "write"
        case _ where capability.hasPrefix("net"), _ where capability.hasPrefix("http"): return "network"
        case _ where capability.hasPrefix("bash"), _ where capability.hasPrefix("proc"), _ where capability.hasPrefix("git"): return "run"
        case _ where capability.hasPrefix("grep"), _ where capability.hasPrefix("search"), _ where capability.hasPrefix("lsp"): return "search"
        default: return "other"
        }
    }

    private static func table(_ items: [JSONValue], span: Int) -> [Call] {
        var rows: [Call] = []
        var index = 0
        var runs: [(cap: String, count: Int, failed: Bool, start: Int, end: Int)] = []
        for item in items {
            let cap = item["cap"]?.string ?? "?"
            let failed = item["status"]?.string != "ok"
            let start = item["start_ms"]?.int ?? 0
            let end = start + (item["duration_ms"]?.int ?? 0)
            if let last = runs.last, last.cap == cap, last.failed == failed {
                runs[runs.count - 1] = (cap, last.count + 1, failed, last.start, max(last.end, end))
            } else {
                runs.append((cap, 1, failed, start, end))
            }
        }
        for run in runs {
            let offset = min(99, run.start * 100 / span)
            let width = max(1, min(100 - offset, (run.end - run.start) * 100 / span))
            rows.append(Call(id: index, capability: run.cap, count: run.count, failed: run.failed, offset: offset, width: width))
            index += 1
        }
        return rows
    }

    private static func sentence(_ calls: [Call]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for call in calls {
            let kind = family(call.capability)
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += call.count
        }
        func noun(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        let parts = order.map { kind -> String in
            let n = counts[kind] ?? 0
            switch kind {
            case "read": return "read " + noun(n, "file", "files")
            case "write": return "wrote " + noun(n, "file", "files")
            case "network": return "made " + noun(n, "request", "requests")
            case "run": return "ran " + noun(n, "command", "commands")
            case "search": return "searched " + noun(n, "time", "times")
            default: return "made " + noun(n, "other call", "other calls")
            }
        }
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}
