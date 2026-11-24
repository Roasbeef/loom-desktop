import Foundation

// Project mode as the daemon serves it (loom protocol-change/106 and its
// addenda; docs/client-protocol.md section 3.32). Three reads carry it:
// `projects.list` (each project with its counts by stage), `projects.board` (a
// page of one project's tickets, plus the router's queued replies and the
// messages it declined to route) and `projects.ticket` (one ticket with its
// assignments and the messages on its opening thread). The commands live in
// `ControlClient+Projects.swift`; this file is the typed values and the decoders.
//
// Three rules from the protocol govern every decoder here.
//
// - A stage is the daemon's spelling and is never derived. A stage this client
//   does not know is kept as text and drawn as text, and it needs a person when
//   it is spelled `person/...`, because that prefix is the protocol's own marker.
//   `person/check` is a known stage and is drawn with its raw word, which is the
//   owner's open question 6.
// - An absent field is unknown and is never zero. A ticket with no `opened_ms`
//   has no age, and a ticket with no title is drawn as untitled.
// - Every string is external text: a title, a question, a check's output and an
//   input can come from a message anyone could write. Each one is passed through
//   `ProjectText.safe` once, so a terminal escape or a control character cannot
//   reach a screen, and the view draws the result with `Text(verbatim:)`.
//
// The decoders are total. A ticket with no usable `id` is counted in
// `ProjectPage.unreadable` and left out, because keeping it would offer a command
// that names nothing.

/// Makes external text safe to draw: control characters other than a newline or a
/// tab are removed, and the text is cut to a bound.
public enum ProjectText {
    /// Removes what could move a cursor or rewrite a line when text is drawn, and
    /// cuts the rest to `limit` characters.
    public static func safe(_ text: String, limit: Int = 4000) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            return !(scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format)
        }
        let cleaned = String(String.UnicodeScalarView(kept))
        return cleaned.count > limit ? String(cleaned.prefix(limit - 1)) + "\u{2026}" : cleaned
    }
}

/// A ticket's stage, in the daemon's own spelling.
public enum ProjectStage: Sendable, Equatable, Hashable {
    case personDelivery, personAnswer, personReview, personBlocked, personFailed, personCheck
    case queued, idle, working
    case ended(String)
    case unknown(String)

    public init(word: String) {
        switch word {
        case "person/delivery": self = .personDelivery
        case "person/answer": self = .personAnswer
        case "person/review": self = .personReview
        case "person/blocked": self = .personBlocked
        case "person/failed": self = .personFailed
        case "person/check": self = .personCheck
        case "queued": self = .queued
        case "idle": self = .idle
        case "working": self = .working
        default:
            if word.hasPrefix("ended/") { self = .ended(String(word.dropFirst("ended/".count))) }
            else { self = .unknown(ProjectText.safe(word, limit: 64)) }
        }
    }

    /// The daemon's word, which is what a heading draws.
    public var word: String {
        switch self {
        case .personDelivery: return "person/delivery"
        case .personAnswer: return "person/answer"
        case .personReview: return "person/review"
        case .personBlocked: return "person/blocked"
        case .personFailed: return "person/failed"
        case .personCheck: return "person/check"
        case .queued: return "queued"
        case .idle: return "idle"
        case .working: return "working"
        case .ended(let outcome): return "ended/\(outcome)"
        case .unknown(let word): return word
        }
    }

    /// Whether the stage waits on a person: every `person/` word, known or not.
    public var needsPerson: Bool { word.hasPrefix("person/") }

    /// How urgent a stage is on the board, lowest first, in the web view's order:
    /// delivery, answer, review, check, blocked, failed, then the stages that need
    /// nobody.
    public var urgency: Int {
        switch self {
        case .personDelivery: return 0
        case .personAnswer: return 1
        case .personReview: return 2
        case .personCheck: return 3
        case .personBlocked: return 4
        case .personFailed: return 5
        case .unknown(let word) where word.hasPrefix("person/"): return 6
        case .working: return 7
        case .queued: return 8
        case .idle: return 9
        case .unknown: return 10
        case .ended: return 11
        }
    }
}

/// Something the daemon says a person can do with a ticket now. A client shows a
/// control for each word listed and derives none from the stage.
public enum ProjectAction: Sendable, Equatable, Hashable {
    case answer, close, retry, recheck, publish, stop
    case unknown(String)

    public init(word: String) {
        switch word {
        case "answer": self = .answer
        case "close": self = .close
        case "retry": self = .retry
        case "recheck": self = .recheck
        case "publish": self = .publish
        case "stop": self = .stop
        default: self = .unknown(ProjectText.safe(word, limit: 64))
        }
    }
}

/// What the check made of the ticket's head.
public enum ProjectCheckOutcome: Sendable, Equatable {
    case passed, failed, overridden, unfinished, waiting
    case unknown(String)

    init(word: String) {
        switch word {
        case "passed": self = .passed
        case "failed": self = .failed
        case "overridden": self = .overridden
        case "unfinished": self = .unfinished
        case "waiting": self = .waiting
        default: self = .unknown(ProjectText.safe(word, limit: 64))
        }
    }
}

/// The host's check of a ticket's latest commit. `output` is what a process
/// printed while running the worker's code, so it is external text.
public struct ProjectCheck: Sendable, Equatable {
    public let commit: String
    public let outcome: ProjectCheckOutcome
    public let atMs: Int?
    public let command: String?
    public let output: String?
    /// `test` or `environment` for a failure.
    public let cause: String?
    /// `worker` when the worker was sent back, `person` when nobody was.
    public let handling: String?
    public let note: String?

    init?(_ value: JSONValue?) {
        guard let value, let outcome = value["outcome"]?.string else { return nil }
        commit = ProjectText.safe(value["commit"]?.string ?? "", limit: 64)
        self.outcome = ProjectCheckOutcome(word: outcome)
        atMs = value["at_ms"]?.natural
        command = value["command"]?.string.map { ProjectText.safe($0, limit: 400) }
        output = value["output"]?.string.map { ProjectText.safe($0) }
        cause = value["cause"]?.string.map { ProjectText.safe($0, limit: 32) }
        handling = value["handling"]?.string.map { ProjectText.safe($0, limit: 32) }
        note = value["note"]?.string.map { ProjectText.safe($0, limit: 600) }
    }
}

/// A worker's open question. An answer echoes `seq`.
public struct ProjectQuestion: Sendable, Equatable {
    public let seq: Int
    public let text: String
    public let options: [String]

    init?(_ value: JSONValue?) {
        guard let value, let seq = value["seq"]?.natural, let text = value["text"]?.string else { return nil }
        self.seq = seq
        self.text = ProjectText.safe(text)
        options = (value["options"]?.array ?? []).compactMap { $0.string.map { ProjectText.safe($0, limit: 400) } }
    }
}

/// Why a ticket was allowed to exist.
public struct ProjectMandate: Sendable, Equatable {
    public let strength: String
    public let via: String
    public let source: String
    public let actor: String

    init?(_ value: JSONValue?) {
        guard let value, value.members != nil else { return nil }
        strength = ProjectText.safe(value["strength"]?.string ?? "", limit: 32)
        via = ProjectText.safe(value["via"]?.string ?? "", limit: 32)
        source = ProjectText.safe(value["source"]?.string ?? "", limit: 64)
        actor = ProjectText.safe(value["actor"]?.string ?? "", limit: 128)
    }
}

/// One ticket as the board and the detail both carry it.
public struct ProjectTicket: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let stage: ProjectStage
    /// The worker's session id, once one is bound.
    public let session: String?
    public let mandate: ProjectMandate?
    public let openedMs: Int?
    public let question: ProjectQuestion?
    public let pullRequest: String?
    public let failure: String?
    public let review: String?
    public let actions: [ProjectAction]
    public let check: ProjectCheck?

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, !id.isEmpty, id.count <= 128 else { return nil }
        self.id = id
        let title = value["title"]?.string.map { ProjectText.safe($0, limit: 200) }
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : title
        stage = ProjectStage(word: value["stage"]?.string ?? "")
        session = value["session"]?.string
        mandate = ProjectMandate(value["mandate"])
        openedMs = value["opened_ms"]?.natural
        question = ProjectQuestion(value["question"])
        pullRequest = value["pull_request"]?.string.map { ProjectText.safe($0, limit: 400) }
        failure = value["failure"]?.string.map { ProjectText.safe($0, limit: 600) }
        review = value["review"]?.string.map { ProjectText.safe($0, limit: 600) }
        actions = (value["actions"]?.array ?? []).compactMap { $0.string.map(ProjectAction.init(word:)) }
        check = ProjectCheck(value["check"])
    }

    /// Whether the daemon lists `action` for this ticket now.
    public func offers(_ action: ProjectAction) -> Bool { actions.contains(action) }
}

/// A message the router was offered three times and decided nothing about.
public struct ProjectUnrouted: Sendable, Equatable, Identifiable {
    public let trigger: String
    public let source: String
    public let actor: String
    public let text: String
    /// The reason the daemon recorded, as it spelled it.
    public let reason: String
    public let atMs: Int?
    public var id: String { trigger }

    init?(_ value: JSONValue) {
        guard let trigger = value["trigger"]?.string, !trigger.isEmpty else { return nil }
        self.trigger = trigger
        source = ProjectText.safe(value["source"]?.string ?? "", limit: 64)
        actor = ProjectText.safe(value["actor"]?.string ?? "", limit: 128)
        text = ProjectText.safe(value["text"]?.string ?? "", limit: 2000)
        reason = ProjectText.safe(value["reason"]?.string ?? "", limit: 400)
        atMs = value["at_ms"]?.natural
    }
}

/// One page of a project's board.
public struct ProjectPage: Sendable, Equatable {
    public let project: String
    /// The ledger's newest sequence number. A board with the same revision as the
    /// last one changes nothing a person can see.
    public let revision: Int
    /// All tickets in the project, which may exceed the page. Nil when the daemon sent
    /// none, which is not the same as nothing left out.
    public let total: Int?
    public let tickets: [ProjectTicket]
    /// Rows the decoder could not address and left out.
    public let unreadable: Int
    /// How many replies the router has queued, on page zero.
    public let replies: Int
    public let unrouted: [ProjectUnrouted]

    /// How many tickets the page leaves out: the total less the rows it carries and the
    /// rows it could not read, which are among those it carries. Nil when the daemon
    /// sent no total.
    public var leftOut: Int? {
        total.map { max(0, $0 - tickets.count - unreadable) }
    }

    public init?(_ value: JSONValue) {
        guard let project = value["project"]?.string, let revision = value["revision"]?.natural else { return nil }
        let rows = value["tickets"]?.array ?? []
        let tickets = rows.compactMap(ProjectTicket.init)
        self.project = project
        self.revision = revision
        self.tickets = tickets
        unreadable = rows.count - tickets.count
        total = value["total"]?.natural
        replies = value["replies"]?.array?.count ?? 0
        unrouted = (value["unrouted"]?.array ?? []).compactMap(ProjectUnrouted.init)
    }
}

/// One project in `projects.list`.
public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let workspace: String
    /// The router's session. Absent when the daemon names none.
    public let routerSession: String?
    /// Tickets by the daemon's stage word.
    public let counts: [String: Int]

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, !id.isEmpty, id.count <= 64 else { return nil }
        self.id = id
        workspace = ProjectText.safe(value["workspace"]?.string ?? "", limit: 1024)
        routerSession = value["router_session"]?.string
        var counts: [String: Int] = [:]
        for (word, count) in value["counts"]?.members ?? [:] {
            if let count = count.natural { counts[ProjectText.safe(word, limit: 64)] = count }
        }
        self.counts = counts
    }

    /// The project's name: the last component of its folder.
    public var name: String {
        let last = (workspace as NSString).lastPathComponent
        return last.isEmpty ? id : last
    }

    /// The counts as `(stage, count)` pairs in board order, zero counts left out.
    public var stages: [(stage: ProjectStage, count: Int)] {
        counts.filter { $0.value > 0 }
            .map { (stage: ProjectStage(word: $0.key), count: $0.value) }
            .sorted { ($0.stage.urgency, $0.stage.word) < ($1.stage.urgency, $1.stage.word) }
    }
}

/// A ticket's assignment of a worker.
public struct ProjectAssignment: Sendable, Equatable {
    public let seq: Int
    public let session: String?
    /// `pending`, `running`, `done/exited`, `done/crashed`, `done/rested`, or a
    /// word this client does not know, kept as text.
    public let status: String

    init?(_ value: JSONValue) {
        guard let seq = value["seq"]?.natural else { return nil }
        self.seq = seq
        session = value["session"]?.string
        status = ProjectText.safe(value["status"]?.string ?? "", limit: 64)
    }
}

/// A message on a ticket's opening thread.
public struct ProjectInput: Sendable, Equatable {
    public let trigger: String
    /// `delivered`, `waiting`, `failed`, `recorded`, or a word kept as text.
    public let delivery: String
    public let source: String?
    public let actor: String?
    public let text: String?

    init?(_ value: JSONValue) {
        guard let trigger = value["trigger"]?.string else { return nil }
        self.trigger = trigger
        delivery = ProjectText.safe(value["delivery"]?.string ?? "", limit: 32)
        source = value["source"]?.string.map { ProjectText.safe($0, limit: 64) }
        actor = value["actor"]?.string.map { ProjectText.safe($0, limit: 128) }
        text = value["text"]?.string.map { ProjectText.safe($0, limit: 2000) }
    }
}

/// `projects.ticket`: one ticket with its assignments and opening thread.
public struct ProjectDetail: Sendable, Equatable {
    public let project: String
    public let revision: Int
    public let ticket: ProjectTicket
    /// Newest first.
    public let assignments: [ProjectAssignment]
    /// Oldest first.
    public let inputs: [ProjectInput]

    public init?(_ value: JSONValue) {
        guard let project = value["project"]?.string, let ticket = value["ticket"].flatMap(ProjectTicket.init) else { return nil }
        self.project = project
        self.ticket = ticket
        revision = value["revision"]?.natural ?? 0
        assignments = (value["assignments"]?.array ?? []).compactMap(ProjectAssignment.init)
        inputs = (value["inputs"]?.array ?? []).compactMap(ProjectInput.init)
    }
}

/// Decodes `projects.list`.
public enum ProjectList {
    public static func decode(_ value: JSONValue) -> [ProjectSummary] {
        (value["projects"]?.array ?? []).compactMap(ProjectSummary.init)
    }
}
