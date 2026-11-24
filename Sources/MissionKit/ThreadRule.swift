import Foundation
import LoomKit

// The words and the read plan of the inbox's reading pane. The pane draws one open
// thread, and this file decides what it says and which daemon reads opening the
// thread starts. It mirrors the web view's `thread_words.gleam`,
// `approval_evidence`'s title and rows (`view/attention_thread.gleam`),
// `brief_rule.gleam`, `thread_send.gleam` and `review_scan_rule.stat_words`.
//
// The rule is pure. It reads no clock and draws nothing: a sentence that holds an
// instant is a list of parts, and the caller words each instant in the reader's
// zone, so a test states every sentence with a fixed clock.
//
// ## Flow
//
// `reads(for:)` says what opening a thread asks the daemon; `briefDue` and
// `peersShown` pace and filter the brief; `approvalTitle` and `evidenceRows` word
// a pending approval; `stuckTitle` and `stuckPhrase` word a stuck strand;
// `turnWords`, `goalStatus`, `tokens`, `strandPhrase` and `delegates` word the
// brief's cards; `statWords` words a review's size; `ThreadSend` words a message
// sent from the pane.

/// One piece of a sentence that holds an instant.
public enum ThreadPart: Sendable, Equatable {
    /// Fixed words, or words the daemon bounded.
    case words(String)
    /// An instant in Unix milliseconds, worded as a time of day by the reader.
    case clock(Int)
}

/// A line of the pane that is code, or prose, in a composed title.
public enum TitlePart: Sendable, Equatable {
    case words(String)
    /// A command, a path or a tool name a model's call carried. Drawn as code.
    case code(String)
}

/// One row of an approval's evidence card.
public struct EvidenceRow: Sendable, Equatable {
    public let label: String
    public let value: String
    /// Whether the value is an identifier the card draws in monospace.
    public let isCode: Bool

    public init(label: String, value: String, isCode: Bool) {
        self.label = label
        self.value = value
        self.isCode = isCode
    }
}

/// What opening a thread asks the daemon. The daemon allows six brief reads in four
/// seconds for each credential, so only the open thread is read.
public struct ThreadReads: Sendable, Equatable {
    /// The session's pending approvals, which carry the evidence and the raise time.
    public let approval: Bool
    /// The session's brief.
    public let brief: Bool
    /// The ask or find to read in full.
    public let record: String?
    /// The session's worktree as a review, read once when the thread opens. It runs
    /// Git in the session's sandbox, so it is never repeated on the refresh.
    public let review: Bool

    public init(approval: Bool, brief: Bool, record: String?, review: Bool = false) {
        self.approval = approval
        self.brief = brief
        self.record = record
        self.review = review
    }

    public static let none = ThreadReads(approval: false, brief: false, record: nil)
}

/// The last brief read of one session, which pacing counts from.
public struct BriefRead: Sendable, Equatable {
    /// When it was started, in Unix milliseconds.
    public let started: Int
    /// The time it asked peer messages after, or zero.
    public let since: Int

    public init(started: Int, since: Int) {
        self.started = started
        self.since = since
    }
}

/// An instant a thread's eyebrow dates, with the words that say what happened at it.
public struct ThreadMoment: Sendable, Equatable {
    public let label: String
    public let at: Int
}

public enum ThreadRule {
    /// How old the last read of an open thread's brief must be before the refresh
    /// reads it again, in milliseconds.
    public static let refreshMs = 15_000

    // MARK: Which reads fire

    /// What opening `row` reads. An ask reads its record and its session's brief; a
    /// find reads its record; a stuck strand reads nothing, since its row holds the
    /// failure. A session thread reads a brief for every kind but a failed or quiet
    /// one, and an approval's thread reads its evidence as well.
    public static func reads(for row: InboxRow) -> ThreadReads {
        switch row.subject {
        case .ask(_, let id): return ThreadReads(approval: false, brief: true, record: id)
        case .find(_, let id): return ThreadReads(approval: false, brief: false, record: id)
        case .stuck: return .none
        case .ticket: return .none
        case .session:
            switch row.kind {
            case .approval: return ThreadReads(approval: true, brief: true, record: nil)
            case .review: return ThreadReads(approval: false, brief: true, record: nil, review: true)
            case .waiting, .working: return ThreadReads(approval: false, brief: true, record: nil)
            case .failed, .quiet, .ask, .stuck, .find, .ticket: return .none
            }
        }
    }

    /// Whether a brief read is worth starting at `now`. A session never read is
    /// always due, and so is one whose last read asked after another time, since its
    /// peer messages would not be the ones the thread labels. Every other read waits
    /// for `refreshMs`.
    public static func briefDue(last: BriefRead?, now: Int, since: Int) -> Bool {
        guard let last else { return true }
        if last.since != since { return true }
        return now - last.started >= refreshMs
    }

    /// Whether the brief's peer messages may be drawn. They are the messages that
    /// arrived after the time the read named, and the label over them says "since it
    /// asked", so they are shown only when that time is the approval's raise time.
    public static func peersShown(readSince: Int?, raised: Int?) -> Bool {
        guard let readSince, let raised else { return false }
        return readSince == raised
    }

    // MARK: Approval

    /// The title a pending approval composes, or nil when it wants no grant the
    /// design words. A write grant is worded first, since it names the place the call
    /// may change; a network grant names the tool.
    public static func approvalTitle(_ item: ApprovalEvidenceItem) -> [TitlePart]? {
        let write = item.wanted.first { $0.kind == "writable_root" }
        let network = item.wanted.first { $0.kind == "network" }
        if let write {
            return [.words("May "), .code(toolName(item)), .words(" have write access to "), .code(write.detail), .words("?")]
        }
        if network != nil {
            return [.words("May "), .code(toolName(item)), .words(" reach the network?")]
        }
        return nil
    }

    /// The tool the title names. The call's command is a model's text and can be long, so
    /// it is never the title; it stays in the facts under "Command".
    private static func toolName(_ item: ApprovalEvidenceItem) -> String {
        item.tool.isEmpty ? "this program" : item.tool
    }

    /// The title when the evidence composes none: the pane's own sentence.
    public static let approvalFallbackTitle = "An approval is pending."

    /// The rows of one pending approval's card: the tool, the action, what held the
    /// call, the network it would have, what it wants and the policy today. A row
    /// whose data the daemon left out is not drawn; the app never words "off" itself.
    public static func evidenceRows(_ item: ApprovalEvidenceItem) -> [EvidenceRow] {
        var rows = [EvidenceRow(label: "Tool", value: item.tool.isEmpty ? "not recorded" : item.tool, isCode: true)]
        if let preview = item.preview { rows.append(EvidenceRow(label: "Command", value: preview, isCode: true)) }
        if !item.reason.isEmpty {
            rows.append(EvidenceRow(label: "Held by", value: heldBy(item.source) + ": " + item.reason, isCode: false))
        }
        if let network = item.network { rows.append(EvidenceRow(label: "Network", value: network.rawValue, isCode: false)) }

        // The network grant first, under its own label, then every other grant.
        let networks = item.wanted.filter { $0.kind == "network" }
        if !networks.isEmpty {
            rows.append(EvidenceRow(label: "Wants a network grant", value: networks.map(\.detail).joined(separator: ", "), isCode: false))
        }
        let others = item.wanted.filter { $0.kind != "network" }
        if !others.isEmpty {
            rows.append(EvidenceRow(label: "Wants", value: others.map { "\($0.kind) \($0.detail)" }.joined(separator: "\n"), isCode: false))
        }
        if let policy = item.policy {
            rows.append(EvidenceRow(label: "Policy today", value: "\(policy.sandbox) \u{00B7} network \(policy.network)", isCode: true))
        }
        return rows
    }

    static func heldBy(_ source: String) -> String {
        switch source {
        case "policy": return "policy"
        case "execution": return "execution"
        default: return "the harness"
        }
    }

    // MARK: Stuck

    /// The pane's title for a stuck strand.
    public static func stuckTitle(reason: String?) -> String {
        switch InboxRule.Failure(reason: reason) {
        case .rateLimited: return "The last turn failed on a provider rate limit, and nothing has retried."
        case .overloaded: return "The last turn failed because the provider was overloaded, and nothing has retried."
        case .timedOut: return "The last turn failed because the provider did not answer in time, and nothing has retried."
        case .other: return "The last turn failed, and nothing has retried."
        }
    }

    /// The sentence that says what happened and when, then what the provider said
    /// about a retry. A time that is not known is left out, and a wait that is not
    /// known says the provider gave none, which is a statement about the reply.
    public static func stuckPhrase(_ stuck: AttentionStuck) -> [ThreadPart] {
        let failure = InboxRule.Failure(reason: stuck.reason)
        let lead: String
        switch failure {
        case .rateLimited: lead = "Rate-limited"
        case .overloaded: lead = "The provider was overloaded"
        case .timedOut: lead = "The provider did not answer in time"
        case .other: lead = "The last turn failed"
        }

        var parts: [ThreadPart] = stuck.failedAt.map { [.words(lead + " at "), .clock($0)] } ?? [.words(lead)]
        parts.append(.words("; nothing has retried."))
        parts += retryPhrase(failure, failedAt: stuck.failedAt, retryAfterMs: stuck.retryAfterMs)
        return parts
    }

    private static func retryPhrase(_ failure: InboxRule.Failure, failedAt: Int?, retryAfterMs: Int?) -> [ThreadPart] {
        // A reason that is not about the provider says nothing about one.
        switch failure {
        case .other, .timedOut: return []
        case .rateLimited, .overloaded: break
        }
        guard let wait = retryAfterMs else { return [.words(" The provider gave no reset time.")] }
        if let at = failedAt {
            return [.words(" The provider asked for a wait of \(waitWords(wait)), until "), .clock(at + wait), .words(".")]
        }
        return [.words(" The provider asked for a wait of \(waitWords(wait)).")]
    }

    /// A wait the provider asked for, in the largest whole unit that is not zero.
    static func waitWords(_ wait: Int) -> String {
        if wait < 60_000 { return "\(max(1, wait / 1000)) s" }
        if wait < 3_600_000 { return "\(wait / 60_000) min" }
        return "\(wait / 3_600_000) h"
    }

    /// The words Retry sends a stuck strand, from the pane and from the session
    /// page's rail alike. They are the web's own, fixed (`thread_send.retry_prompt`),
    /// so a strand is asked the same thing from either client, and nothing a person
    /// or a model wrote reaches them.
    public static let retryPrompt = "The last run of this strand failed. Please retry it."

    // MARK: The brief's cards

    /// How long the turn now running has gone on. A turn under a minute old, or one
    /// that starts after `now`, is "a turn that has just started".
    public static func turnWords(started: Int, now: Int) -> String {
        let wait = now - started
        if wait < 60_000 { return "a turn that has just started" }
        if wait < 3_600_000 { return "\(wait / 60_000) min into a turn" }
        if wait < 86_400_000 { return "\(wait / 3_600_000) h into a turn" }
        return "\(wait / 86_400_000) d into a turn"
    }

    /// A token count: the number below a thousand, then `412k`, then `1.2M` with the
    /// decimal left out when it is zero.
    public static func tokens(_ count: Int) -> String {
        if count < 1000 { return String(max(count, 0)) }
        if count < 1_000_000 { return "\(count / 1000)k" }
        let tenths = count / 100_000
        return tenths % 10 == 0 ? "\(tenths / 10)M" : "\(tenths / 10).\(tenths % 10)M"
    }

    /// The words for a goal's status, or nil for a word the app does not know.
    public static func goalStatus(_ status: String) -> String? {
        switch status {
        case "active": return "active"
        case "paused": return "paused"
        case "limited": return "stopped at its budget"
        case "complete": return "complete"
        default: return nil
        }
    }

    /// What a strand is doing and since when: `working since 14:06`. A strand whose
    /// time is not known has the state alone.
    public static func strandPhrase(state: BriefStrand.State, since: Int?) -> [ThreadPart] {
        let word: String
        switch state {
        case .working: word = "working"
        case .idle: word = "idle"
        case .stopped: word = "stopped"
        }
        return since.map { [.words(word + " since "), .clock($0)] } ?? [.words(word)]
    }

    /// How many strands are in each state: `1 working, 1 stopped, 2 idle`. A state
    /// no strand is in is left out, and no strands say nothing.
    public static func delegates(_ strands: [BriefStrand]) -> String {
        [(BriefStrand.State.working, "working"), (.stopped, "stopped"), (.idle, "idle")]
            .map { state, word in (strands.filter { $0.state == state }.count, word) }
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: ", ")
    }

    /// The pill that states the last command and how it ended. It is a fact about a
    /// call that ran, never the result of a check.
    public static func commandWords(_ command: BriefCommand) -> String {
        "last command: \(command.command.text), exit \(command.exit)"
    }

    // MARK: Review

    /// A review's size as the web's row says it: `+412 \u{2212}88, 7 files \u{00B7} 2 finds
    /// attached`. The finds are named only when there are some.
    public static func statWords(_ stat: ReviewStat, finds: Int) -> String {
        let files = stat.files == 1 ? "1 file" : "\(stat.files) files"
        let size = "+\(stat.added) \u{2212}\(stat.removed), \(files)"
        switch finds {
        case 0: return size
        case 1: return size + " \u{00B7} 1 find attached"
        case let many: return size + " \u{00B7} \(many) finds attached"
        }
    }

    /// What a "To review" thread says of its change: the size once the scan has read
    /// it, the failure when every try at the worktree failed, else that the scan is
    /// still at it.
    public static func reviewWords(stat: ReviewStat?, isUnreadable: Bool, finds: Int) -> String {
        if let stat { return statWords(stat, finds: finds) }
        return isUnreadable ? "The worktree could not be read." : "Checking the worktree\u{2026}"
    }

    /// Whether the pane offers its message bar. An observer watches and sends
    /// nothing, as the rail's buttons are not offered to one. A "To review" thread
    /// whose review has been read has the outbox in its place, as on the web, where a
    /// review has no message box of its own; one whose review is not read, because the
    /// worktree could not be read or the read is still out, still lets the person write
    /// to the session.
    public static func offersMessage(kind: InboxKind, hasReview: Bool, isObserver: Bool) -> Bool {
        if isObserver { return false }
        return kind != .review || !hasReview
    }

    /// What the pane's Retry button does for a stuck strand.
    public enum RetryOffer: Sendable, Equatable {
        /// Not drawn: the connection only watches, or the feed no longer lists the
        /// strand as stuck.
        case hidden
        /// Drawn and pressable.
        case enabled
        /// Drawn and not pressable, while a retry is out.
        case disabled
    }

    /// Whether Retry is offered. A retry that was delivered keeps the button off
    /// until the feed has been read again, and the feed then either no longer lists
    /// the strand, so the button goes, or still does, so a second press is the
    /// person's own choice and not a repeat of a stale row.
    public static func retryOffer(isObserver: Bool, stuckListed: Bool, sending: Bool) -> RetryOffer {
        if isObserver || !stuckListed { return .hidden }
        return sending ? .disabled : .enabled
    }

    // MARK: Eyebrow

    /// The time a thread's eyebrow dates: when an ask was asked, when a stuck strand
    /// failed, when an approval began to wait, when a finished session finished. A
    /// find waits on no one, and a record with no time has none.
    public static func moment(for row: InboxRow, raised: Int?) -> ThreadMoment? {
        switch row.kind {
        case .ask: return row.since.map { ThreadMoment(label: "asked", at: $0) }
        case .stuck: return row.since.map { ThreadMoment(label: "failed", at: $0) }
        case .approval: return (raised ?? row.since).map { ThreadMoment(label: "waiting since", at: $0) }
        case .waiting, .review: return row.since.map { ThreadMoment(label: "finished", at: $0) }
        case .ticket: return row.since.map { ThreadMoment(label: "opened", at: $0) }
        case .failed, .working, .quiet, .find: return nil
        }
    }

    /// Renders a phrase with `clock` wording each instant.
    public static func render(_ phrase: [ThreadPart], clock: (Int) -> String = ClockTime.local) -> String {
        phrase.map { part in
            switch part {
            case .words(let words): return words
            case .clock(let at): return clock(at)
            }
        }.joined()
    }
}

// MARK: Sending a message from the pane

/// What the pane's message field sends, and what it says happened. The words are
/// the app's own and never include text from a session or an error value, except
/// the daemon's own refusal words.
public enum ThreadSend {
    /// A button on the message field.
    public enum Choice: Sendable, Equatable {
        /// An ordinary prompt on an idle strand.
        case send
        /// A prompt the daemon holds until the running turn ends.
        case queue
        /// A steer: it stops the current turn and runs first.
        case steer

        public var label: String {
            switch self {
            case .send: return "Send"
            case .queue: return "Queue"
            case .steer: return "Steer"
            }
        }

        /// The session command the button sends.
        public var command: String { self == .steer ? "steer" : "prompt" }
    }

    /// The buttons a thread of this kind offers. A working session takes a queue and
    /// a steer; every other takes one send. A session with an approval pending
    /// takes a send alone, since a prompt starts a turn at once and a steer would
    /// stop nothing.
    public static func choices(for kind: InboxKind) -> [Choice] {
        kind == .working ? [.queue, .steer] : [.send]
    }

    /// The note shown beside an approval thread's message field: the code does not
    /// queue behind an approval.
    public static func holdNote(for kind: InboxKind) -> String? {
        kind == .approval
            ? "A message here starts a new turn now, and the session does not wait behind the approval for it. The approval is decided with the card above."
            : nil
    }

    /// Whether a draft may be sent: it holds something besides whitespace and fits
    /// the daemon's prompt bound of 16,384 bytes.
    public static func sendable(_ draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= promptLimit
    }

    /// The most bytes of one prompt the daemon takes.
    public static let promptLimit = 16_384

    /// What the bar says after a delivery. `status` is the daemon's `admitted` or
    /// `queued`, which is all it means: it does not say the session read the message.
    public static func deliveredWords(status: String?, choice: Choice, name: String) -> String {
        switch (status, choice) {
        case ("queued", .steer): return "Delivered to \(name) \u{00B7} steering: it stops the current turn and runs next"
        case ("queued", _): return "Delivered to \(name) \u{00B7} queued"
        default: return "Delivered to \(name) \u{00B7} admitted"
        }
    }

    /// The words for a send the daemon refused.
    public static func refusedWords(_ daemonWords: String) -> String {
        "Not sent: " + daemonWords
    }

    /// The words for a send that never answered. It may have arrived.
    public static let unansweredWords = "No answer in time; it may have arrived. Check the session before sending again."
}
