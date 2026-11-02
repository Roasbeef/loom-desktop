import Foundation

/// What a person typed into the composer, decided without a socket.
///
/// The parse lives here, in a value that tests can exercise, so the composer view
/// only asks what a draft means and never interprets it. The vocabulary is the one
/// the terminal and web clients share (`session_view/command.gleam`), restricted to
/// what this app carries out. A command the app has no surface for is not parsed
/// as one, so it cannot be mistaken for work that was done.
public enum SlashCommand: Sendable, Equatable {
    /// Nothing but whitespace.
    case empty
    /// Ordinary text for the model.
    case prompt(String)
    /// `/model` alone: list the catalogue.
    case models
    case model(String)
    case effort(String)
    case profileShow
    /// `nil` is the configuration's default roles, which the person spells `default`.
    case profileSelect(String?)
    case compact
    case abort
    case steer(String)
    case queue(String)
    case fork(String)
    case goalStatus
    case goalSet(objective: String, budget: Int)
    /// `nil` clears the check.
    case goalCheck(String?)
    case goalClear
    case goalPause
    case goalResume
    case btw(BtwAction)
    case btwClose
    case schedules
    case unschedule(name: String, target: String?)
    case approvals(String?)
    case approve(String)
    case deny(String)
    case peek(String)
    case peekClose
    case clear
    /// A command that cannot be sent, with the sentence that says why. The words
    /// are worded here so the refusal names the number or the word that was wrong.
    case invalid(String)

    public enum BtwAction: Sendable, Equatable {
        case read, refresh, clear, cancel
        case ask(String)

        /// The `action` word the wire takes.
        public var wire: String {
            switch self {
            case .read: return "read"
            case .refresh: return "refresh"
            case .clear: return "clear"
            case .cancel: return "cancel"
            case .ask: return "ask"
            }
        }
    }

    /// The token budget a `/goal` without `--budget` pins. The wire requires a
    /// positive budget, so the app supplies this one and says so when it confirms.
    public static let defaultGoalBudget = 200_000
    /// The server's bounds, mirrored so a refusal names the count without a round trip.
    public static let objectiveLimit = 4000
    public static let checkLimit = 1000

    // MARK: Parsing

    public static func parse(_ draft: String) -> SlashCommand {
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .empty }
        guard input.hasPrefix("/") else { return .prompt(input) }

        // The name is the first run of non-space characters, and the argument
        // keeps its internal spacing, as it does in the other clients.
        let body = input.dropFirst()
        let name: String
        let rest: String
        if let space = body.firstIndex(where: \.isWhitespace) {
            name = String(body[..<space])
            rest = body[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = String(body)
            rest = ""
        }

        func required(_ build: (String) -> SlashCommand) -> SlashCommand {
            rest.isEmpty ? .invalid("/\(name) needs an argument.") : build(rest)
        }

        switch name {
        case "model": return rest.isEmpty ? .models : .model(rest)
        case "models": return .models
        case "effort": return required { .effort($0) }
        case "profile", "model-profile": return profile(rest)
        case "compact": return .compact
        case "abort": return .abort
        case "steer": return required { .steer($0) }
        case "queue": return required { .queue($0) }
        case "fork": return required { .fork($0) }
        case "goal": return goal(rest)
        case "btw": return btw(rest)
        case "schedules": return .schedules
        case "unschedule": return unschedule(rest)
        case "approvals": return .approvals(rest.isEmpty ? nil : rest)
        case "approve": return required { .approve($0) }
        case "deny": return required { .deny($0) }
        case "peek": return rest == "close" ? .peekClose : required { .peek($0) }
        case "clear": return .clear
        default: return .invalid("Unknown command /\(name).")
        }
    }

    private static func profile(_ rest: String) -> SlashCommand {
        switch rest {
        case "": return .profileShow
        case "default": return .profileSelect(nil)
        default: return .profileSelect(rest)
        }
    }

    private static func btw(_ rest: String) -> SlashCommand {
        switch rest {
        case "": return .btw(.read)
        case "refresh": return .btw(.refresh)
        case "clear": return .btw(.clear)
        case "cancel": return .btw(.cancel)
        case "close": return .btwClose
        default: return .btw(.ask(rest))
        }
    }

    private static func unschedule(_ rest: String) -> SlashCommand {
        let words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        switch words.count {
        case 0: return .invalid("/unschedule needs an argument.")
        case 1: return .unschedule(name: words[0], target: nil)
        default: return .unschedule(name: words[0], target: words[1])
        }
    }

    /// `/goal [--budget N] <objective>`, or one of four subcommands. The
    /// subcommands are subcommands only as the whole argument, since the
    /// objective is free text and `/goal clear the failing test` is work to do.
    private static func goal(_ rest: String) -> SlashCommand {
        switch rest {
        case "": return .goalStatus
        case "clear": return .goalClear
        case "pause": return .goalPause
        case "resume": return .goalResume
        case "check": return .goalCheck(nil)
        case "--budget": return .invalid("/goal --budget needs a number and an objective.")
        default: break
        }
        if rest.hasPrefix("check ") {
            let command = rest.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if command.isEmpty { return .goalCheck(nil) }
            if command.count > checkLimit {
                return .invalid("The check is \(command.count) characters, and the limit is \(checkLimit).")
            }
            return .goalCheck(command)
        }
        if rest.hasPrefix("--budget ") || rest.hasPrefix("--budget=") {
            return budgeted(String(rest.dropFirst(9)).trimmingCharacters(in: .whitespaces))
        }
        return pinning(rest, budget: defaultGoalBudget)
    }

    private static func budgeted(_ rest: String) -> SlashCommand {
        let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        guard let word = parts.first else { return .invalid("/goal --budget needs a number and an objective.") }
        guard let budget = Int(word.replacingOccurrences(of: "_", with: "")), budget > 0 else {
            return .invalid("\(word) is not a positive token count.")
        }
        guard parts.count == 2 else { return .invalid("/goal --budget needs an objective after the number.") }
        return pinning(parts[1].trimmingCharacters(in: .whitespaces), budget: budget)
    }

    private static func pinning(_ objective: String, budget: Int) -> SlashCommand {
        objective.count > objectiveLimit
            ? .invalid("The objective is \(objective.count) characters, and the limit is \(objectiveLimit).")
            : .goalSet(objective: objective, budget: budget)
    }

    // MARK: Completion

    /// One row of the list shown while a command is being typed.
    public struct Suggestion: Sendable, Equatable, Identifiable {
        public let command: String
        public let summary: String
        /// Whether choosing the row leaves the line open for an argument.
        public let takesArgument: Bool

        public var id: String { command }

        /// The text a chosen row puts in the editor.
        public var insertion: String { takesArgument ? command + " " : command }
    }

    /// What the daemon has said it can complete: model and profile names.
    public struct Catalogue: Sendable, Equatable {
        public var models: [String]
        public var profiles: [String]

        public init(models: [String] = [], profiles: [String] = []) {
            self.models = models
            self.profiles = profiles
        }
    }

    public static let effortLevels: [(String, String)] = [
        ("off", "no reasoning requested"),
        ("minimal", "the smallest budget the model offers"),
        ("low", "a small reasoning budget"),
        ("medium", "a medium reasoning budget"),
        ("high", "a large reasoning budget"),
        ("xhigh", "beyond high where the model offers it"),
        ("max", "the largest budget the model offers"),
    ]

    private static let goalWords: [(String, String, Bool)] = [
        ("check", "run a command before each review", true),
        ("clear", "unpin the session goal", false),
        ("pause", "hold the goal without unpinning it", false),
        ("resume", "continue a held or tripped goal", false),
        ("--budget", "set the token budget: /goal --budget 200000 <objective>", true),
    ]

    private static let commands: [(String, String, Bool)] = [
        ("/model", "choose a model", true),
        ("/effort", "set the reasoning level", true),
        ("/profile", "show or switch the model profile", true),
        ("/compact", "compact this conversation", false),
        ("/queue", "run after the current turn", true),
        ("/steer", "redirect the current turn", true),
        ("/fork", "fork this conversation into a new strand", true),
        ("/goal", "show or pin a session goal", true),
        ("/btw", "ask a side question while work continues", true),
        ("/schedules", "list this session's schedules", false),
        ("/unschedule", "retire a schedule", true),
        ("/approvals", "show decided approvals", false),
        ("/approve", "allow a pending request by id", true),
        ("/deny", "deny a pending request by id", true),
        ("/peek", "read a subagent's transcript on another machine", true),
        ("/abort", "stop the current run", false),
        ("/clear", "clear this window's transcript", false),
    ]

    /// The rows for a draft, or none when it is not a command being typed.
    ///
    /// A command word completes by prefix. Once a space follows a command with a
    /// closed vocabulary, the rows become that vocabulary: levels, goal words,
    /// models and profiles. A command with free text offers nothing past its space.
    public static func suggestions(for draft: String, catalogue: Catalogue = Catalogue()) -> [Suggestion] {
        // Only leading space is dropped, because a trailing space is what opens
        // the argument rows.
        let input = String(draft.drop(while: \.isWhitespace))
        guard input.hasPrefix("/"), !input.contains("\n") else { return [] }

        func rows(_ command: String, _ partial: String, _ words: [(String, String, Bool)]) -> [Suggestion] {
            words
                .filter { $0.0.hasPrefix(partial) }
                .map { Suggestion(command: "\(command) \($0.0)", summary: $0.1, takesArgument: $0.2) }
        }

        if let space = input.firstIndex(of: " ") {
            let command = String(input[..<space])
            let partial = input[space...].trimmingCharacters(in: .whitespaces)
            switch command {
            case "/effort":
                return rows(command, partial, effortLevels.map { ($0.0, $0.1, false) })
            case "/goal":
                return rows(command, partial, goalWords)
            case "/model":
                return rows(command, partial, catalogue.models.map { ($0, "catalogue model", false) })
            case "/profile", "/model-profile":
                let names = ["default"] + catalogue.profiles
                return rows(command, partial, names.map { ($0, $0 == "default" ? "the configuration's default roles" : "profile", false) })
            default:
                return []
            }
        }
        return commands
            .filter { $0.0.hasPrefix(input) }
            .map { Suggestion(command: $0.0, summary: $0.1, takesArgument: $0.2) }
    }

    /// Moves a selection through `count` rows, wrapping at either edge.
    public static func move(_ selected: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((selected + step) % count + count) % count
    }
}
