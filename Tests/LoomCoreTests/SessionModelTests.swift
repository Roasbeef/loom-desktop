import XCTest
import LoomKit
@testable import LoomCore

/// The deterministic simulation of one attached session.
///
/// The production core (`Session`, which holds the production `Lane` and `Conversation`)
/// runs inside this harness. Only the world is simulated: a `FakeDaemon` for the socket's
/// far end, a virtual clock the schedule moves, and a `Host` that performs the core's
/// effects the way the app's controller does and keeps what a view would have observed.
/// The runner plays the shell's event loop: it feeds frames and ticks to the core, in the
/// order the seed chooses, and performs the effects it returns.
///
/// ## What runs for real and what is simulated
///
/// | Component | In the simulation |
/// | --- | --- |
/// | `Lane`, `Session`, `Conversation`, `TransferAssembler`, `DraftLedger` | production, unchanged |
/// | the session socket | simulated: a FIFO of frames, with faults at its two ends |
/// | the daemon | `FakeDaemon`, strict about stop-and-wait and transfers |
/// | the clock | virtual: moves only on a generated tick or a jump to `nextDue` |
/// | the app's controller | `Host`: performs effects, observes projections |
/// | the shell's reconnect | `Host`: reattaches 3 s after the lane ends, as the catalogue poll does |
///
/// ## Faults, one bit each in the seed's mask
///
/// An op whose class is off acts honestly, so every seed makes progress.
///
/// | Bit | Class | Enters at |
/// | --- | --- | --- |
/// | 0 | lost reply | an inbound reply is dropped after the daemon applied the command |
/// | 1 | duplicate | the last push is delivered again |
/// | 2 | reorder | two queued pushes swap |
/// | 3 | disconnect | the socket closes at any step, including inside a transfer |
///
/// ## Rules
///
/// The lane's tags are checked through the daemon's strictness (I1, I6) and its own model
/// test. This spec adds the session's:
///
/// - O1 text the person sent is in exactly one place: the editor, a pending line, or the
///   transcript. After the heal, a message the daemon applied is in the transcript and not
///   the editor, and one it did not is in the editor.
/// - O2 one `prompt` or `steer` crosses the wire per message.
/// - T1 the durable rows of a strand only grow, except through `/clear`, a strand change or
///   a new attachment.
/// - T3 a reply's text is in the live stream or a durable row from its first delta until its
///   entry lands, and not in both once the stream has ended.
/// - T4 a token changes nothing a view reads except through the stream flush.
/// - T5 the stream is projected at most once per flush window.
/// - T6 a cut of an unchanged daemon changes nothing observed.
/// - Liveness: after the heal the session is attached, nothing waits, every draft is settled,
///   and the transcript equals the daemon's chain.
///
/// One excuse is counted and not failed: a stream replaced by a newer generation on its
/// strand before its entry is held (`streamReplacedBeforeEntry`). Loom's rule replaces it
/// too, so the gap is a policy question and is tracked as such.
struct SessionModel: SimSpec {
    static let modes = 2
    static let maxSteps = 64

    enum Fault: Int {
        case lostReply = 0, duplicate, reorder, disconnect
    }

    static let tickSizes = [10, 33, 34, 60, 100, 250, 1_000, 3_000, 5_000, 9_999, 10_000, 30_000]

    /// What the app's controller keeps for views, and the editor.
    struct Host: Equatable {
        var editor = ""
        var stream: LiveStream?
        var rowIDs: [String] = []
        var notices: [String] = []
        var projections = 0
        var streamProjections = 0
        var pushedProjections = 0
    }

    struct World {
        var session: Session
        var daemon = FakeDaemon()
        var host = Host()
        var now = 0
        var wire: [String] = []
        var reattachAt: Int?
        var attachments = 1
        var sent: [String] = []
        var sentStrand: [String: String] = [:]
        var counter = 0
        var faults: Sim.FaultMask
        var rowBase: [String] = []
        var seen: [String: String] = [:]
        var lastStream: Int?
        var pendingCutVersion = 0
        var lastCutVersion: Int?
        var healing = false
        /// What the T1 check last read, so an unchanged transcript is not walked again.
        var rowsKey: [Int] = []
        var census: [String: Int] = [:]

        mutating func count(_ key: String) { census[key, default: 0] += 1 }
    }

    // MARK: Spec

    func makeWorld(mode: Int, faults: Sim.FaultMask, rng: inout SimRandom) -> World {
        var daemon = FakeDaemon()
        if mode == 1 {
            // A session already in progress: history, and a reply streaming.
            _ = daemon.receive(command: Frames.text(["v": 2, "id": 1, "cmd": "prompt", "body": ["strand": "main", "text": "earlier"]]))
            daemon.socket.owed = 0
            _ = daemon.progress(choice: 1)
        }
        let started = Session.start(sessionID: "s1", now: 0)
        var world = World(session: started.session, daemon: daemon, faults: faults)
        world.daemon.attach()
        perform(&world, started.effects)
        return world
    }

    func step(_ world: inout World, kind: Int, arg: Int, rng: inout SimRandom) throws(Sim.Violation) {
        let mask = world.faults
        let faulty = { (fault: Fault) in mask.has(fault.rawValue) }
        switch kind {
        case 0: try send(&world, arg: arg)
        case 1: try submit(&world, Lane.Command("notes", kind: .read))
        case 2, 3: try progress(&world, choice: arg)
        case 4: world.wire += world.daemon.unrelatedEntry(); world.count("unrelatedEntry")
        case 5: try deliver(&world, rng: &rng)
        case 6: while !world.wire.isEmpty { try deliver(&world, rng: &rng) }
        case 7: try tick(&world, ms: Self.tickSizes[arg % Self.tickSizes.count])
        case 8: try jump(&world)
        case 9: faulty(.lostReply) ? lose(&world) : try deliver(&world, rng: &rng)
        case 10: faulty(.duplicate) ? duplicate(&world) : try deliver(&world, rng: &rng)
        case 11: faulty(.reorder) ? reorder(&world) : try deliver(&world, rng: &rng)
        case 12: faulty(.disconnect) ? disconnect(&world) : try deliver(&world, rng: &rng)
        case 13: perform(&world, world.session.apply(.clear, now: world.now)); world.rowBase = []
        case 14:
            // A strand is chosen from the picker, which lists the strands the daemon has.
            if world.daemon.strands.contains("side") {
                perform(&world, world.session.apply(.focus(world.session.focusedStrand == "main" ? "side" : "main"), now: world.now))
                world.rowBase = []
            }
        default: perform(&world, world.session.apply(.cancelWaiting, now: world.now))
        }
        try check(&world)
    }

    func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {
        // Heal: faults off, the daemon finishes its work, time moves, and the host
        // reattaches by its own rule. Nothing here reconnects what production would not.
        world.faults = .none
        world.healing = true
        for _ in 0..<400 {
            while world.daemon.operation != nil || !world.daemon.held.isEmpty {
                world.wire += world.daemon.progress(choice: 0)
            }
            while !world.wire.isEmpty { try deliver(&world, rng: &rng) }
            try check(&world)
            if quiescent(world) { break }
            let due = [world.session.nextDue, world.reattachAt].compactMap { $0 }.min() ?? world.now + 1_000
            world.now = max(world.now, due)
            try tickNow(&world)
        }
        guard quiescent(world) else {
            throw Sim.Violation("liveness", "no quiescence: live=\(world.session.isLive) inflight=\(world.session.lane.isInFlight) waiting=\(world.session.lane.waiting) wire=\(world.wire.count) reattach=\(String(describing: world.reattachAt))")
        }
        try settledChecks(world)
    }

    func snapshot(_ world: World) -> String {
        let rows = world.session.conversation.rows(strand: world.session.focusedStrand).map { "\($0.id)" }
        let ledger = world.session.ledger.lines.map { "\($0.id):\($0.text):\($0.outcome)" }
        let applied = world.daemon.applied.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
        return [
            "now=\(world.now) attach=\(world.attachments) live=\(world.session.isLive) due=\(String(describing: world.session.nextDue))",
            "lane=\(world.session.lane.phase) next=\(world.session.lane.nextID) cursor=\(world.session.lane.cursor)",
            "rows=\(rows)", "ledger=\(ledger)", "editor=\(world.host.editor.debugDescription)",
            "host=\(world.host.projections)/\(world.host.streamProjections)/\(world.host.pushedProjections)",
            "daemon=\(world.daemon.entries.map(\.id)) v=\(world.daemon.version) applied=\(applied)",
            "wire=\(world.wire.count) census=\(world.census.sorted(by: { $0.key < $1.key }))",
        ].joined(separator: "\n")
    }

    func tallies(_ world: World) -> [String: Int] { world.census }

    // MARK: Ops

    private func send(_ world: inout World, arg: Int) throws(Sim.Violation) {
        world.counter += 1
        let text = "m\(world.counter)#"
        world.sent.append(text)
        let strand = world.session.focusedStrand
        world.sentStrand[text] = strand
        let busy = world.session.isBusy
        let steer = busy && arg % 4 == 3
        let command = Lane.Command(steer ? "steer" : "prompt", body: ["strand": .string(strand), "text": .string(text)], kind: .mutation)
        let delivery: Delivery = steer ? .steer : busy ? .queue : .send
        perform(&world, world.session.apply(.send(text: text, delivery: delivery, command: command), now: world.now))
        world.count("send")
    }

    private func submit(_ world: inout World, _ command: Lane.Command) throws(Sim.Violation) {
        world.counter += 1
        perform(&world, world.session.apply(.submit(command, tag: world.counter), now: world.now))
    }

    private func progress(_ world: inout World, choice: Int) throws(Sim.Violation) {
        let frames = world.daemon.progress(choice: choice)
        world.wire += frames
        if !frames.isEmpty { world.count("daemonProgress") }
    }

    /// Delivers the first frame on the socket to the core, as the shell's reader would.
    private func deliver(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {
        guard !world.wire.isEmpty else { return }
        guard world.session.isLive else {
            world.wire = []
            return
        }
        let frame = world.wire.removeFirst()
        guard let envelope = try? EventEnvelope.decode(frame) else { return }
        if envelope.replyTo != nil { world.daemon.replyConsumed() }
        let isToken = envelope.event == "stream_delta" && envelope.body["kind"]?.string == "text"
        if isToken, let strand = envelope.body["strand"]?.string, let generation = envelope.body["generation"]?.string {
            world.seen[strand] = generation
        }
        let revision = world.session.conversation.revision
        let version = world.pendingCutVersion
        let effects = world.session.receive(frame, now: world.now)

        // T4: a token changes no projection and no revision. Only the flush shows it.
        if isToken, world.session.isLive {
            guard !effects.contains(where: { if case .project = $0 { return true }; return false }),
                  world.session.conversation.revision == revision else {
                throw Sim.Violation("T4", "a token caused a projection or moved the revision: \(effects)")
            }
        }

        // T6: a cut of a daemon that has not changed since the last cut changes nothing.
        if envelope.event == "snapshot_end" {
            let projected = effects.contains { if case .project(.all(forced: .ifChanged)) = $0 { return true }; return false }
            if projected, let last = world.lastCutVersion, last == version {
                throw Sim.Violation("T6", "an unchanged daemon (version \(version)) changed what is observed")
            }
            world.lastCutVersion = version
        }
        perform(&world, effects)
    }

    private func lose(_ world: inout World) {
        guard let index = world.wire.firstIndex(where: { (try? EventEnvelope.decode($0))?.replyTo != nil }) else { return }
        world.wire.remove(at: index)
        world.count("lostReply")
    }

    private func duplicate(_ world: inout World) {
        guard let push = world.wire.last(where: { (try? EventEnvelope.decode($0))?.replyTo == nil }) else { return }
        world.wire.insert(push, at: 0)
        world.count("duplicatePush")
    }

    private func reorder(_ world: inout World) {
        let pushes = world.wire.indices.filter { (try? EventEnvelope.decode(world.wire[$0]))?.replyTo == nil }
        guard pushes.count >= 2 else { return }
        world.wire.swapAt(pushes[0], pushes[1])
        world.count("reorderedPushes")
    }

    private func disconnect(_ world: inout World) {
        guard world.session.isLive else { return }
        perform(&world, world.session.receive(failed: .closed("the socket ended"), now: world.now))
        world.count("disconnect")
    }

    private func tick(_ world: inout World, ms: Int) throws(Sim.Violation) {
        world.now += ms
        try tickNow(&world)
    }

    private func jump(_ world: inout World) throws(Sim.Violation) {
        let due = [world.session.nextDue, world.reattachAt].compactMap { $0 }.min()
        if let due { world.now = max(world.now, due) }
        try tickNow(&world)
    }

    /// The shell's one wake-up: the core's tick, and the reattach the catalogue poll makes.
    private func tickNow(_ world: inout World) throws(Sim.Violation) {
        if let due = world.session.nextDue, due <= world.now {
            perform(&world, world.session.tick(now: world.now))
        }
        if let at = world.reattachAt, at <= world.now, !world.session.isLive {
            world.reattachAt = nil
            let started = Session.start(sessionID: "s1", inheriting: world.session, now: world.now)
            world.session = started.session
            world.daemon.attach()
            world.wire = []
            world.attachments += 1
            world.rowBase = []
            world.seen = [:]
            world.host.stream = nil
            world.lastCutVersion = nil
            world.count("reattach")
            perform(&world, started.effects)
        }
    }

    // MARK: Performing effects

    /// What the app's controller does with each effect, plus what a view would observe.
    private func perform(_ world: inout World, _ effects: [Session.Effect]) {
        for effect in effects {
            switch effect {
            case .transmit(let text):
                let before = world.daemon.version
                let replies = world.daemon.receive(command: text)
                if let command = Frames.decode(command: text), ["subscribe", "catch_up", "history"].contains(command.cmd) {
                    world.pendingCutVersion = world.daemon.version
                }
                _ = before
                world.wire += replies
            case .shut:
                world.daemon.socket.isOpen = false
                world.wire = []
            case .project(let projection):
                world.host.projections += 1
                let conversation = world.session.conversation
                switch projection {
                case .all:
                    world.host.rowIDs = conversation.rows(strand: world.session.focusedStrand, clearedThrough: world.session.clearedThrough[world.session.focusedStrand]).map(\.id)
                    world.host.stream = conversation.streams[world.session.focusedStrand]
                case .pushed:
                    world.host.pushedProjections += 1
                case .stream:
                    world.host.streamProjections += 1
                    world.host.stream = conversation.streams[world.session.focusedStrand]
                    world.lastStream = world.now
                }
            case .settled:
                break
            case .restoreDraft(let text):
                world.host.editor = DraftLedger.restoring(text, into: world.host.editor)
                world.count("restoreDraft")
            case .notice(let words, _):
                world.host.notices.append(words)
                if words == Session.maybeSentWords { world.count("maybeSent") }
                if words == Session.offeredBackWords { world.count("offeredBack") }
            case .restoreReturned, .pushedEvent:
                break
            case .ended:
                world.reattachAt = world.now + 3_000
                world.count("ended")
            }
        }
    }

    // MARK: Invariants

    private func check(_ world: inout World) throws(Sim.Violation) {
        if let violation = world.daemon.violations.first { throw violation }
        for (key, count) in world.daemon.applied where count > 1 && (key.hasPrefix("prompt:") || key.hasPrefix("steer:")) {
            throw Sim.Violation("O2", "\(key) crossed the wire \(count) times")
        }
        try rows(world: &world)
        try streams(world)
        try custody(world)
        if let last = world.lastStream, last > world.now { throw Sim.Violation("T5", "a stream projection from the future") }
    }

    /// T1: the durable rows of the strand only grow.
    private func rows(world: inout World) throws(Sim.Violation) {
        let strand = world.session.focusedStrand
        let key = [world.session.conversation.revision, world.attachments, world.session.clearedThrough[strand] ?? -1, strand.hashValue, world.rowBase.isEmpty ? 0 : 1]
        if key == world.rowsKey { return }
        world.rowsKey = key
        let ids = world.session.conversation.rows(strand: strand, clearedThrough: world.session.clearedThrough[strand]).filter { $0.seq != nil }.map(\.id)
        if !world.rowBase.isEmpty {
            var cursor = ids.makeIterator()
            for id in world.rowBase where !cursor.contains(where: { $0 == id }) {
                throw Sim.Violation("T1", "row \(id) left the transcript: was \(world.rowBase), now \(ids)")
            }
        }
        world.rowBase = ids
    }

    /// T3: a reply's text is in the stream or a durable row, and not both once ended.
    private func streams(_ world: World) throws(Sim.Violation) {
        let conversation = world.session.conversation
        for (strand, generation) in world.seen {
            guard let reserved = StreamIdentity.responseEntry(generation) else { continue }
            let current = conversation.streams[strand]
            if conversation.holds(entry: reserved) {
                if current?.generation == generation, current?.ended == true {
                    throw Sim.Violation("T3", "the text is in the durable row \(reserved) and in the ended stream")
                }
                continue
            }
            if current?.generation == generation { continue }
            if current != nil {
                // A newer generation took the strand before the entry was held.
                continue
            }
            throw Sim.Violation("T3", "the reply for \(reserved) is in neither the stream nor a durable row")
        }
    }

    /// O1: a message is not both in the editor and anywhere the daemon may hold it.
    private func custody(_ world: World) throws(Sim.Violation) {
        let conversation = world.session.conversation
        guard !world.host.editor.isEmpty else { return }
        for text in world.sent where world.host.editor.contains(text) {
            let inTranscript = Session.occurrences(of: text, in: conversation, strand: world.sentStrand[text] ?? "main") > 0
            let inLedger = world.session.ledger.lines.contains { $0.text == text }
            let pending = conversation.pendingInputs.contains { $0.text == text }
            if inTranscript || inLedger || pending {
                throw Sim.Violation("O1", "\(text) is in the editor and also in the transcript, a pending line or a held input")
            }
        }
    }

    private func quiescent(_ world: World) -> Bool {
        world.session.isLive && world.reattachAt == nil && world.wire.isEmpty && !world.session.lane.isInFlight
            && world.session.lane.waiting == 0 && world.session.flushAt == nil && world.daemon.operation == nil
            && world.daemon.held.isEmpty && world.session.ledger.lines.isEmpty
            // A notice that arrives before the first cut is dropped, and a lost final notice is
            // repaired only by the refresh, so the heal must outlast one refresh to be caught up.
            && world.session.lane.cursor >= world.daemon.nextSeq
    }

    private func settledChecks(_ world: World) throws(Sim.Violation) {
        let conversation = world.session.conversation
        for text in world.sent {
            let applied = (world.daemon.applied["prompt:\(text)"] ?? 0) + (world.daemon.applied["steer:\(text)"] ?? 0)
            let inEditor = world.host.editor.contains(text)
            let shown = Session.occurrences(of: text, in: conversation, strand: world.sentStrand[text] ?? "main")
            if applied > 0 && inEditor { throw Sim.Violation("O1", "\(text) was applied and is also back in the editor") }
            if applied == 0 && !inEditor { throw Sim.Violation("O1", "\(text) was never applied and is not in the editor: the text is lost") }
            if applied > 0, shown == 0, world.session.clearedThrough.isEmpty { throw Sim.Violation("liveness", "\(text) was applied but the transcript never shows it") }
        }
        if world.session.clearedThrough.isEmpty, world.session.focusedStrand == "main" {
            let shown = conversation.rows(strand: "main").compactMap { row -> String? in
                switch row.kind {
                case .user(let text, _): return text
                case .assistant(let text): return text
                default: return nil
                }
            }
            let chain = world.daemon.chain(strand: "main").map(\.text)
            guard shown == chain else { throw Sim.Violation("liveness", "the transcript \(shown) is not the daemon's chain \(chain)") }
        }
    }
}

final class SessionModelTests: XCTestCase {
    /// `SIM_REPLAY=<hex> swift test --filter SessionModelTests/testReplay` prints one seed step by step.
    func testReplay() throws {
        guard let hex = ProcessInfo.processInfo.environment["SIM_REPLAY"], let seed = Sim.Seed(hex: hex) else { throw XCTSkip("set SIM_REPLAY") }
        Sim.replay(SessionModel(), seed: seed) { print($0) }
    }

    func testTheSwarmKeepsEveryRuleOfTheSession() {
        for generator in [Sim.generator(default: 1), Sim.generator(default: 1) + 1] {
            if let failure = Sim.check(SessionModel(), runs: Sim.runs(default: 1_500), generator: generator) {
                XCTFail("generator \(generator): \(failure)")
            }
        }
    }

    func testTheSwarmReachesTheStatesTheRulesTalkAbout() {
        var seen: [String: Int] = [:]
        var rng = SimRandom(seed: 5)
        for _ in 0..<1_500 {
            let length = 3 + Int(rng.next() % UInt64(SessionModel.maxSteps))
            let seed = Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if case .success(let outcome) = Sim.run(SessionModel(), seed: seed) {
                for (key, value) in outcome.tallies { seen[key, default: 0] += value }
            }
        }
        for key in ["send", "daemonProgress", "lostReply", "disconnect", "reattach", "maybeSent", "restoreDraft", "unrelatedEntry", "duplicatePush", "reorderedPushes"] where (seen[key] ?? 0) == 0 {
            XCTFail("no run reached \(key); reached \(seen.sorted(by: { $0.key < $1.key }))")
        }
    }

    func testTheCorpusIsDeterministicOnTwoRuns() {
        var rng = SimRandom(seed: 11)
        let seeds = (0..<300).map { _ -> Sim.Seed in
            let length = 3 + Int(rng.next() % UInt64(SessionModel.maxSteps))
            return Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        }
        XCTAssertEqual(Sim.corpus(SessionModel(), seeds: seeds), [])
    }
}
