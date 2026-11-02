import Foundation

/// The `code_mode` programs a strand ran, in order, each with its state, a
/// bounded excerpt of its result and the capability calls it made.
///
/// A program is a `code_mode` tool call and its result. The call supplies the
/// label and the wall budget it asked for, and the result's `details` supply
/// the state, the value or reason and the call record (`protocol-change/060`).
/// A call with no result yet is running. The state is a closed type computed
/// from the result's `status` word, so a view chooses its style from the type
/// and never from model text.
public struct TraceBoard: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running, completed, errored, rejected, compileFailed, runFailed, failed

        public var word: String {
            switch self {
            case .running: return "running"
            case .completed: return "completed"
            case .errored: return "errored"
            case .rejected: return "rejected by vetting"
            case .compileFailed: return "compile failed"
            case .runFailed: return "run failed"
            case .failed: return "failed"
            }
        }

        public var isFailure: Bool {
            switch self {
            case .running, .completed: return false
            case .errored, .rejected, .compileFailed, .runFailed, .failed: return true
            }
        }
    }

    public struct Call: Sendable, Equatable, Identifiable {
        public let id: Int
        public let capability: String
        public let arguments: String?
        public let status: String
        public let error: String?
        public let durationMs: Int
    }

    public struct Program: Sendable, Equatable, Identifiable {
        public let id: Int
        public let state: State
        public let label: String
        public let excerpt: String?
        public let detail: String?
        public let withinMs: Int?
        public let calls: [Call]
        public let callSummary: String?

        /// The wall budget the program asked for, in words.
        public var budget: String {
            guard let withinMs else { return "default wall budget" }
            return withinMs >= 1000 && withinMs % 1000 == 0 ? "\(withinMs / 1000) s wall" : "\(withinMs) ms wall"
        }

        /// A rejected program never ran; the rest were vetted before they did.
        public var vetting: String {
            switch state {
            case .rejected: return "refused by vetting"
            case .running, .failed: return "not vetted yet"
            default: return "vetted"
            }
        }
    }

    public static let maxPrograms = 12
    public static let maxCharacters = 160

    public let programs: [Program]
    public let omitted: Int

    public init(programs: [Program], omitted: Int) {
        self.programs = programs
        self.omitted = omitted
    }

    /// Folds a chain of entries, oldest first, into the board.
    public static func fold(chain: [JSONValue]) -> TraceBoard {
        var calls: [(id: String, arguments: JSONValue)] = []
        var results: [String: JSONValue] = [:]
        for entry in chain {
            guard entry["type"]?.string == "message", let message = entry["message"] else { continue }
            switch message["role"]?.string {
            case "assistant":
                for block in message["content"]?.array ?? [] where block["type"]?.string == "toolCall" {
                    let call = block["toolCall"] ?? block
                    if call["name"]?.string == "code_mode", let id = call["id"]?.string {
                        calls.append((id, call["arguments"] ?? .null))
                    }
                }
            case "toolResult":
                if message["toolName"]?.string == "code_mode", let id = message["toolCallId"]?.string {
                    results[id] = message
                }
            default:
                break
            }
        }
        let all = calls.enumerated().map { index, call in program(call.arguments, results[call.id], position: index + 1) }
        return TraceBoard(programs: Array(all.suffix(maxPrograms)), omitted: max(0, all.count - maxPrograms))
    }

    private static func program(_ arguments: JSONValue, _ result: JSONValue?, position: Int) -> Program {
        let label = label(arguments, position: position)
        let within = arguments["within_ms"]?.int
        guard let result else {
            return Program(id: position, state: .running, label: label, excerpt: nil, detail: nil,
                           withinMs: within, calls: [], callSummary: nil)
        }
        let details = result["details"]
        let isError = result["isError"]?.bool ?? false
        let state: State
        switch details?["status"]?.string {
        case "completed": state = .completed
        case "errored", "program_failed": state = .errored
        case "vetting_rejected": state = .rejected
        case "compile_failed": state = .compileFailed
        case "run_failed": state = .runFailed
        default: state = isError ? .failed : .completed
        }
        let text = (result["content"]?.array ?? [])
            .compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: " ")
        let excerpt: String
        if state == .completed, let value = details?["value"] {
            excerpt = clip(value.compactText)
        } else if let message = details?["message"]?.string {
            excerpt = clip(message)
        } else {
            excerpt = clip(text)
        }
        var detail: String?
        if state == .compileFailed || state == .runFailed || state == .rejected {
            let reason = details?["detail"]?.string ?? ""
            detail = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? excerpt : PanelWords.clip(reason, 800)
        }
        let log = details?["calls"]
        let items: [Call] = (log?["items"]?.array ?? []).enumerated().compactMap { index, row in
            guard let capability = row["cap"]?.string else { return nil }
            return Call(
                id: index, capability: capability, arguments: row["args"]?.string,
                status: row["status"]?.string ?? "", error: row["error"]?.string,
                durationMs: row["duration_ms"]?.int ?? 0
            )
        }
        var summary: String?
        if let total = log?["total"]?.int {
            summary = "\(total) call\(total == 1 ? "" : "s") · \(log?["failed"]?.int ?? 0) failed"
        }
        return Program(id: position, state: state, label: label, excerpt: excerpt, detail: detail,
                       withinMs: within, calls: items, callSummary: summary)
    }

    /// The program's path, or the leading comment of its source, or its place.
    private static func label(_ arguments: JSONValue, position: Int) -> String {
        if let path = arguments["program_path"]?.string { return clip(path) }
        if let source = arguments["program"]?.string {
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("import ") { continue }
                if trimmed.hasPrefix("//") {
                    let text = trimmed.drop(while: { $0 == "/" }).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { return clip(text) }
                }
                break
            }
        }
        return "Program \(position)"
    }

    private static func clip(_ text: String) -> String {
        PanelWords.clip(PanelWords.oneLine(text), maxCharacters)
    }
}
