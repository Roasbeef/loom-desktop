import Foundation
import LoomKit

// The rule that sorts what the daemon says into the attention inbox: which group a
// thread belongs to, what the chip on its row says, how a group is ordered, how
// old a row is, what each folder in the rail counts, and which thread the list
// opens on. It mirrors the web view's rule, so the same session sits in the same
// group on both clients (loom packages/web_view/src/web_view/inbox_rule.gleam,
// attention_rule.gleam, thread_words.gleam, and the folder counts in home.gleam).
//
// The rule is pure. It reads no clock and draws nothing: the caller hands it the
// time it read the daemon at, so a test states every decision with a fixed `now`.
//
// ## Flow
//
// `InboxRule.board` is the one entry point the app reads: it turns threads and feed
// rows into rows with `rows`, puts them in groups with `sections`, counts them with
// `tally`, and keeps the three together as an `InboxBoard`. Every surface that
// shows a number or a list of what needs the owner (the Inbox's badge, the window's
// subtitle, the Dock badge, the menu bar, the notifier, "Next Session Needing You",
// Mission Control's Needs You block, the sidebar's Needs You group and the inbox
// itself) reads that one board, so two surfaces cannot disagree. `folderEntries`,
// `visible` and `shownFolder` decide what the rail offers and what the list draws;
// `selection` names the open thread; `headline` and `countNote` say what the counts
// read.
//
// "Needs you" counts approvals, asks, stuck strands and failed runs, which are the
// rows the web's "Needs you" band draws. An unhealthy machine is not one of them:
// the web classifier has no such kind, so this app does not count it. The inbox
// still lists a sick machine in a "Machines" section of its own, which the board
// does not carry and no count includes.
//
// ## Where this departs from the web
//
// - No Projects folder and no ticket rows: this app has no project boards.
// - Saved sessions are counted, not listed. The web counts each from the catalogue's
//   summary (loom protocol-change/122) and draws a row for each one that holds
//   something open, with a Resume button. Here `sessions.saved_attention` feeds the
//   counts, the headline and the rail note (`InboxSaved`), and a saved session gets
//   no row of its own. Against a daemon that does not know the command, or before
//   the first read, the notes keep saying saved sessions are not checked.
// - A "To review" group exists for the sessions the caller names in `reviewing`.
//   The web decides that by reading each idle session's worktree, and `ReviewScan`
//   does the same here, so an idle session with something to say sits in
//   "Waiting" only once a read has found its tree clean.
// - A quiet session that has any feed row (an ask, a stuck strand or a find) is not
//   folded. The web folds it as well as listing the item, so the same session sits
//   under "Needs you" and again under "Folded", whose gloss says no one is waiting.
//   Here its feed rows stand alone and its quiet row is dropped. This departs from
//   the web until the same fix lands in Loom.

/// What a thread is about, which the chip on its row says.
public enum InboxKind: Sendable, Equatable {
    /// An approval is pending. It is decided on the session's own page or in place.
    case approval
    /// The main strand's last run failed and nothing is running or pending.
    case failed
    /// A finished session whose worktree is to be read.
    case review
    /// Idle with a last message.
    case waiting
    /// Working now.
    case working
    /// Idle with nothing said.
    case quiet
    /// An open ask routed to the owner.
    case ask
    /// A strand that stopped on a failed run.
    case stuck
    /// An open find, by what the agent calls it.
    case find(FindKind)

    /// The word on the row's chip.
    public var chip: String {
        switch self {
        case .approval: return "Approval"
        case .failed: return "Failed"
        case .review: return "Review"
        case .waiting: return "Waiting"
        case .working: return "Update"
        case .quiet: return "Quiet"
        case .ask: return "Ask"
        case .stuck: return "Stuck"
        case .find(let kind): return kind.rawValue.capitalized
        }
    }
}

/// The groups the inbox lists, in the order it draws them. The same order and
/// words as the web view's list; `finds` sits between "Waiting" and "Updates".
public enum InboxGroup: Int, Sendable, CaseIterable, Comparable {
    case needsYou, toReview, waiting, finds, updates, quiet

    public static func < (lhs: InboxGroup, rhs: InboxGroup) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The heading a group is drawn under. The quiet group is folded to one line
    /// of names, under the heading "Folded".
    public var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .toReview: return "To review"
        case .waiting: return "Waiting"
        case .finds: return "Finds"
        case .updates: return "Updates"
        case .quiet: return "Folded"
        }
    }

    /// The few words at the right of the band that say what the group holds.
    public var gloss: String {
        switch self {
        case .needsYou: return "agents stopped for you"
        case .toReview, .waiting: return "finished, waiting on your read"
        case .finds: return "noticed outside the task"
        case .updates: return "working, nothing asked; message them here"
        case .quiet: return "no one is waiting on you"
        }
    }
}

/// The folders of the rail. A folder narrows the list and tells the daemon
/// nothing.
public enum InboxFolder: Sendable, CaseIterable, Equatable, Hashable {
    case everything, needing, reviewing, finding, updating

    /// The words of a folder: "Everything, by need" for the one that shows every
    /// group, and the group's own name for the others.
    public var title: String {
        switch self {
        case .everything: return "Everything, by need"
        case .needing: return "Needs you"
        case .reviewing: return "To review"
        case .finding: return "Finds"
        case .updating: return "Updates"
        }
    }

    /// The group a folder shows, or nil for the folder that shows all of them.
    var group: InboxGroup? {
        switch self {
        case .everything: return nil
        case .needing: return .needsYou
        case .reviewing: return .toReview
        case .finding: return .finds
        case .updating: return .updates
        }
    }
}

/// What a row opens: a session's thread, or one record of the attention feed.
public enum InboxSubject: Sendable, Equatable, Hashable, Codable {
    case session(String)
    case ask(session: String, id: String)
    case stuck(session: String, strand: String)
    case find(session: String, id: String)

    /// The session the thread belongs to.
    public var sessionID: String {
        switch self {
        case .session(let id): return id
        case .ask(let session, _), .stuck(let session, _), .find(let session, _): return session
        }
    }

    /// A stable string for a selection and an accessibility name. The kind leads,
    /// so an ask and a stuck strand that share a text are never taken for each other.
    public var key: String {
        switch self {
        case .session(let id): return "session/\(id)"
        case .ask(let session, let id): return "ask/\(session)/\(id)"
        case .stuck(let session, let strand): return "stuck/\(session)/\(strand)"
        case .find(let session, let id): return "find/\(session)/\(id)"
        }
    }
}

/// How long a row has waited, in the short words the row's right edge carries.
public struct InboxAge: Sendable, Equatable {
    /// `now`, `40m`, `1h 22m` or `3d`.
    public let words: String
    /// A wait of an hour or more, which the row marks.
    public let isOverdue: Bool
}

/// One session as the inbox reads it: the display name beside what the daemon's
/// activity read said. `activity` is nil when the daemon gave no usable report,
/// and the session then has no thread of its own, though its feed items still list.
public struct InboxThread: Sendable, Equatable {
    public let id: String
    public let name: String
    public let activity: SessionActivity?

    public init(id: String, name: String, activity: SessionActivity?) {
        self.id = id
        self.name = name
        self.activity = activity
    }
}

/// One row of the list.
public struct InboxRow: Sendable, Equatable, Identifiable {
    public let subject: InboxSubject
    public let kind: InboxKind
    public let group: InboxGroup
    /// The session's name, which a feed row does not carry.
    public let name: String
    /// What a session thread is ordered by: the session's own name, untrimmed and
    /// as the catalogue holds it, which is what the web view orders by. It is not
    /// the shown name, which trims and fills in an empty one, so an unnamed session
    /// is listed where the web lists it.
    let sortName: String
    /// The one line under the name. Model text for an ask, a find and a message.
    public let head: String
    /// Nil when the record has no time, and the row then says none: a time is
    /// never made up.
    public let age: InboxAge?
    /// When the wait began, in Unix milliseconds, from the daemon's own record.
    /// Ordering a feed item reads it, so the order needs no clock.
    public let since: Int?
    public var id: String { subject.key }
    public var sessionID: String { subject.sessionID }

    init(
        subject: InboxSubject, kind: InboxKind, group: InboxGroup, name: String, sortName: String? = nil, head: String,
        since: Int?, now: Int
    ) {
        self.subject = subject
        self.kind = kind
        self.group = group
        self.name = name
        self.sortName = sortName ?? name
        self.head = head
        self.since = since

        // A find waits on no one, so its age is never marked as long.
        let age = InboxRule.age(since: since, now: now)
        if case .find = kind {
            self.age = age.map { InboxAge(words: $0.words, isOverdue: false) }
        } else {
            self.age = age
        }
    }
}

/// A group with its rows, ready to draw.
public struct InboxSection: Sendable, Equatable {
    public let group: InboxGroup
    public let rows: [InboxRow]
    public var title: String { group.title }
    public var gloss: String { group.gloss }
    public var count: Int { rows.count }
}

/// What the headline counts.
public struct InboxTally: Sendable, Equatable {
    /// Approvals, asks, stuck strands and failed runs that need the owner.
    public var needing = 0
    /// Open finds.
    public var finds = 0
    /// Running sessions the counts looked at.
    public var running = 0
    /// Running sessions no feed row was read for, and saved sessions the catalogue
    /// has no summary for. The saved ones count only once at least one saved session
    /// was read, as the web counts them, since until then the line says saved
    /// sessions are not checked at all.
    public var unread = 0
    /// Saved sessions counted from the catalogue's summary.
    public var fromCatalogue = 0
}

/// What the inbox knows of the sessions that are not running.
public enum InboxSaved: Sendable, Equatable {
    /// No read answered, or the daemon does not know `sessions.saved_attention`.
    case unchecked
    /// The saved sessions the list holds, and the rows the catalogue read for them. A
    /// listed session with no row was not read, which is not the same as zero.
    case read(listed: [String], rows: [String: SavedAttention])
}

/// Everything the app shows about what needs the owner, decided once. The rows, the
/// groups they sit in and the counts come from one call to `InboxRule.board`, so
/// the badges, the subtitle, the Dock tile, the menu bar, the notifier, the jump to
/// the next session, Mission Control, the sidebar and the inbox read the same
/// values and cannot differ.
public struct InboxBoard: Sendable, Equatable {
    /// The groups that hold any row, in the order the inbox draws them.
    public let sections: [InboxSection]
    /// The counts the headline reads, which include the saved sessions the catalogue
    /// summarised.
    public let tally: InboxTally
    /// How many threads the daemon gave a usable report for.
    public let reported: Int
    /// The sessions the attention feed has answered for, which may hold no item. A
    /// session outside this set has not had its asks and stuck strands read, which is
    /// not the same as having none, so the notifier does not take a first read as news.
    public let checked: Set<String>

    /// The board of nothing read yet.
    public static let empty = InboxBoard(sections: [], tally: InboxTally(), reported: 0, checked: [])

    init(sections: [InboxSection], tally: InboxTally, reported: Int, checked: Set<String> = []) {
        self.sections = sections
        self.tally = tally
        self.reported = reported
        self.checked = checked
    }

    /// Every row, in the order the groups are drawn.
    public var rows: [InboxRow] { sections.flatMap(\.rows) }

    /// How many things wait on the owner: approvals, asks, stuck strands and failed
    /// runs, on running sessions and in the saved sessions' summaries.
    public var needing: Int { tally.needing }

    /// The rows of the "Needs you" group, in the order it is drawn. A saved session
    /// is counted in `needing` and has no row, so this can be shorter than the count.
    public var needsYou: [InboxRow] { sections.first { $0.group == .needsYou }?.rows ?? [] }

    /// The sessions with a row under "Needs you", in the group's order and each once.
    /// The sidebar's Needs You group and "Next Session Needing You" both read it.
    public var needingSessions: [String] {
        var seen: Set<String> = []
        return needsYou.map(\.sessionID).filter { seen.insert($0).inserted }
    }

    /// The window subtitle: how many things wait, or nothing when none do.
    public var subtitle: String { needing == 0 ? "" : "\(needing) waiting" }

    /// The words on the Dock tile, or nil when nothing waits.
    public var dockLabel: String? { needing == 0 ? nil : "\(needing)" }

    /// The same board with every row's age counted to `now`. The counts and groups
    /// do not depend on the clock, so only the ages move.
    public func aged(now: Int) -> InboxBoard {
        InboxBoard(
            sections: sections.map { InboxSection(group: $0.group, rows: $0.rows.map { $0.aged(now: now) }) },
            tally: tally, reported: reported, checked: checked
        )
    }
}

public enum InboxRule {
    /// The longest head, in characters, including the ellipsis a cut head ends in.
    public static let headCharacters = 120

    /// A wait of this many milliseconds is marked on a row as long: an hour.
    public static let overdueAfterMs = 3_600_000

    // MARK: Kind and group

    /// The kind of thread a session's report makes, or nil when the daemon gave no
    /// usable report. `needs_you` with no approval pending is a failed run, since
    /// the daemon reports both under one word and the count tells them apart.
    public static func kind(of thread: InboxThread, reviewing: Set<String> = []) -> InboxKind? {
        guard let activity = thread.activity else { return nil }
        switch activity.state {
        case .needsYou: return activity.approvals > 0 ? .approval : .failed
        case .working: return .working
        case .idle:
            guard said(activity) != nil else { return .quiet }
            // Only an idle session that said something moves to review.
            return reviewing.contains(thread.id) ? .review : .waiting
        case .unknown: return nil
        }
    }

    static func group(of kind: InboxKind) -> InboxGroup {
        switch kind {
        case .approval, .failed, .ask, .stuck: return .needsYou
        case .review: return .toReview
        case .waiting: return .waiting
        case .find: return .finds
        case .working: return .updates
        case .quiet: return .quiet
        }
    }

    // MARK: Words

    /// The last message when it has words in it. A message of whitespace is no
    /// message, so the session is not offered as having said something.
    public static func said(_ activity: SessionActivity) -> String? {
        guard let text = activity.lastMessage, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The name a thread is drawn under: its own, or "Session " and the first eight
    /// characters of its identity when it has none.
    public static func shownName(_ thread: InboxThread) -> String {
        let named = thread.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return named.isEmpty ? "Session " + String(thread.id.prefix(8)) : named
    }

    /// A session thread's one line: the first line of the last message that has
    /// words, else the newest glance's summary, else the session's name, so a row
    /// never reads as a bare kind word that names no session. The line is cut to
    /// `headCharacters` characters, ending in an ellipsis within that count.
    public static func threadHead(_ thread: InboxThread) -> String {
        if let activity = thread.activity {
            if let message = said(activity), let line = message.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) {
                return cut(oneLine(line))
            }
            if let summary = activity.glances.first?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                return cut(summary)
            }
        }
        return cut(shownName(thread))
    }

    /// The threads with each session once, the first listing winning. A session two
    /// daemons both list would otherwise be two rows, and the list's order, which Next
    /// and Previous step through, would hold one selection twice.
    public static func deduped(_ threads: [InboxThread]) -> [InboxThread] {
        var seen: Set<String> = []
        return threads.filter { seen.insert($0.id).inserted }
    }

    /// Text on one line: every run of whitespace, newlines of any kind included,
    /// becomes one space. The daemon's `last_message` can hold newlines, so a digest or
    /// a row that must stay on one line reads it through this. A detail view keeps the
    /// text as written.
    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cuts a line to `headCharacters` grapheme clusters, so a combined character
    /// is never split, and a cut line ends in an ellipsis inside that count.
    public static func cut(_ line: String) -> String {
        guard line.count > headCharacters else { return line }
        return String(line.prefix(headCharacters - 1)) + "\u{2026}"
    }

    /// How long a wait has gone on, as a row's age says it: "now" under a minute,
    /// minutes alone under an hour, hours and minutes under a day, then days.
    public static func shortAge(_ waitMs: Int) -> String {
        let minutes = waitMs / 60_000
        if waitMs < 60_000 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if waitMs < 86_400_000 { return "\(minutes / 60)h " + String(format: "%02d", minutes % 60) + "m" }
        return "\(waitMs / 86_400_000)d"
    }

    static func age(since: Int?, now: Int) -> InboxAge? {
        guard let since else { return nil }
        let wait = now - since
        return InboxAge(words: shortAge(wait), isOverdue: wait >= overdueAfterMs)
    }

    /// The failures a stuck strand's reason code names. The table is closed: any
    /// other code is `other`, so a reason the client was not told about is not
    /// worded.
    enum Failure {
        case rateLimited, overloaded, timedOut, other

        init(reason: String?) {
            switch reason {
            case "rate_limited": self = .rateLimited
            case "overloaded": self = .overloaded
            case "timeout": self = .timedOut
            default: self = .other
            }
        }
    }

    /// A stuck row's one line: what stopped it, and when when the daemon could read
    /// the time. `clock` words an instant as a time of day.
    public static func stuckHead(_ stuck: AttentionStuck, clock: (Int) -> String) -> String {
        func timed(_ lead: String) -> String {
            stuck.failedAt.map { "\(lead) at \(clock($0)), has not retried" } ?? "\(lead), has not retried"
        }
        switch Failure(reason: stuck.reason) {
        case .rateLimited: return timed("Rate-limited")
        case .overloaded: return timed("Provider overloaded")
        case .timedOut: return timed("Provider timed out")
        case .other: return "Stopped on a failed run"
        }
    }

    // MARK: Feed reads

    /// The feed rows to keep after one read. The daemon may leave a resident session
    /// out of an answer, and the client treats that as not read rather than as empty,
    /// so a session that is still resident and missing from this read keeps its last
    /// row. A session that is no longer resident keeps none.
    public static func keptFeed(
        previous: [String: AttentionRow], read: [String: AttentionRow], resident: [String]
    ) -> [String: AttentionRow] {
        var kept = read.filter { resident.contains($0.key) }
        for session in resident where kept[session] == nil {
            if let old = previous[session] { kept[session] = old }
        }
        return kept
    }

    // MARK: Raise times

    /// The raise time of each session's oldest pending approval after a refresh.
    /// A session that still has approvals keeps the time it had when this refresh's
    /// `approval.read` did not answer (the daemon allows a credential only so many
    /// reads), so one refused read does not drop a row's age until the next one. A
    /// session with no approval left keeps no time, and a time read now replaces the
    /// one before it.
    public static func raisedTimes(previous: [String: Int], read: [String: Int], approving: Set<String>) -> [String: Int] {
        previous.filter { approving.contains($0.key) }.merging(read) { _, new in new }
    }

    // MARK: Rows

    /// Every row the inputs make, in no particular order: one for each session
    /// with a report, and one for each ask, stuck strand and find a feed row holds.
    ///
    /// - `feed` holds only the rows the daemon read. A session with no entry is not
    ///   checked, which is not the same as having nothing open.
    /// - `raised` is when each session's oldest pending approval was raised
    ///   (`approval.read`). An approval with no entry has no age: an approval is
    ///   never aged from a record that carries no raise time.
    /// - `reviewing` names the idle sessions listed under "To review".
    public static func rows(
        threads: [InboxThread],
        feed: [String: AttentionRow],
        raised: [String: Int] = [:],
        reviewing: Set<String> = [],
        now: Int,
        clock: (Int) -> String = ClockTime.local
    ) -> [InboxRow] {
        var rows: [InboxRow] = []
        for thread in threads {
            // A quiet session with a feed row waits on someone or has said something
            // worth a line, so it is not folded under a gloss that says no one waits.
            let hasFeedRow = feed[thread.id].map { !$0.asks.items.isEmpty || !$0.stuck.items.isEmpty || !$0.finds.items.isEmpty } ?? false
            if let kind = kind(of: thread, reviewing: reviewing), let activity = thread.activity, !(kind == .quiet && hasFeedRow) {
                rows.append(InboxRow(
                    subject: .session(thread.id), kind: kind, group: group(of: kind),
                    name: shownName(thread), sortName: thread.name, head: threadHead(thread),
                    since: sessionSince(kind: kind, activity: activity, raised: raised[thread.id]), now: now
                ))
            }

            // The feed's items are listed for every running session, report or not.
            guard let row = feed[thread.id] else { continue }
            let name = shownName(thread)
            for ask in row.asks.items {
                rows.append(InboxRow(
                    subject: .ask(session: thread.id, id: ask.id), kind: .ask, group: .needsYou, name: name,
                    head: ask.head, since: ask.createdAt, now: now
                ))
            }
            for stuck in row.stuck.items {
                rows.append(InboxRow(
                    subject: .stuck(session: thread.id, strand: stuck.strand), kind: .stuck, group: .needsYou, name: name,
                    head: stuckHead(stuck, clock: clock), since: stuck.failedAt, now: now
                ))
            }
            for find in row.finds.items {
                rows.append(InboxRow(
                    subject: .find(session: thread.id, id: find.id), kind: .find(find.kind), group: .finds, name: name,
                    head: find.head, since: find.createdAt, now: now
                ))
            }
        }
        return rows
    }

    /// An approval is aged from its raise time, a finished session from the time of
    /// its last message, and a working one from the start of the turn now running.
    /// A session whose data holds no such time has none.
    private static func sessionSince(kind: InboxKind, activity: SessionActivity, raised: Int?) -> Int? {
        switch kind {
        case .approval: return raised
        case .waiting, .review: return activity.lastMessageAt
        case .working: return activity.turnStartedAt
        case .failed, .quiet, .ask, .stuck, .find: return nil
        }
    }

    // MARK: The board

    /// The inbox as one value: the rows the inputs make, grouped and ordered, and the
    /// counts over the same inputs. This is the only function the app calls to learn
    /// what needs the owner. `rows`, `sections` and `tally` stay public for the tests
    /// that state each decision on its own.
    ///
    /// - `saved` is what the catalogue said of the sessions that are not running.
    public static func board(
        threads: [InboxThread],
        feed: [String: AttentionRow],
        raised: [String: Int] = [:],
        reviewing: Set<String> = [],
        saved: InboxSaved = .unchecked,
        now: Int,
        clock: (Int) -> String = ClockTime.local
    ) -> InboxBoard {
        InboxBoard(
            sections: sections(rows(threads: threads, feed: feed, raised: raised, reviewing: reviewing, now: now, clock: clock)),
            tally: tally(threads: threads, feed: feed, saved: saved),
            reported: threads.filter { $0.activity != nil }.count,
            checked: Set(feed.keys)
        )
    }

    // MARK: Groups

    /// The rows collected into the groups that hold any, in the order the inbox
    /// draws them. A group with no row is not listed, so no empty header is drawn.
    ///
    /// Within "Needs you" the asks and stuck strands come first, the longest wait
    /// first and an unknown time last, then the sessions with an approval pending or
    /// a failed run by name. Finds are ordered by wait too. Every other group is by
    /// name. Every order ends in the session and the identity, so two reads of the
    /// same rows list the same order.
    public static func sections(_ rows: [InboxRow]) -> [InboxSection] {
        InboxGroup.allCases.compactMap { group in
            let members = rows.filter { $0.group == group }.sorted(by: order)
            return members.isEmpty ? nil : InboxSection(group: group, rows: members)
        }
    }

    /// Whether `left` is listed before `right` within one group.
    private static func order(_ left: InboxRow, _ right: InboxRow) -> Bool {
        let leftItem = left.isFeedItem, rightItem = right.isFeedItem
        if leftItem != rightItem { return leftItem }
        if leftItem {
            // The longer wait first: its start is the smaller time. A row with no
            // time is last.
            switch (left.since, right.since) {
            case (let a?, let b?) where a != b: return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            return precedes(left.sessionID, right.sessionID, then: left.subject.key, right.subject.key)
        }
        return precedes(left.sortName, right.sortName, then: left.sessionID, right.sessionID)
    }

    /// Byte order on the first pair, then on the second, as the web view's string
    /// comparison orders them, so capitals sort before lower case.
    private static func precedes(_ a: String, _ b: String, then c: String, _ d: String) -> Bool {
        if a != b { return a.utf8.lexicographicallyPrecedes(b.utf8) }
        return c.utf8.lexicographicallyPrecedes(d.utf8)
    }

    // MARK: Folders

    /// The folders the rail offers and their counts. "Everything, by need" is
    /// always first and carries no count; each other folder is offered only while
    /// its group holds a row, and its count is the number of rows its band draws.
    public static func folderEntries(_ sections: [InboxSection]) -> [(folder: InboxFolder, count: Int?)] {
        [(InboxFolder.everything, nil)] + [InboxFolder.needing, .reviewing, .finding, .updating].compactMap { folder in
            let count = sections.first { $0.group == folder.group }?.count ?? 0
            return count > 0 ? (folder, count) : nil
        }
    }

    /// The folder the list is narrowed to: the chosen one while its group holds a
    /// row, and "Everything, by need" once it has emptied, so a list never draws as
    /// blank under a folder the rail no longer offers.
    public static func shownFolder(chosen: InboxFolder, sections: [InboxSection]) -> InboxFolder {
        folderEntries(sections).contains { $0.folder == chosen } ? chosen : .everything
    }

    /// The sections a folder draws. "Everything, by need" draws every group; any
    /// other folder draws its own. "Waiting" and the folded quiet line have no
    /// folder of their own, so they show only under "Everything, by need".
    public static func visible(_ sections: [InboxSection], in folder: InboxFolder) -> [InboxSection] {
        guard let group = folder.group else { return sections }
        return sections.filter { $0.group == group }
    }

    // MARK: Selection

    /// The row the reading pane shows: the chosen one when the visible sections
    /// still hold it, and otherwise the first row of the first section. A stale
    /// choice falls back to the first row, so the pane is never empty while rows
    /// exist. The folded quiet line is names and not rows, so it holds no thread.
    public static func selection(_ sections: [InboxSection], chosen: InboxSubject?) -> InboxSubject? {
        let selectable = sections.filter { $0.group != .quiet }.flatMap(\.rows)
        if let chosen, selectable.contains(where: { $0.subject == chosen }) { return chosen }
        return selectable.first?.subject
    }

    // MARK: What the counts read

    /// The counts the headline reads. A running session with a feed row counts its
    /// asks and stuck strands as the row reports them, which may be more than the
    /// row had room to list, and one approval, or one failed run, when its activity
    /// says so. A running session with no feed row counts its approval and is
    /// marked not checked. Finds are counted apart.
    ///
    /// A saved session counts its summary's pending approvals and open asks as
    /// needing the owner and its open finds as finds, as the web does. A saved
    /// session the catalogue has no summary for is not checked. When no saved session
    /// was read at all, none of them is counted either way, and the headline keeps
    /// saying saved sessions are not checked.
    public static func tally(threads: [InboxThread], feed: [String: AttentionRow], saved: InboxSaved = .unchecked) -> InboxTally {
        var tally = InboxTally()
        for thread in threads {
            // An approval and a failed run each count one: both are a session
            // reported as needing the owner, and the feed adds its own rows.
            let approval = switch kind(of: thread) {
            case .approval?, .failed?: 1
            default: 0
            }
            tally.running += 1
            if let row = feed[thread.id] {
                tally.needing += approval + row.asks.count + row.stuck.count
                tally.finds += row.finds.count
            } else {
                tally.needing += approval
                tally.unread += 1
            }
        }
        guard case .read(let listed, let rows) = saved else { return tally }
        let found = listed.compactMap { rows[$0] }
        guard !found.isEmpty else { return tally }
        for row in found {
            tally.needing += row.pendingApprovals + row.openAsks
            tally.finds += row.openFinds
        }
        tally.fromCatalogue = found.count
        tally.unread += listed.count - found.count
        return tally
    }

    /// The first words of the headline: how many things need the owner.
    public static func lead(_ tally: InboxTally) -> String {
        switch tally.needing {
        case 0: return "Nothing needs you"
        case 1: return "1 needs you"
        case let many: return "\(many) need you"
        }
    }

    /// The line over the list: how many things need the owner, how many finds are
    /// open, and what the count read, so it never claims more than it looked at.
    /// Once saved sessions were read it says how many came from the catalogue, in
    /// the web's words; before that it says saved sessions are not checked.
    public static func headline(_ tally: InboxTally) -> String {
        let finds: String
        switch tally.finds {
        case 0: finds = ""
        case 1: finds = " \u{00B7} 1 find"
        case let many: finds = " \u{00B7} \(many) finds"
        }
        let sessions = tally.running == 1 ? "1 running session" : "\(tally.running) running sessions"
        let unread = tally.unread == 0 ? "" : ", \(tally.unread) not checked"
        if tally.fromCatalogue > 0 {
            return "\(lead(tally))\(finds) \u{00B7} \(sessions) read live, \(tally.fromCatalogue) saved from the catalogue\(unread)"
        }
        return "\(lead(tally))\(finds) \u{00B7} \(sessions) read live\(unread); saved sessions not checked"
    }

    /// The note under the rail's folders: how many running sessions the counts
    /// read, and whether the saved ones were read too. `fromCatalogue` is the
    /// tally's count of saved sessions taken from the catalogue.
    public static func countNote(running: Int, fromCatalogue: Int = 0) -> String {
        let sessions = running == 1 ? "1 running session" : "\(running) running sessions"
        if fromCatalogue > 0 {
            return "Counts read \(sessions) live and each saved session from the catalogue's summary."
        }
        return "Counts read \(sessions). Saved sessions are not checked."
    }
}

extension InboxRow {
    /// The same row with its age counted to `now`.
    fileprivate func aged(now: Int) -> InboxRow {
        InboxRow(subject: subject, kind: kind, group: group, name: name, sortName: sortName, head: head, since: since, now: now)
    }

    /// Whether the row is an item of the attention feed rather than a session's
    /// own thread.
    fileprivate var isFeedItem: Bool {
        switch subject {
        case .session: return false
        case .ask, .stuck, .find: return true
        }
    }

}
