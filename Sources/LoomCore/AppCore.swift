import LoomKit
import MissionKit

/// The app's decisions that span sessions and daemons, as a value.
///
/// `AppModel` held these as observed properties changed from several places: `trackBoard`
/// recomputed the board from an observation one main-actor turn after an input changed, the
/// views wrote the inbox selection and the project selection directly, and the notifier kept
/// its own copy of the previous board. Here the shell reports the facts it holds, and one step
/// computes the board, settles the open thread, the folder and the project selection against
/// that board, plans the notices, and names what to persist, so no surface can see a board the
/// selection has not met.
///
/// ## What the shell still does
///
/// It gathers `Facts` from the daemons and sessions it owns, so an input that changes in a
/// model is reported one turn later, as the observation did. What changed is that the
/// decisions made from the facts are made in one place, in one step, and are testable.
///
/// ## Invariants
///
/// `AppCoreModelTests` checks them after every step:
///
/// - B2 the board equals `InboxRule.board` recomputed from the facts.
/// - B3 the open thread is a row the board lists, or is marked resolved, or is none, and a
///   refresh never moves it.
/// - B7 the unseen-reply mark of a session is clear while it is the place shown.
/// - N2 a notice is planned at most once per row and kind, and removed when its row leaves
///   the board.
/// - P1 every persisted value decodes to the state it came from.
/// - P2 nothing persisted carries a credential, only reply digests.
public struct AppCore: Sendable, Equatable {
    /// Where the main window is, as far as the core needs to know.
    public enum Place: Sendable, Equatable {
        case inbox
        case session(String)
        case other
    }

    /// What the shell holds that the board and the marks are computed from.
    public struct Facts: Sendable, Equatable {
        public var threads: [InboxThread] = []
        public var feed: [String: AttentionRow] = [:]
        public var raised: [String: Int] = [:]
        public var reviewing: Set<String> = []
        public var saved: InboxSaved = .unchecked
        public var projects: [ProjectState] = []
        public var machines: [String] = []
        /// A digest of each session's latest reply.
        public var replies: [String: String] = [:]

        public init() {}
    }

    public enum Event: Sendable, Equatable {
        case facts(Facts, now: Int)
        case place(Place)
        case chooseInbox(InboxSelection?)
        case chooseFolder(InboxFolder)
        case openInbox(InboxSubject)
        case selectProject(ProjectSelection?)
        /// The open session shows its latest reply.
        case markSeen(session: String)
        /// The first reply seen from each session counts as read.
        case recordFirstReplies
    }

    public enum Effect: Sendable, Equatable {
        /// Write this value under this key in the preferences.
        case persist(key: String, JSONValue)
        /// Post and remove these notices.
        case notify(NoticePlan)
        /// Clear notices a previous run left for items that resolved while the app was quit.
        case sweep(keeping: Set<String>)
        case dockBadge(String?)
        case navigate(Place)
    }

    /// The preferences key the reply digests are kept under.
    public static let repliesKey = "seenReplyDigests"

    public private(set) var facts = Facts()
    public private(set) var board = InboxBoard.empty
    public private(set) var opening = InboxOpening.none
    public private(set) var folder: InboxFolder = .everything
    public private(set) var selection: ProjectSelection?
    public private(set) var place: Place = .other
    public private(set) var seenReplies: [String: String]

    private var previous = InboxBoard.empty
    private var hasSwept = false

    /// Starts from the digests the last run stored.
    public init(seenReplies: [String: String] = [:]) {
        self.seenReplies = seenReplies
    }

    private var inboxPlace: InboxPlace { place == .inbox ? .inbox : .elsewhere }

    public mutating func apply(_ event: Event) -> [Effect] {
        switch event {
        case .facts(let facts, let now):
            self.facts = facts
            return settle(now: now)

        case .place(let place):
            self.place = place
            return settle(now: lastNow)

        case .chooseInbox(let choice):
            guard let choice else { return [] }
            opening = InboxRule.open(choice, from: opening, rows: InboxRule.selectable(board.sections), machines: facts.machines)
            return []

        case .chooseFolder(let chosen):
            folder = chosen
            let shown = InboxRule.shownFolder(chosen: chosen, sections: board.sections)
            opening = InboxRule.narrow(
                opening,
                visible: InboxRule.selectable(InboxRule.visible(board.sections, in: shown)),
                rows: InboxRule.selectable(board.sections),
                machines: facts.machines
            )
            return []

        case .openInbox(let subject):
            folder = .everything
            opening = InboxRule.open(.thread(subject), from: opening, rows: InboxRule.selectable(board.sections), machines: facts.machines)
            place = .inbox
            return [.navigate(.inbox)]

        case .selectProject(let chosen):
            selection = chosen
            return []

        case .markSeen(let session):
            guard let digest = facts.replies[session], seenReplies[session] != digest else { return [] }
            seenReplies[session] = digest
            return [persistReplies()]

        case .recordFirstReplies:
            var changed = false
            for (id, digest) in facts.replies.sorted(by: { $0.key < $1.key }) where seenReplies[id] == nil {
                seenReplies[id] = digest
                changed = true
            }
            return changed ? [persistReplies()] : []
        }
    }

    /// Whether a session finished something while the person was away.
    public func hasUnseenReply(_ session: String) -> Bool {
        guard let digest = facts.replies[session] else { return false }
        if place == .session(session) { return false }
        guard let seen = seenReplies[session] else { return false }
        return seen != digest
    }

    // MARK: Settling

    private var lastNow = 0

    /// Recomputes everything that depends on the facts or the place, in one step.
    private mutating func settle(now: Int) -> [Effect] {
        lastNow = now
        var effects: [Effect] = []
        board = InboxRule.board(
            threads: facts.threads, feed: facts.feed, raised: facts.raised, reviewing: facts.reviewing, saved: facts.saved,
            tickets: ProjectRule.waiting(facts.projects),
            ticketsLeftOut: facts.projects.reduce(0) { $0 + ProjectRule.leftOutWaiting($1) },
            now: now
        )

        // The open thread is settled against the board it reads. Arriving on the inbox opens
        // the first thread then, and leaving drops a resolved opening.
        opening = InboxRule.settle(opening, rows: InboxRule.selectable(board.sections), machines: facts.machines, place: inboxPlace)

        // A ticket that has gone from its board never leaves the pane naming it.
        selection = ProjectSelection.settled(selection, projects: facts.projects)

        // A folder that has emptied is drawn as Everything, and is forgotten here, or a later
        // item in it would narrow the list again with no click.
        if InboxRule.shownFolder(chosen: folder, sections: board.sections) != folder { folder = .everything }

        // The first board that holds a session is the baseline against which notices a
        // previous run delivered are swept.
        if !hasSwept, board.reported > 0 {
            hasSwept = true
            effects.append(.sweep(keeping: Set(board.rows.compactMap(Notices.notice(of:)).map(\.identifier))))
        }
        let plan = Notices.plan(previous: previous, next: board)
        if board != previous { effects.append(.dockBadge(board.dockLabel)) }
        previous = board
        if !plan.isEmpty { effects.append(.notify(plan)) }
        return effects
    }

    private func persistReplies() -> Effect {
        .persist(key: Self.repliesKey, .object(seenReplies.mapValues { .string($0) }))
    }
}
