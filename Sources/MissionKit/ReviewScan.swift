import Foundation
import LoomKit

// Which idle sessions are "To review": the sessions that stopped with a last
// message and whose worktree holds changes. It mirrors the web view's
// `review_scan_rule.gleam`.
//
// Whether a worktree holds changes is known only by reading it, and a read is
// about twenty-six jailed Git calls on the session's helper pool, which the agent's
// own tools share. The daemon allows a credential two in four seconds. The scan
// therefore reads one session at a time, only for an idle session with a last
// message, and only once for each last message: a session whose message has not
// changed since it was read is not read again, and one that said something new is
// read afresh, since it may have changed files.
//
// The scan keeps a small value for each session and never the review itself, so
// memory holds a verdict and not forty kilobytes of hunks for each session.
//
// The scan is pure and holds no clock: the caller hands it the time.
//
// ## Flow
//
// `candidates` names the idle sessions with a message; `due` picks the one to read
// next; `started` records that its read is out and `answered` records what it
// found; `reviewing` names the sessions listed under "To review" and `stat` gives
// the size of one session's change.

/// A review's counts, as the pane words them.
public struct ReviewStat: Sendable, Equatable {
    public let files: Int
    public let added: Int
    public let removed: Int

    public init(files: Int, added: Int, removed: Int) {
        self.files = files
        self.added = added
        self.removed = removed
    }
}

/// What the scan knows of each session's worktree.
public struct ReviewScan: Sendable, Equatable {
    /// How long a read may be out before the scan stops waiting for it, in
    /// milliseconds. The daemon's own read gives up after 14 seconds.
    public static let staleMs = 30_000

    /// How many times one message's read is tried when it keeps failing.
    public static let maxAttempts = 3

    /// The words the daemon refuses a read with when the credential has spent its
    /// allowance of workspace reads. Such a refusal says nothing about the session,
    /// so it is not counted as an attempt.
    public static let busyWords = "too many workspace reads; try again shortly"

    /// Why a read did not answer.
    public enum Failure: Error, Sendable, Equatable {
        /// The credential's allowance is spent.
        case busy
        /// The principal may not read this session's worktree; the scan then reads
        /// no more of that session. The daemon decides by session, so the same
        /// principal may be an operator on another.
        case forbidden
        /// Any other failure.
        case failed

        /// Classifies a refusal by its code and the daemon's words.
        public init(code: String?, message: String) {
            if code == "forbidden" {
                self = .forbidden
            } else if message.contains(ReviewScan.busyWords) {
                self = .busy
            } else {
                self = .failed
            }
        }
    }

    /// What a successful read found for one message.
    struct Verdict: Sendable, Equatable {
        let message: String
        let changed: Bool
        let stat: ReviewStat
    }

    /// What is outstanding for a session beside its verdict.
    enum Pending: Sendable, Equatable {
        case none
        /// A read is out, begun at `since`. `failed` counts the failures of this
        /// message before it began.
        case reading(message: String, since: Int, failed: Int)
        case failed(message: String, attempts: Int)
    }

    /// A verdict outlives everything that happens after it, since only a read that
    /// answered replaces one. A session does not move between "To review" and
    /// "Waiting" because the daemon was busy.
    struct Seen: Sendable, Equatable {
        var verdict: Verdict?
        var pending: Pending
    }

    private(set) var seen: [String: Seen] = [:]

    /// The sessions whose worktree the daemon refused this principal. A refused
    /// session is neither read again nor listed under "To review", as a page that
    /// cannot read a worktree has no such row; other sessions are unaffected.
    public private(set) var forbidden: Set<String> = []

    public init() {}

    // MARK: Candidates

    /// The idle sessions with a last message, as identity and message, in the order
    /// the threads are listed: the sessions whose tree could be reviewed.
    public static func candidates(threads: [InboxThread]) -> [(session: String, message: String)] {
        threads.compactMap { thread in
            guard InboxRule.kind(of: thread) == .waiting, let activity = thread.activity,
                  let message = InboxRule.said(activity)
            else { return nil }
            return (thread.id, message)
        }
    }

    // MARK: The next read

    /// The one session to read next, or nil when none is due or a read is still
    /// out. A session with fewer attempts goes first.
    public func due(_ candidates: [(session: String, message: String)], now: Int) -> (session: String, message: String)? {
        // A read that is out and not stale holds the line.
        let busy = seen.values.contains { entry in
            if case .reading(_, let since, _) = entry.pending { return now - since < Self.staleMs }
            return false
        }
        if busy { return nil }

        let due = candidates.compactMap { candidate -> (attempts: Int, candidate: (session: String, message: String))? in
            if forbidden.contains(candidate.session) { return nil }
            return attempts(of: seen[candidate.session], message: candidate.message).map { ($0, candidate) }
        }
        // The sort is stable by candidate order for equal attempts.
        return due.enumerated().min { left, right in
            (left.element.attempts, left.offset) < (right.element.attempts, right.offset)
        }?.element.candidate
    }

    /// How many attempts the session's message has had, when it is due another: none
    /// for a message never read, and the count so far for a failed one with tries
    /// left. A message that was read, is being read or has used its tries is not due.
    private func attempts(of held: Seen?, message: String) -> Int? {
        guard let held else { return 0 }
        if let verdict = held.verdict, verdict.message == message { return nil }
        switch held.pending {
        case .none: return 0
        case .reading(let read, _, _): return read != message ? 0 : nil
        case .failed(let read, let attempts):
            if read != message { return 0 }
            return attempts < Self.maxAttempts ? attempts : nil
        }
    }

    /// Records that a read of `session` is out for `message`.
    public mutating func started(_ session: String, message: String, now: Int) {
        seen[session] = Seen(
            verdict: seen[session]?.verdict,
            pending: .reading(message: message, since: now, failed: failures(session, message))
        )
    }

    /// Records what a read found. A failed read counts as one more attempt and a busy
    /// refusal as none; either leaves the session's verdict as it was.
    public mutating func answered(_ session: String, message: String, read: Result<ReviewRead, Failure>) {
        let before = seen[session]?.verdict
        switch read {
        case .success(let review):
            let stat = ReviewStat(files: review.stat.files, added: review.stat.added, removed: review.stat.removed)
            seen[session] = Seen(verdict: Verdict(message: message, changed: Self.changed(review), stat: stat), pending: .none)
        case .failure(.busy):
            // The refusal says nothing about the session: with no verdict it is as
            // if unread, and with one it keeps it.
            if before != nil { seen[session] = Seen(verdict: before, pending: .none) } else { seen[session] = nil }
        case .failure(.forbidden):
            forbidden.insert(session)
            seen[session] = Seen(verdict: before, pending: .none)
        case .failure(.failed):
            seen[session] = Seen(verdict: before, pending: .failed(message: message, attempts: failures(session, message) + 1))
        }
    }

    private func failures(_ session: String, _ message: String) -> Int {
        switch seen[session]?.pending {
        case .failed(let read, let attempts)? where read == message: return attempts
        case .reading(let read, _, let failed)? where read == message: return failed
        default: return 0
        }
    }

    /// Whether a worktree holds anything to review: a file, or a file left out. A
    /// directory that is not a checkout holds nothing.
    static func changed(_ review: ReviewRead) -> Bool {
        switch review.repository {
        case .notRepository: return false
        case .head, .unborn: return !review.files.isEmpty || review.omitted > 0
        }
    }

    // MARK: Reading the result

    /// The sessions listed under "To review": every candidate except one whose
    /// verdict for its current message says the tree is clean, and one whose
    /// worktree the daemon refused. A session not yet read is listed, since a
    /// session that moved to "Waiting" only to jump back when its turn came would
    /// shuffle the list.
    public func reviewing(_ candidates: [(session: String, message: String)]) -> Set<String> {
        Set(candidates.compactMap { candidate in
            if forbidden.contains(candidate.session) { return nil }
            if let verdict = seen[candidate.session]?.verdict, verdict.message == candidate.message, !verdict.changed {
                return nil
            }
            return candidate.session
        })
    }

    /// The size a session's last read counted, for the message it was read for and
    /// no other. Nil for a session not yet read, read at an older message, or whose
    /// tree is clean.
    public func stat(_ session: String, message: String) -> ReviewStat? {
        guard let verdict = seen[session]?.verdict, verdict.message == message, verdict.changed else { return nil }
        return verdict.stat
    }

    /// Whether the session's current message has no verdict yet, which the pane
    /// words as being checked.
    public func isChecking(_ session: String, message: String) -> Bool {
        guard let verdict = seen[session]?.verdict else { return true }
        return verdict.message != message
    }
}
