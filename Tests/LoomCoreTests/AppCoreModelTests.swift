import XCTest
import LoomKit
import MissionKit
@testable import LoomCore

/// The simulation of the app's cross-session decisions: the board, the open thread, the
/// folder, the marks of unseen replies, the notices and what is persisted.
///
/// The production `AppCore` runs. The world is a small universe of sessions whose activity,
/// feed rows and replies the schedule changes, a place the window is in, and a preferences
/// store the harness keeps as the app does. Faults, one bit each: 0 a session vanishes from
/// the listing, 1 the feed row of a session disappears (a read that no longer reports it),
/// 2 the app is quit and started again from what was persisted, 3 a reply changes under an
/// open session.
///
/// Rules: B2, B3, B7, N2, P1, P2, as listed on `AppCore`.
struct AppCoreModel: SimSpec {
    static let modes = 2
    static let maxSteps = 64

    enum Fault: Int {
        case vanish = 0, feedGone, restart, replyChanges
    }

    static let ids = ["s1", "s2", "s3", "s4"]

    struct World {
        var core = AppCore()
        var facts = AppCore.Facts()
        var now = 1_000_000
        var preferences: [String: JSONValue] = [:]
        /// Notices posted and not yet removed.
        var posted: Set<String> = []
        var faults: Sim.FaultMask
        var asks = 0
        var replyCounter = 0
        var census: [String: Int] = [:]
        /// An ask just added to a session the app had already read the feed of: N3 expects one notice for it.
        var expectedAsk: (session: String, id: String, wasChecked: Bool)?

        mutating func count(_ key: String) { census[key, default: 0] += 1 }
    }

    func makeWorld(mode: Int, faults: Sim.FaultMask, rng: inout SimRandom) -> World {
        var world = World(faults: faults)
        if mode == 1 {
            // A session already waiting when the app starts, whose notice a past run delivered.
            world.facts.threads = [thread("s1", approvals: 1)]
            world.facts.replies["s1"] = "digest-0"
        }
        _ = try? apply(&world, .facts(world.facts, now: world.now))
        return world
    }

    func step(_ world: inout World, kind: Int, arg: Int, rng: inout SimRandom) throws(Sim.Violation) {
        let mask = world.faults
        let faulty = { (fault: Fault) in mask.has(fault.rawValue) }
        let id = Self.ids[arg % Self.ids.count]
        world.now += 1_000
        switch kind {
        case 0: setThread(&world, id, approvals: arg % 3)
        case 1:
            if faulty(.vanish) { world.facts.threads.removeAll { $0.id == id }; world.count("vanish") } else { setThread(&world, id, approvals: 0) }
        case 2: addAsk(&world, id)
        case 3:
            if faulty(.feedGone) { world.facts.feed[id] = nil; world.count("feedGone") } else { addAsk(&world, id) }
        case 4: try apply(&world, .place(.inbox))
        case 5: try apply(&world, .place(.other))
        case 6: try apply(&world, .place(.session(id)))
        case 7: try apply(&world, .chooseInbox(world.core.board.rows.isEmpty ? nil : .thread(world.core.board.rows[arg % world.core.board.rows.count].subject)))
        case 8: try apply(&world, .chooseFolder(InboxFolder.allCases[arg % InboxFolder.allCases.count]))
        case 9:
            if !world.core.board.rows.isEmpty { try apply(&world, .openInbox(world.core.board.rows[arg % world.core.board.rows.count].subject)) }
        case 10: try apply(&world, .markSeen(session: id))
        case 11: try apply(&world, .recordFirstReplies)
        case 12:
            world.replyCounter += 1
            world.facts.replies[id] = "digest-\(world.replyCounter)"
            if faulty(.replyChanges), case .session(let open) = world.core.place { world.facts.replies[open] = "digest-\(world.replyCounter)x"; world.count("replyChanges") }
        case 13: break
        case 14:
            if faulty(.restart) { restart(&world) }
        default: break
        }
        if [0, 1, 2, 3, 12, 13, 15].contains(kind) { try apply(&world, .facts(world.facts, now: world.now)) }

        // N3: an ask that appears on a session whose feed was already read posts one notice for it.
        if let expected = world.expectedAsk {
            world.expectedAsk = nil
            if expected.wasChecked, let row = world.core.board.rows.first(where: { $0.subject == .ask(session: expected.session, id: expected.id) }),
               let notice = Notices.notice(of: row), !world.posted.contains(notice.identifier) {
                throw Sim.Violation("N3", "a new ask \(expected.id) on \(expected.session) posted no notice")
            }
        }
        try check(world)
    }

    func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {
        // Heal: nothing to reconnect. Settling twice from the same facts changes nothing.
        try apply(&world, .facts(world.facts, now: world.now))
        let before = world.core
        try apply(&world, .facts(world.facts, now: world.now))
        guard world.core == before else { throw Sim.Violation("B3", "settling twice from the same facts changed the state") }
    }

    func snapshot(_ world: World) -> String {
        let board = world.core.board.rows.map { "\($0.subject)" }
        return "board=\(board) opening=\(String(describing: world.core.opening.selection)) resolved=\(world.core.opening.isResolved) folder=\(world.core.folder) place=\(world.core.place) seen=\(world.core.seenReplies.sorted { $0.key < $1.key }) posted=\(world.posted.sorted()) prefs=\(world.preferences.keys.sorted()) census=\(world.census.sorted { $0.key < $1.key })"
    }

    func tallies(_ world: World) -> [String: Int] { world.census }

    // MARK: World changes

    private func thread(_ id: String, approvals: Int) -> InboxThread {
        let activity = SessionActivity(.object([
            "session_id": .string(id), "state": approvals > 0 ? "needs_you" : "idle", "approvals": .int(Int64(approvals)),
        ]))
        return InboxThread(id: id, name: id, activity: activity)
    }

    private func setThread(_ world: inout World, _ id: String, approvals: Int) {
        world.facts.threads.removeAll { $0.id == id }
        world.facts.threads.append(thread(id, approvals: approvals))
        world.facts.threads.sort { $0.id < $1.id }
        if world.facts.feed[id] == nil { world.facts.feed[id] = AttentionRow(sessionID: id) }
    }

    private func addAsk(_ world: inout World, _ id: String) {
        guard world.facts.threads.contains(where: { $0.id == id }) else { return }
        world.asks += 1
        let ask = AttentionAsk(id: "a\(world.asks)", strand: "main", createdAt: world.now, head: "Which?", questions: 1)
        world.expectedAsk = (id, "a\(world.asks)", world.core.board.checked.contains(id))
        let existing = world.facts.feed[id]?.asks.items ?? []
        world.facts.feed[id] = AttentionRow(sessionID: id, asks: .init(count: existing.count + 1, items: existing + [ask]))
    }

    /// The app is quit and started again from what it persisted.
    private func restart(_ world: inout World) {
        let stored = world.preferences[AppCore.repliesKey]
        var digests: [String: String] = [:]
        if case .object(let fields)? = stored {
            for (key, value) in fields { if let text = value.string { digests[key] = text } }
        }
        world.core = AppCore(seenReplies: digests)
        world.posted = []
        world.count("restart")
    }

    // MARK: Applying events and checking effects

    private func apply(_ world: inout World, _ event: AppCore.Event) throws(Sim.Violation) {
        let beforeSelection = world.core.opening.selection
        let beforeRows = Set(world.core.board.rows.map(\.subject))
        let effects = world.core.apply(event)
        for effect in effects {
            switch effect {
            case .persist(let key, let value):
                // P2: only reply digests are persisted, under the one key.
                guard key == AppCore.repliesKey, case .object(let fields) = value else { throw Sim.Violation("P2", "persisted \(key)") }
                for (session, digest) in fields where digest.string?.hasPrefix("digest-") != true {
                    throw Sim.Violation("P2", "persisted a value that is not a reply digest for \(session): \(digest)")
                }
                world.preferences[key] = value
                world.count("persist")
            case .notify(let plan):
                // N2: a notice is posted once, and removed only after it was posted.
                for notice in plan.post {
                    guard world.posted.insert(notice.identifier).inserted else { throw Sim.Violation("N2", "notice \(notice.identifier) was posted twice") }
                }
                for identifier in plan.remove { world.posted.remove(identifier) }
                world.count("notify")
            case .sweep, .dockBadge, .navigate:
                break
            }
        }
        if case .facts = event {
            // B3: a refresh never moves the open thread while its row is still listed.
            if case .thread(let subject)? = beforeSelection, beforeRows.contains(subject), world.core.board.rows.contains(where: { $0.subject == subject }),
               world.core.place == .inbox, world.core.opening.selection != beforeSelection {
                throw Sim.Violation("B3", "a refresh moved the open thread \(subject)")
            }
        }
    }

    private func check(_ world: World) throws(Sim.Violation) {
        // B2: the board is the rule applied to the facts.
        let expected = InboxRule.board(
            threads: world.facts.threads, feed: world.facts.feed, raised: world.facts.raised, reviewing: world.facts.reviewing,
            saved: world.facts.saved, tickets: [], ticketsLeftOut: 0, now: world.core.facts == world.facts ? lastNow(world) : lastNow(world)
        )
        if world.core.facts == world.facts, world.core.board.rows.map(\.subject) != expected.rows.map(\.subject) {
            throw Sim.Violation("B2", "the board does not match the rule applied to the facts")
        }

        // B3: the open thread is a listed row, or machine, or none.
        if world.core.place == .inbox, let selection = world.core.opening.selection, !world.core.opening.isResolved {
            switch selection {
            case .thread(let subject):
                guard world.core.board.rows.contains(where: { $0.subject == subject }) else { throw Sim.Violation("B3", "the open thread \(subject) is not on the board and is not marked resolved") }
            case .machine(let name):
                guard world.facts.machines.contains(name) else { throw Sim.Violation("B3", "the open machine \(name) is not listed") }
            }
        }

        // B7: the session in view has no unseen mark.
        if case .session(let id) = world.core.place, world.core.hasUnseenReply(id) {
            throw Sim.Violation("B7", "session \(id) shows an unseen mark while it is the place shown")
        }

        // N2: a posted notice belongs to a row the board still lists.
        let live = Set(world.core.board.rows.compactMap(Notices.notice(of:)).map(\.identifier))
        for identifier in world.posted where !live.contains(identifier) {
            throw Sim.Violation("N2", "notice \(identifier) stays posted after its row left the board")
        }

        // P1: what was persisted is what the core holds.
        if case .object(let fields)? = world.preferences[AppCore.repliesKey] {
            let stored = fields.compactMapValues(\.string)
            for (session, digest) in stored where world.core.seenReplies[session] != digest && world.core.seenReplies[session] != nil {
                // A later mark may not be persisted yet only if no effect was produced, which would be a bug.
                throw Sim.Violation("P1", "persisted \(session)=\(digest) differs from the core's \(String(describing: world.core.seenReplies[session]))")
            }
        }
    }

    private func lastNow(_ world: World) -> Int { world.now }
}

final class AppCoreModelTests: XCTestCase {
    func testTheSwarmKeepsEveryRuleOfTheAppCore() {
        for generator in [Sim.generator(default: 1), Sim.generator(default: 1) + 1] {
            if let failure = Sim.check(AppCoreModel(), runs: Sim.runs(default: 1_500), generator: generator) {
                XCTFail("generator \(generator): \(failure)")
            }
        }
    }

    func testTheSwarmReachesTheStatesTheRulesTalkAbout() {
        var seen: [String: Int] = [:]
        var rng = SimRandom(seed: 17)
        for _ in 0..<1_500 {
            let length = 3 + Int(rng.next() % UInt64(AppCoreModel.maxSteps))
            let seed = Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if case .success(let outcome) = Sim.run(AppCoreModel(), seed: seed) {
                for (key, value) in outcome.tallies { seen[key, default: 0] += value }
            }
        }
        for key in ["vanish", "feedGone", "restart", "persist", "notify", "replyChanges"] where (seen[key] ?? 0) == 0 {
            XCTFail("no run reached \(key); reached \(seen.sorted { $0.key < $1.key })")
        }
    }

    func testTheCorpusIsDeterministicOnTwoRuns() {
        var rng = SimRandom(seed: 29)
        let seeds = (0..<300).map { _ -> Sim.Seed in
            let length = 3 + Int(rng.next() % UInt64(AppCoreModel.maxSteps))
            return Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        }
        XCTAssertEqual(Sim.corpus(AppCoreModel(), seeds: seeds), [])
    }
}
