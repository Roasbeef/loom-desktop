import Foundation
import LoomKit

// What a review stages before Send, the one prompt Send delivers, and where a Send
// stands. It mirrors the web view's `review_stage_rule.gleam`,
// `review_outbox_rule.gleam` and `review_pane.gleam`.
//
// Nothing here reaches the agent. A staged item is a value, replaced by staging it
// again and taken back by clearing. The verdict is not a daemon command: it is words
// in a prompt, so staging a verdict and sending it is an ordinary `prompt` on the
// session's main strand, the same command the message bar sends.
//
// One Send closes the staged finds at the revisions the pane read, one at a time, and
// then delivers one prompt. The prompt is composed, and refused when it is past the
// daemon's bound, before the first close, so an oversized review has no side effect.
// A close the daemon refuses halts the Send, because the prompt says what was closed
// and would otherwise be wrong. Closes already applied stay applied and are not
// applied again by the next Send. A prompt the daemon refuses leaves the staging as
// it was, so Send can be pressed again.
//
// The rule is pure. A comment is the owner's own words and a path is the
// repository's; the rule bounds the first and compares the second.
//
// ## Flow
//
// `ReviewOutbox.toggle`, `comment` and `close` stage; `send` composes the prompt and
// says what to ask first; `closed` takes the daemon's word on a close and says what
// is next; `prompted` takes its word on the prompt and ends the Send.

/// The owner's judgement of the work as a whole.
public enum ReviewVerdict: Sendable, Equatable {
    case approve, requestChanges, comment

    /// The words the prompt carries.
    public var words: String {
        switch self {
        case .approve: return "approved"
        case .requestChanges: return "changes requested"
        case .comment: return "comments only, no decision"
        }
    }

    /// The button's label.
    public var label: String {
        switch self {
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        case .comment: return "Comment"
        }
    }
}

/// One file's comment.
public struct ReviewFileComment: Sendable, Equatable {
    public let path: String
    /// What the owner wrote, trimmed and never empty.
    public let text: String
}

/// One find the owner chose to close, and how.
public struct ReviewFindAction: Sendable, Equatable {
    public enum Standing: Sendable, Equatable {
        /// Staged and not yet applied: Send applies it first.
        case pending
        /// The daemon applied it. It stays, so the prompt still says it was closed.
        case applied
    }

    public let id: String
    /// The revision the pane read the find at, which the daemon checks.
    public let revision: Int
    public let outcome: FindOutcome
    /// What the owner wrote about it, trimmed, when they wrote anything.
    public let note: String?
    public let standing: Standing
}

/// Why a stage was refused.
public enum ReviewStageProblem: Sendable, Equatable {
    case unknownFile
    case tooLong
    case unreadFind

    public var words: String {
        switch self {
        case .unknownFile: return "That file is not in this review."
        case .tooLong: return "That note is over \(ReviewOutbox.noteLimit) bytes. Shorten it."
        case .unreadFind: return "That find has not been read yet, so it cannot be closed."
        }
    }
}

/// Why no prompt could be made.
public enum ReviewRefusal: Error, Sendable, Equatable {
    case nothingStaged
    /// A comment names a file the review no longer holds.
    case fileMissing
    case tooLong(bytes: Int)

    public var words: String {
        switch self {
        case .nothingStaged: return "Nothing is staged."
        case .fileMissing: return "A comment names a file this review no longer holds."
        case .tooLong(let bytes):
            return "This review is \(bytes) bytes, over the \(ThreadSend.promptLimit) byte limit. Shorten a comment or a note."
        }
    }
}

/// What the daemon said of one close.
public struct ReviewCloseResult: Sendable, Equatable {
    public let find: String
    public let outcome: FindOutcome
    public let isDone: Bool
    /// The daemon's own words for a refusal, or the app's fixed words for a close.
    public let words: String

    public init(find: String, outcome: FindOutcome, isDone: Bool, words: String) {
        self.find = find
        self.outcome = outcome
        self.isDone = isDone
        self.words = words
    }
}

/// What became of the prompt.
public enum ReviewPromptResult: Sendable, Equatable {
    /// No prompt was sent, and the words say why.
    case notSent(String)
    /// The daemon took it. The words are `ThreadSend.deliveredWords`.
    case delivered(String)
    /// The daemon refused it, or did not answer. The words say which.
    case refused(String)
}

/// What a Send did: each close in the order it was applied, and the prompt.
public struct ReviewReceipt: Sendable, Equatable {
    public let closes: [ReviewCloseResult]
    public let prompt: ReviewPromptResult

    /// One line for each close and one for the prompt.
    public var lines: [String] {
        closes.map { "\($0.find) (\($0.outcome.rawValue)): \($0.words)" } + [promptWords]
    }

    private var promptWords: String {
        switch prompt {
        case .notSent(let words), .delivered(let words), .refused(let words): return words
        }
    }
}

/// What to ask of the daemon next.
public enum ReviewStep: Sendable, Equatable {
    /// Close a find at the revision the pane read.
    case close(find: String, revision: Int, outcome: FindOutcome)
    /// Deliver the composed prompt to the session's main strand.
    case prompt(String)
    /// Nothing more is asked: the send ended, and `progress` says how.
    case halted
}

/// The staged items of one open review, and where a Send stands.
public struct ReviewOutbox: Sendable, Equatable {
    /// The most bytes one comment or find note may hold. It is far under the prompt
    /// bound, so one note cannot take the whole of it, and the total is still checked.
    public static let noteLimit = 4096

    public enum Progress: Sendable, Equatable {
        case resting
        /// A send is out. `prompt` was composed, and checked against the bound,
        /// before the first close was asked. Staging is refused while a send is out,
        /// so the text is the one that was checked.
        case sending(done: [ReviewCloseResult], prompt: String)
        case settled(ReviewReceipt)
    }

    public private(set) var verdict: ReviewVerdict?
    /// In the order they were first staged.
    public private(set) var comments: [ReviewFileComment] = []
    public private(set) var finds: [ReviewFindAction] = []
    /// Why the last stage was refused.
    public private(set) var problem: String?
    public private(set) var progress: Progress = .resting

    public init() {}

    public var hasStaged: Bool { verdict != nil || !comments.isEmpty || !finds.isEmpty }

    public var isSending: Bool {
        if case .sending = progress { return true }
        return false
    }

    // MARK: Staging

    /// Stages a verdict. Choosing the one already staged takes it back, so a verdict
    /// pressed by mistake is one press from gone.
    public mutating func toggle(_ chosen: ReviewVerdict) {
        guard !isSending else { return }
        verdict = verdict == chosen ? nil : chosen
        restart()
    }

    /// Stages a file's comment, replacing the one before it. Text with nothing in it
    /// takes the file's comment back. A path the review does not hold, and a text
    /// past `noteLimit` bytes, are refused and change nothing.
    public mutating func comment(files: [String], path: String, text: String) {
        guard !isSending else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard files.contains(path) else { return refuse(.unknownFile) }
        guard trimmed.utf8.count <= Self.noteLimit else { return refuse(.tooLong) }
        let entry = ReviewFileComment(path: path, text: trimmed)
        if trimmed.isEmpty {
            comments.removeAll { $0.path == path }
        } else if let held = comments.firstIndex(where: { $0.path == path }) {
            comments[held] = entry
        } else {
            comments.append(entry)
        }
        restart()
    }

    /// Stages how a find is closed. `revision` is the one the pane read the find at,
    /// or nil for a find not read, which waits. The action replaces the one staged
    /// for the same find, unless the daemon has applied that one: a closed find is
    /// closed, and is not closed a second way.
    public mutating func close(find: String, revision: Int?, outcome: FindOutcome, note: String) {
        guard !isSending else { return }
        guard let revision else { return refuse(.unreadFind) }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= Self.noteLimit else { return refuse(.tooLong) }
        let entry = ReviewFindAction(
            id: find, revision: revision, outcome: outcome, note: trimmed.isEmpty ? nil : trimmed, standing: .pending
        )
        if let held = finds.firstIndex(where: { $0.id == find }) {
            if finds[held].standing == .pending { finds[held] = entry }
        } else {
            finds.append(entry)
        }
        restart()
    }

    /// Takes back everything staged.
    public mutating func clear() {
        guard !isSending else { return }
        self = ReviewOutbox()
    }

    private mutating func refuse(_ reason: ReviewStageProblem) { problem = reason.words }

    /// A stage that was taken ends the receipt of the Send before it.
    private mutating func restart() {
        problem = nil
        progress = .resting
    }

    // MARK: The prompt

    /// The prompt for what is staged, or the reason there is none. `files` are the
    /// paths of the review in the order it draws them, which orders the comments.
    ///
    /// The prompt reads "I reviewed your changes. Verdict: changes requested.", then
    /// the file comments and the closed finds, each section only when something was
    /// staged for it.
    public func compose(files: [String]) -> Result<String, ReviewRefusal> {
        guard hasStaged else { return .failure(.nothingStaged) }
        guard comments.allSatisfy({ files.contains($0.path) }) else { return .failure(.fileMissing) }

        var parts = [verdict.map { "I reviewed your changes. Verdict: \($0.words)." } ?? "I reviewed your changes."]
        let ordered = files.compactMap { path in comments.first { $0.path == path } }
        if !ordered.isEmpty {
            parts.append("File comments:")
            parts.append(ordered.map { "\($0.path):\n\($0.text)" }.joined(separator: "\n\n"))
        }
        if !finds.isEmpty {
            parts.append("Finds I closed:")
            parts.append(finds.map { action in
                let base = "\(action.id): \(action.outcome.rawValue)."
                return action.note.map { "\(base) \($0)" } ?? base
            }.joined(separator: "\n"))
        }
        let text = parts.joined(separator: "\n\n")
        let bytes = text.utf8.count
        return bytes > ThreadSend.promptLimit ? .failure(.tooLong(bytes: bytes)) : .success(text)
    }

    // MARK: Send

    /// Begins a Send and says what to ask first. A send already out and an empty
    /// outbox begin nothing. A prompt that cannot be composed is refused here,
    /// before any close.
    public mutating func send(files: [String]) -> ReviewStep {
        if isSending { return .halted }
        switch compose(files: files) {
        case .failure(let refusal):
            if refusal != .nothingStaged {
                progress = .settled(ReviewReceipt(closes: [], prompt: .notSent(refusal.words)))
            }
            return .halted
        case .success(let text):
            problem = nil
            progress = .sending(done: [], prompt: text)
            return next()
        }
    }

    /// Takes the daemon's word on the close that was asked, and says what is next.
    /// A close that was done marks its action applied. One that was refused drops its
    /// action, so the owner stages it again against what is there now, and halts the
    /// send with the prompt unsent.
    public mutating func closed(_ result: ReviewCloseResult) -> ReviewStep {
        guard case .sending(let done, let prompt) = progress else { return .halted }
        let results = done + [result]
        if result.isDone {
            if let held = finds.firstIndex(where: { $0.id == result.find }) {
                let action = finds[held]
                finds[held] = ReviewFindAction(
                    id: action.id, revision: action.revision, outcome: action.outcome, note: action.note, standing: .applied
                )
            }
            progress = .sending(done: results, prompt: prompt)
            return next()
        }
        finds.removeAll { $0.id == result.find }
        progress = .settled(ReviewReceipt(closes: results, prompt: .notSent("Nothing was sent to the agent.")))
        return .halted
    }

    /// Takes the daemon's word on the prompt. A delivery empties the staging, and a
    /// refusal leaves it, so Send can be pressed again.
    public mutating func prompted(_ result: ReviewPromptResult) {
        guard case .sending(let done, _) = progress else { return }
        if case .delivered = result {
            verdict = nil
            comments = []
            finds = []
        }
        progress = .settled(ReviewReceipt(closes: done, prompt: result))
    }

    /// The first close not yet applied, else the prompt that was composed when the
    /// send began.
    private func next() -> ReviewStep {
        if let action = finds.first(where: { $0.standing == .pending }) {
            return .close(find: action.id, revision: action.revision, outcome: action.outcome)
        }
        if case .sending(_, let prompt) = progress { return .prompt(prompt) }
        return .halted
    }
}
