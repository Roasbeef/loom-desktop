import Foundation
import LoomKit

// What a person may answer to an ask, and what the daemon's refusal means for the
// next press. An ask is a list of typed questions (loom protocol-change/119). The
// pane draws one control for each, and this file decides, with no clock and no
// drawing, whether the person's entries make an answer the daemon would accept, which
// words say why not, and when the form may send again.
//
// The check mirrors the daemon's `core/attention_answer.gleam`, which is the rule
// the page and the control socket share: the same keys, the same kinds, the same
// bounds. It is here so that an answer the daemon is certain to refuse is not sent.
// It is not the authority: the daemon checks again against the stored ask, and its
// words are what the pane shows for anything this check let through.
//
// ## Flow
//
// `AnswerRule.offer` says whether the ask shows a form or only words (answered,
// routed to a strand, observer, a question this app cannot draw, an older daemon).
// `check` turns the entries into the `attention.answer` body or the first question
// that fails. `refusalWords` words a refusal, and `AnswerFlow` holds the form after any
// send until the form's own read of the record has landed.
//
// ## Where this departs from the web
//
// - The web builds the prompt's length into its check. Here the daemon's refusal
//   ("the answer is too long to send") is the only word on the whole prompt's size.
// - A question kind this app does not know has no control, so the ask is shown
//   read-only and answered on the session's page.

/// What a person entered for one question.
public enum AnswerEntry: Sendable, Equatable {
    /// Nothing yet.
    case unset
    /// A `confirm` question.
    case confirm(Bool)
    /// A `choice` question: the option's label.
    case picked(String)
    /// A `multiple` or `checklist` question: the labels ticked.
    case ticked(Set<String>)
    /// A `fill` question: the text as typed.
    case typed(String)
    /// "Other" for any question: the person's own words.
    case other(String)
}

/// The first question that cannot be answered as entered, and why in words a
/// person reads.
public struct AnswerRefusal: Error, Sendable, Equatable {
    public let key: String
    public let words: String
}

/// Whether the entries make an answer.
public enum AnswerCheck: Sendable, Equatable {
    case ready(AttentionAnswerBody)
    case refused(AnswerRefusal)
}

/// What an ask offers a person: the form, or the words that stand in its place.
public enum AnswerOffer: Sendable, Equatable {
    case form
    case words(String)
}

public enum AnswerRule {
    /// The longest Other text, in bytes (`core/attention_answer.max_other_bytes`).
    public static let maxOtherBytes = 1000
    /// The longest `fill` of the `long_text` format, in bytes.
    public static let maxLongTextBytes = 4000
    /// The longest `fill` of any other format, in bytes.
    public static let maxFillBytes = 1000

    /// What the session page's card says when the daemon cannot take an answer.
    public static let cardUnsupportedWords = "This daemon cannot take answers here. Answer it in the web view."

    /// The line an ask keeps when the daemon cannot take an answer, which is what the
    /// app said before the command existed.
    public static let unsupportedWords = "Answer on the session's page; this window shows an ask and does not answer it."

    // MARK: What is offered

    /// Whether an ask shows a form. `status` is the record's (`open`, `answered`);
    /// `unsupported` is true when the daemon has refused the command as unknown.
    ///
    /// `unsupportedWords` is what an older daemon's ask says; the session page's card
    /// passes its own, since the default sends a reader to the page they are on.
    public static func offer(
        ask: AttentionRecord.Ask, status: String, isObserver: Bool, unsupported: Bool,
        unsupportedWords: String = AnswerRule.unsupportedWords
    ) -> AnswerOffer {
        if unsupported { return .words(unsupportedWords) }
        if status == "answered" { return .words("This ask has been answered.") }
        if let routing = ask.routing, routing != "owner" {
            return .words("This ask is routed to the strand \(routing), which is not answered here.")
        }

        // The daemon tells an observer `may_answer: false`, and the connection's own
        // role says the same before a record has been read.
        if isObserver || !ask.mayAnswer { return .words("Only the owner or an operator can answer an ask.") }
        if !isAnswerable(ask.questions) {
            return .words("This ask has a question this app cannot draw. \(unsupportedWords)")
        }
        return .form
    }

    /// Whether every question is of a kind with a control, and an ask has questions.
    public static func isAnswerable(_ questions: [AttentionQuestion]) -> Bool {
        !questions.isEmpty && questions.allSatisfy { question in
            switch question.kind {
            case .confirm, .fill: return true
            case .choice, .multiple, .checklist: return !question.options.isEmpty
            case .other: return false
            }
        }
    }

    /// The fewest and most options a `multiple` question takes: its own bounds, or
    /// one and the option count, as the daemon defaults them.
    public static func bounds(of question: AttentionQuestion) -> (min: Int, max: Int) {
        (question.min ?? 1, question.max ?? question.options.count)
    }

    // MARK: Checking the entries

    /// The `attention.answer` body for the entries, or the first question, in the
    /// ask's order, that has no answer the daemon would take.
    public static func check(questions: [AttentionQuestion], entries: [String: AnswerEntry]) -> AnswerCheck {
        var values: [(key: String, value: AnswerValue)] = []
        for question in questions {
            switch value(of: question, entry: entries[question.key] ?? .unset) {
            case .success(let value): values.append((question.key, value))
            case .failure(let refusal): return .refused(refusal)
            }
        }
        return .ready(AttentionAnswerBody(entries: values))
    }

    private static func value(of question: AttentionQuestion, entry: AnswerEntry) -> Result<AnswerValue, AnswerRefusal> {
        func refuse(_ words: String) -> Result<AnswerValue, AnswerRefusal> {
            .failure(AnswerRefusal(key: question.key, words: words))
        }
        let labels = Set(question.options.map(\.label))

        // Other stands in for any kind, and its text is checked as the daemon checks it.
        if case .other(let text) = entry {
            if text.contains("\u{0000}") { return refuse("The text holds a character that cannot be sent.") }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return refuse("Say what you mean by Other.") }
            if text.utf8.count > maxOtherBytes { return refuse("The text is too long: at most \(maxOtherBytes) bytes.") }
            return .success(.other(text))
        }
        switch (question.kind, entry) {
        // A checklist takes any subset, and a multiple whose minimum is zero does, so
        // an untouched one is the empty answer the daemon accepts.
        case (.checklist, .unset): return .success(.labels([]))
        case (.multiple, .unset) where bounds(of: question).min == 0: return .success(.labels([]))
        case (_, .unset): return refuse("Answer this question.")
        case (.confirm, .confirm(let yes)): return .success(.confirm(yes))
        case (.choice, .picked(let label)):
            return labels.contains(label) ? .success(.choice(label)) : refuse("Pick one of the options.")
        case (.multiple, .ticked(let ticked)):
            let chosen = question.options.map(\.label).filter { ticked.contains($0) }
            let (low, high) = bounds(of: question)
            if chosen.count < low { return refuse(low == 1 ? "Pick at least one." : "Pick at least \(low).") }
            if chosen.count > high { return refuse("Pick at most \(high).") }
            return .success(.labels(chosen))
        case (.checklist, .ticked(let ticked)):
            // Any subset is an answer, an empty one included.
            return .success(.labels(question.options.map(\.label).filter { ticked.contains($0) }))
        case (.fill, .typed(let text)):
            return fill(text, format: question.format ?? "text", key: question.key)
        default:
            return refuse("Answer this question.")
        }
    }

    // MARK: Fill

    private static func fill(_ text: String, format: String, key: String) -> Result<AnswerValue, AnswerRefusal> {
        func refuse(_ words: String) -> Result<AnswerValue, AnswerRefusal> {
            .failure(AnswerRefusal(key: key, words: words))
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return refuse("Type an answer.") }
        if text.contains("\u{0000}") { return refuse("The text holds a character that cannot be sent.") }
        let limit = format == "long_text" ? maxLongTextBytes : maxFillBytes
        if text.utf8.count > limit { return refuse("The text is too long: at most \(limit) bytes.") }
        switch format {
        case "path" where text.contains("\n") || text.contains("\r"): return refuse("A path is one line.")
        case "number" where !isDecimal(text): return refuse("Type a number, such as 12 or -3.5.")
        case "url" where !isAddress(text): return refuse("Type an address that starts with http:// or https://.")
        default: return .success(.text(text))
        }
    }

    /// `-?[0-9]+(\.[0-9]+)?`, the daemon's decimal form, and nothing else.
    static func isDecimal(_ text: String) -> Bool {
        let unsigned = text.hasPrefix("-") ? String(text.dropFirst()) : text
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        func digits(_ part: Substring) -> Bool { !part.isEmpty && part.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
        switch parts.count {
        case 1: return digits(parts[0])
        case 2: return digits(parts[0]) && digits(parts[1])
        default: return false
        }
    }

    /// An absolute `http` or `https` address with something after the scheme and no
    /// whitespace anywhere.
    static func isAddress(_ text: String) -> Bool {
        let rest: Substring
        if text.hasPrefix("https://") { rest = text.dropFirst(8) } else if text.hasPrefix("http://") { rest = text.dropFirst(7) } else { return false }
        return !rest.isEmpty && !text.contains { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
    }

    // MARK: What the daemon said

    /// What a delivery says, in the words of a sent message: the strand took it now
    /// or holds it behind its turn.
    public static func deliveredWords(_ delivery: AnswerDelivery, name: String) -> String {
        "Answer delivered to \(name) \u{00B7} \(delivery.rawValue)"
    }

    /// The words of a refusal, which are the daemon's own. Nothing here decides what
    /// follows: every send, however it ended, holds the form until the record is read
    /// again (`AnswerFlow`), because the daemon's messages do not reliably say whether
    /// the prompt arrived.
    public static func refusalWords(code: String, message: String) -> String {
        message.isEmpty ? (Refusal.words(code: code) ?? code) : message
    }

    /// The words for a send that never got an answer. The prompt may have arrived,
    /// and a mutation is never resent on its own (client protocol section 6.5).
    public static let unansweredWords = "No answer in time; it may have arrived. The ask is read again before it can be answered."
}

/// The form's hold on sending, which keeps a second answer from being sent against
/// a record the first one made stale, or delivered twice.
///
/// One rule: after a send ends, whatever way it ended, the form is held. Only a read
/// of the record that the form itself started after the send returned releases it,
/// and a read that failed leaves it held. The daemon's refusal messages do not
/// reliably say whether the prompt arrived (some codes carry "delivered; the record
/// was not settled", and an `unavailable` may carry "the prompt may have arrived"),
/// so the form does not read them. The one exception is a daemon that does not know
/// the command, which the form never offers again (`declined`).
public struct AnswerFlow: Sendable, Equatable {
    /// The words on the last send or refusal. Nil before any.
    public private(set) var said: String?
    public private(set) var isSending = false
    public private(set) var isHeld = false

    public init() {}

    /// Whether Send may be pressed.
    public var maySend: Bool { !isSending && !isHeld }

    /// Starts a send. It answers false, and changes nothing, when one may not start.
    public mutating func begin() -> Bool {
        guard maySend else { return false }
        isSending = true
        return true
    }

    /// A send ended, delivered or refused or lost. The record is stale or in doubt
    /// from here, so the form waits for a read.
    public mutating func ended(words: String) {
        isSending = false
        said = words
        isHeld = true
    }

    /// The daemon does not know the command, so nothing was delivered and a read
    /// would say nothing. The form is not offered again, so it is not held.
    public mutating func declined(words: String) {
        isSending = false
        said = words
        isHeld = false
    }

    /// A read of the record landed after the last send returned.
    public mutating func readLanded() {
        isHeld = false
    }

    /// The reason the form gives for waiting, or nil when it is not held.
    public var holdWords: String? {
        isHeld ? "Reading the ask again before it can be answered\u{2026}" : nil
    }
}
