import Foundation
import LoomKit

// What the app tells the owner outside its window, decided as data. A notice exists
// for the same items the inbox counts under "Needs you": an approval, an ask, a
// stuck strand and a failed run. The decision is a diff of one `InboxBoard` against
// the next, so a notice cannot disagree with the count on the Dock tile, and the
// adapter that talks to the system's notification center has nothing left to
// decide: it posts what `plan` lists, removes what it lists, and opens the thread
// of a notice that was clicked.
//
// ## Flow
//
// `Notices.plan` takes the board the notifier saw last (`InboxBoard.empty` before
// anything was read) and the board it sees now. A row that is new in the second and
// is one of the four kinds becomes a `Notice` to post, unless the first board
// cannot vouch that the row is news (see "What counts as news"). An identifier that
// was open in the first and is not in the second goes in `remove`, because its
// item was answered, decided, retried or dismissed, or changed into something that
// no longer needs the owner. `Notices.notice` words one row and is nil for the kinds
// that have no notice, so the four kinds are listed once.
//
// ## What counts as news
//
// A row is news only when its session had a row on the previous board, and an ask
// or a stuck strand only when the previous board had also read that session's
// attention feed (`InboxBoard.checked`). That makes the backlog a property of the
// two boards and not of a flag in the adapter: a second daemon that connects later,
// a remote that becomes reachable while the app is in the background, and a feed
// read that lands after the session list all arrive as sessions or feed entries the
// previous board lacked, so none posts its backlog. The cost is that an ask raised
// before a new session's first feed read is taken as backlog and never notified.
//
// One approval is one row per session, so a second approval on a session that
// already has one waiting posts no notice, and an approval decided and replaced by a
// new one inside one poll interval looks unchanged and does not post again.
//
// ## What a notice says
//
// A notice never decides anything: it opens the thread and nothing more, since an
// approval is decided only beside its evidence. Its title is the app's own words
// for the kind. Whatever a session wrote (an ask's question, a command an approval
// requests) is the body, and the body says whose words they are, so a notice is
// never read as the app speaking. The session's name is the subtitle. A session's
// title can be derived from what an agent wrote, and the subtitle shows it bare, as
// the menu bar and the inbox already do.

/// One notification to deliver.
public struct Notice: Sendable, Equatable {
    /// Names the notice for removal. It carries the kind, so a session whose approval
    /// is decided and whose next run then fails gets a second notice rather than none.
    public let identifier: String
    /// One identifier per session, so the system groups a session's notices.
    public let thread: String
    /// The thread a click opens.
    public let subject: InboxSubject
    /// The app's own words for what happened.
    public let title: String
    /// The session's name.
    public let subtitle: String
    /// Session-written text is labelled as such here.
    public let body: String
}

/// What to do after a board changed.
public struct NoticePlan: Sendable, Equatable {
    /// Notices to deliver, in the order the board draws their rows.
    public let post: [Notice]
    /// Identifiers whose item no longer needs the owner, to remove wherever they
    /// have been delivered.
    public let remove: [String]

    /// Nothing to do.
    public var isEmpty: Bool { post.isEmpty && remove.isEmpty }
}

public enum Notices {
    /// The longest stretch of session text a notice carries, in characters.
    public static let quoteCharacters = 140

    /// Compares two boards. A notice is posted only for a row that is news, as the
    /// header says, and removed when its identifier left the board.
    ///
    /// ## Examples
    ///
    /// A board with one new ask against one that had read the session's feed and
    /// held none posts one notice; the same board twice posts none; the empty board
    /// against the first removes it.
    public static func plan(previous: InboxBoard, next: InboxBoard) -> NoticePlan {
        let before = Set(previous.rows.compactMap(notice(of:)).map(\.identifier))
        let known = Set(previous.rows.map(\.sessionID))
        let post = next.rows.compactMap { row -> Notice? in
            guard let notice = notice(of: row), !before.contains(notice.identifier) else { return nil }
            guard known.contains(row.sessionID) else { return nil }
            switch row.kind {
            case .ask, .stuck: return previous.checked.contains(row.sessionID) ? notice : nil
            default: return notice
            }
        }
        let after = Set(next.rows.compactMap(notice(of:)).map(\.identifier))
        return NoticePlan(post: post, remove: before.subtracting(after).sorted())
    }

    /// The notice a row makes, or nil for a kind that has none. Only the quoted part
    /// is session text.
    public static func notice(of row: InboxRow) -> Notice? {
        let kind: String
        let title: String
        let body: String
        switch row.kind {
        case .approval:
            kind = "approval"
            title = "Approval waiting"
            body = "Open the thread to read what it asks for."
        case .ask:
            kind = "ask"
            title = "Asks you a question"
            body = "Untrusted text from the agent: \(quote(row.head))"
        case .stuck:
            // The head is the daemon's own account of why the strand stopped.
            kind = "stuck"
            title = "Strand stuck"
            body = row.head
        case .failed:
            kind = "failed"
            title = "Run failed"
            body = "The last run failed. Open the thread to read why."
        case .review, .waiting, .working, .quiet, .find:
            return nil
        }
        return Notice(
            identifier: "\(kind)/\(row.id)", thread: row.sessionID, subject: row.subject,
            title: title, subtitle: row.name, body: body
        )
    }

    /// One line of session text with control and bidirectional scalars made visible,
    /// cut to `quoteCharacters`.
    static func quote(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let line = Escalation.escapeForDisplay(flat)
        guard line.count > quoteCharacters else { return line }
        return String(line.prefix(quoteCharacters - 1)) + "\u{2026}"
    }
}
