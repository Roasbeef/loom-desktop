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
// `Notices.plan` takes the board the notifier saw last (nil before the first read)
// and the board it sees now. A row that is new in the second and is one of the four
// kinds becomes a `Notice` to post. An identifier that was open in the first and is
// not in the second goes in `remove`, because its item was answered, decided,
// retried or dismissed, or changed into something that no longer needs the owner.
// `Notices.content` words one row.
//
// ## What a notice says
//
// A notice never decides anything: it opens the thread and nothing more, since an
// approval is decided only beside its evidence. Its title is the app's own words
// for the kind. Whatever a session wrote (an ask's question, a command an approval
// requests) is the body, and the body says whose words they are, so a notice is
// never read as the app speaking. The session's name is the subtitle.

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

    /// The identifier of a row's notice, or nil for a kind that has none.
    public static func identifier(of row: InboxRow) -> String? {
        switch row.kind {
        case .approval, .failed, .ask, .stuck: return "\(row.kind.chip.lowercased())/\(row.id)"
        case .review, .waiting, .working, .quiet, .find: return nil
        }
    }

    /// Compares two boards. `previous` is nil before the first read, which is a
    /// backlog and not news, so it posts nothing and removes nothing.
    ///
    /// `authority` gives the line an approval's card requests, when the session's
    /// card has been read, since the board's own line for an approval is the
    /// session's last message.
    ///
    /// ## Examples
    ///
    /// A board with one new ask against an empty one posts one notice; the same
    /// board twice posts none; the empty board against the first removes it.
    public static func plan(
        previous: InboxBoard?, next: InboxBoard, authority: (InboxRow) -> String? = { _ in nil }
    ) -> NoticePlan {
        guard let previous else { return NoticePlan(post: [], remove: []) }
        let before = Set(previous.rows.compactMap(identifier(of:)))
        let after = Set(next.rows.compactMap(identifier(of:)))
        let post = next.rows.compactMap { row -> Notice? in
            guard let id = identifier(of: row), !before.contains(id) else { return nil }
            return content(of: row, identifier: id, authority: authority(row))
        }
        return NoticePlan(post: post, remove: before.subtracting(after).sorted())
    }

    /// Words one row's notice. Only the quoted part is session text.
    static func content(of row: InboxRow, identifier: String, authority: String?) -> Notice {
        let title: String
        let body: String
        switch row.kind {
        case .approval:
            title = "Approval waiting"
            body = authority.map { "Requests, untrusted text from the agent: \(quote($0))" }
                ?? "Open the thread to read what it asks for."
        case .ask:
            title = "Asks you a question"
            body = "Untrusted text from the agent: \(quote(row.head))"
        case .stuck:
            // The head is the daemon's own account of why the strand stopped.
            title = "Strand stuck"
            body = row.head
        case .failed, .review, .waiting, .working, .quiet, .find:
            title = "Run failed"
            body = "The last run failed. Open the thread to read why."
        }
        return Notice(
            identifier: identifier, thread: row.sessionID, subject: row.subject,
            title: title, subtitle: row.name, body: body
        )
    }

    /// One line of session text, cut to `quoteCharacters`.
    static func quote(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count > quoteCharacters else { return line }
        return String(line.prefix(quoteCharacters - 1)) + "\u{2026}"
    }
}
