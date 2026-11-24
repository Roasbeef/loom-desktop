import Foundation
import LoomKit

// The rule behind project mode on the desktop: which tickets are threads in the
// inbox, which lane a ticket sits in, which controls a ticket draws, and the words
// the Projects destination and a ticket's pane say. It mirrors the web view's rule
// (loom packages/web_view/src/web_view/ticket_rule.gleam and
// packages/session_view/src/session_view/project_board.gleam), so the same ticket
// sits in the same group on both clients.
//
// The rule is pure. It reads no clock, calls no daemon and draws nothing, so a test
// states every decision with a fixed `now`.
//
// Three rules shape it.
//
// - A control exists only for an action the daemon listed for that ticket. The
//   stage is never read to decide one, because the daemon lists actions from the
//   engine's own rules, and a stage this client does not know would otherwise get
//   none or the wrong ones. An action word the client does not know has no control.
// - A stage is drawn with the daemon's own word, `person/check` included. This
//   client words what each stage means in a gloss beside it and never in place of it.
// - Every string in a ticket is external text. The decoders made it safe to draw,
//   and a view draws it with `Text(verbatim:)`.
//
// ## Flow
//
// `waiting` → `lane` → `controls` → `press` → `refusal`
//
// 1. `waiting` picks the tickets that need a person out of the boards, in the
//    board's own order.
// 2. `lane` says which inbox group a waiting ticket sits in.
// 3. `controls` says which controls the daemon's list leaves for one ticket.
// 4. `press` says whether a control asks again before it is sent.
// 5. `refusal` words the daemon's answer to an act that did not go through.

/// A project the app has read: the list's row, and the last page zero of its board
/// when one has answered. A project whose board did not read has no tickets here,
/// which is not the same as having none.
public struct ProjectState: Sendable, Equatable, Identifiable {
    public let summary: ProjectSummary
    public let page: ProjectPage?
    public var id: String { summary.id }

    public init(summary: ProjectSummary, page: ProjectPage?) {
        self.summary = summary
        self.page = page
    }
}

/// A ticket with the address that opens it.
public struct ProjectTicketRef: Sendable, Equatable {
    public let project: String
    public let projectName: String
    public let ticket: ProjectTicket

    public init(project: String, projectName: String, ticket: ProjectTicket) {
        self.project = project
        self.projectName = projectName
        self.ticket = ticket
    }
}

/// Which inbox group a waiting ticket sits in.
public enum TicketLane: Sendable, Equatable {
    /// The worker waits for an answer or a decision the person owes it: "Needs you".
    case answering
    /// The work is finished and waits to be read, `person/review` or `person/check`:
    /// "To review".
    case reviewing
}

/// One thing a person can do to a ticket.
public enum TicketControl: Sendable, Equatable, Hashable {
    /// Answer the open question. The sequence number is the question's as the pane
    /// was drawn, and the daemon refuses an answer to any other.
    case answer(seq: Int)
    case recheck, retry, close, publish, stop

    /// The word on the button.
    public var title: String {
        switch self {
        case .answer: return "Answer"
        case .recheck: return "Check Again"
        case .retry: return "Retry"
        case .close: return "Close Ticket"
        case .publish: return "Publish"
        case .stop: return "Stop"
        }
    }

    /// The act that needs no text, or nil for an answer.
    public var act: TicketAct? {
        switch self {
        case .answer: return nil
        case .recheck: return .recheck
        case .retry: return .retry
        case .close: return .close
        case .publish: return .publish
        case .stop: return .stop
        }
    }

    /// Whether a first press only asks. Close and Stop end work and cannot be
    /// undone, and Publish pushes a branch and opens a pull request, so each asks
    /// once on a button that names the act. Retry, Check Again and Answer are sent.
    public var needsConfirmation: Bool {
        switch self {
        case .close, .stop, .publish: return true
        case .answer, .recheck, .retry: return false
        }
    }

    /// What the confirmation says the act does.
    public var consequence: String {
        switch self {
        case .close: return "Accepts the work and ends the ticket. A later message can reopen it."
        case .stop: return "Withdraws the ticket's mandate. The ticket can never resume."
        case .publish: return "Pushes the ticket's head to the project's remote and opens a pull request, whatever the check said."
        case .answer, .recheck, .retry: return ""
        }
    }
}

public enum ProjectRule {
    // MARK: Waiting tickets

    /// The tickets that need a person, project by project in the order given and
    /// within a project in the board's order. A project whose board did not read has
    /// none.
    public static func waiting(_ projects: [ProjectState]) -> [ProjectTicketRef] {
        projects.flatMap { project -> [ProjectTicketRef] in
            guard let page = project.page else { return [] }
            return ordered(page.tickets).filter(\.stage.needsPerson)
                .map { ProjectTicketRef(project: project.id, projectName: project.summary.name, ticket: $0) }
        }
    }

    /// Needs-a-person tickets first, by stage urgency, and in arrival order within a
    /// stage, since the daemon sends a page newest first.
    public static func ordered(_ tickets: [ProjectTicket]) -> [ProjectTicket] {
        tickets.enumerated().sorted { left, right in
            let (a, b) = (left.element.stage.urgency, right.element.stage.urgency)
            return a != b ? a < b : left.offset < right.offset
        }.map(\.element)
    }

    /// The lane of a waiting ticket. A review or a check is read, and every other
    /// stage that needs a person is a question or a failure the person answers.
    public static func lane(of ticket: ProjectTicket) -> TicketLane {
        switch ticket.stage {
        case .personReview, .personCheck: return .reviewing
        default: return .answering
        }
    }

    /// The tickets of a board grouped into runs of one stage word, in board order.
    public static func groups(_ tickets: [ProjectTicket]) -> [(stage: ProjectStage, tickets: [ProjectTicket])] {
        var groups: [(stage: ProjectStage, tickets: [ProjectTicket])] = []
        for ticket in ordered(tickets) {
            if let index = groups.firstIndex(where: { $0.stage.word == ticket.stage.word }) {
                groups[index].tickets.append(ticket)
            } else {
                groups.append((ticket.stage, [ticket]))
            }
        }
        return groups
    }

    // MARK: Words

    /// What a stage means, in a few words beside the daemon's own word. The word is
    /// never replaced: a client that renamed `person/check` would hide the open
    /// question of what to call it.
    public static func gloss(_ stage: ProjectStage) -> String {
        switch stage {
        case .personDelivery: return "a message never reached the worker"
        case .personAnswer: return "the worker asked a question"
        case .personReview: return "the work waits for your review"
        case .personBlocked: return "the worker reported itself blocked"
        case .personFailed: return "the worker could not start"
        case .personCheck: return "the check failed and nobody is handling it"
        case .queued: return "waiting for a session"
        case .idle: return "nothing is running and nothing is wanted"
        case .working: return "a worker is on it"
        case .ended(let outcome): return "ended: \(outcome)"
        case .unknown: return "a stage this app does not know"
        }
    }

    /// The ticket's name on a row: its title, or "Untitled ticket".
    public static func titleWords(_ ticket: ProjectTicket) -> String {
        ticket.title.map(InboxRule.oneLine) ?? "Untitled ticket"
    }

    /// The one line a ticket row says under its name: the daemon's stage word, then
    /// the first thing the ticket has to say, which is the open question, the
    /// reason a worker could not start, the check's own sentence or the host's
    /// reason it waits for review. The line is cut like a session row's.
    public static func head(_ ref: ProjectTicketRef) -> String {
        let ticket = ref.ticket
        let detail: String?
        if let question = ticket.question {
            detail = question.text
        } else if let failure = ticket.failure {
            detail = failure
        } else if let check = ticket.check, check.outcome == .failed {
            detail = "Check failed" + (check.cause.map { " (\($0))" } ?? "")
        } else {
            detail = ticket.review
        }
        let line = detail.flatMap { text in
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        }
        let lead = "\(ref.projectName) \u{00B7} \(ticket.stage.word)"
        return InboxRule.cut(line.map { "\(lead) \u{00B7} \(InboxRule.oneLine($0))" } ?? lead)
    }

    /// How long ago a ticket's opening message arrived, or nothing when the daemon
    /// no longer holds that message. An age is never taken from when this app first
    /// saw the ticket.
    public static func age(_ ticket: ProjectTicket, now: Int) -> InboxAge? {
        InboxRule.age(since: ticket.openedMs, now: now)
    }

    /// Why the ticket was allowed to exist, as a sentence, or nothing when the
    /// daemon did not say.
    public static func mandateWords(_ mandate: ProjectMandate?) -> String? {
        guard let mandate else { return nil }
        let who = mandate.actor.isEmpty ? mandate.source : "\(mandate.actor) via \(mandate.source)"
        let how: String
        switch mandate.via {
        case "composer": how = "asked for it"
        case "addressed": how = "addressed the router"
        case "follow_up": how = "followed up"
        case "overheard": how = "was overheard"
        case "automation": how = "an automation started it"
        case "rule": how = "a rule matched"
        default: how = mandate.via.isEmpty ? "started it" : mandate.via
        }
        let strength = mandate.strength == "inferred" ? "Inferred" : "Explicit"
        return who.isEmpty ? "\(strength): \(how)" : "\(strength): \(who) \(how)"
    }

    /// The count of tickets by stage as the project row says it: the daemon's words
    /// with their counts, such as "2 person/answer \u{00B7} 1 working", or "No tickets".
    public static func countWords(_ summary: ProjectSummary) -> String {
        let stages = summary.stages
        guard !stages.isEmpty else { return "No tickets" }
        return stages.map { "\($0.count) \($0.stage.word)" }.joined(separator: " \u{00B7} ")
    }

    /// How many of a project's tickets need a person, from the list's counts.
    public static func needing(_ summary: ProjectSummary) -> Int {
        summary.stages.filter(\.stage.needsPerson).reduce(0) { $0 + $1.count }
    }

    /// The line a healthy board shows.
    public static func health(_ summary: ProjectSummary) -> String {
        let need = needing(summary)
        switch need {
        case 0: return "Nothing needs you"
        case 1: return "1 ticket needs you"
        default: return "\(need) tickets need you"
        }
    }

    // MARK: Router

    /// What the router's session is doing, in a few words, from the session list's
    /// record of it. A router the list does not hold reads as not running, never as
    /// healthy.
    public static func routerWords(_ state: SessionState?) -> String {
        guard let state else { return "Router session not listed" }
        return state.isResident ? "Router running" : "Router saved"
    }

    // MARK: Controls

    /// The controls a ticket draws, in a fixed order: Answer, Check Again, Retry,
    /// Close, Publish, Stop. Each is there only when the daemon lists its action. An
    /// answer also needs the open question whose number it carries. Publish is
    /// listed by the daemon only while the project's publish setting is on, and an
    /// action this client does not know has no control.
    public static func controls(_ ticket: ProjectTicket) -> [TicketControl] {
        var controls: [TicketControl] = []
        if ticket.offers(.answer), let question = ticket.question { controls.append(.answer(seq: question.seq)) }
        if ticket.offers(.recheck) { controls.append(.recheck) }
        if ticket.offers(.retry) { controls.append(.retry) }
        if ticket.offers(.close) { controls.append(.close) }
        if ticket.offers(.publish) { controls.append(.publish) }
        if ticket.offers(.stop) { controls.append(.stop) }
        return controls
    }

    /// Whether a press is honoured: only for a control the ticket draws now, so a
    /// press drawn for a ticket the next read has changed asks nothing.
    public static func allows(_ ticket: ProjectTicket, _ control: TicketControl) -> Bool {
        controls(ticket).contains(control)
    }

    // MARK: Words for an act

    /// The words for an act the daemon took.
    public static func told(_ control: TicketControl) -> String {
        switch control {
        case .answer: return "Answer sent. The worker has it queued."
        case .recheck: return "The check is running again."
        case .retry: return "A new worker was asked for."
        case .close: return "Ticket closed. The mandate stands."
        case .publish: return "Publishing was asked for. The host pushes the branch."
        case .stop: return "Ticket stopped."
        }
    }

    /// The words for an act the daemon refused. A `bad_request` carries the
    /// project's own sentence, which is shown as it came; every other code is made
    /// into a sentence here, and nothing a person or a worker wrote is used.
    public static func refusal(code: String, message: String, control: TicketControl) -> String {
        switch code {
        case "conflict":
            if case .answer = control { return "The question changed. Read it again before answering." }
            return "The ticket changed. Read it again."
        case "forbidden": return "Only the owner can do that."
        case "not_found": return "The project or ticket is gone."
        case "bad_request":
            let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return said.isEmpty || said == "request refused" ? "The daemon refused it." : ProjectText.safe(said, limit: 600)
        case "unavailable": return "The daemon could not take it now. Try again."
        default: return "The daemon refused it (\(ProjectText.safe(code, limit: 32)))."
        }
    }
}
