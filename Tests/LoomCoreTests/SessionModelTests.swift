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
/// | 4 | lost request | a prompt or steer is dropped on its way to the daemon, which never sees it |
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
        case lostReply = 0, duplicate, reorder, disconnect, lostRequest, observer
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
        /// The sequence of each approval the person was shown and answered while the session held it.
        var decisions: [String: Int] = [:]
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
        /// The faults the seed chose, which the heal turns off in `faults` and a content check still needs to know.
        let injected: Sim.FaultMask
        var rowBase: [String] = []
        var seen: [String: String] = [:]
        var lastStream: Int?
        /// How many fragments of each generation the live session has been given.
        var delivered: [String: Int] = [:]
        var pendingCutVersion = 0
        var lastCutVersion: Int?
        var healing = false
        /// The next prompt or steer is dropped on its way to the daemon, which never sees it.
        var dropNextCommand = false
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
        var world = World(session: started.session, daemon: daemon, faults: faults, injected: faults)
        world.daemon.socket.role = faults.has(Fault.observer.rawValue) ? "observer" : "owner"
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
        default:
            if arg % 4 == 0 {
                try decide(&world, arg: arg)
            } else if arg % 2 == 1, faulty(.lostRequest) {
                world.dropNextCommand = true
                world.count("lostRequest")
            } else {
                perform(&world, world.session.apply(.cancelWaiting, now: world.now))
            }
        }
        try check(&world)
    }

    /// The person answers an approval: one the session holds, or one it never did.
    private func decide(_ world: inout World, arg: Int) throws(Sim.Violation) {
        let held = world.session.conversation.escalations
        let record: Escalation
        if let first = held.first, arg % 8 != 4 {
            record = held[arg % held.count]
            world.decisions[record.id] = record.seq
            _ = first
        } else {
            // A record the session does not hold, as a view that outlived its row would offer.
            record = Escalation(id: "ghost\(arg)", seq: 1, status: "pending", strand: "main", tool: "bash", action: "run", preview: "", reason: "", source: "", grants: [], untranslatableGrants: 0)
        }
        world.counter += 1
        let tag = 10_000 + world.counter
        let decision: Session.Decision = arg % 3 == 0 ? .deny : .approve(arg % 5 == 0 ? .forSession : .once)
        perform(&world, world.session.apply(.decide(record, decision, tag: tag), now: world.now))
        world.count("decide")
    }

    func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {
        // Heal: faults off, the daemon finishes its work, time moves, and the host
        // reattaches by its own rule. Nothing here reconnects what production would not.
        world.faults = .none
        world.healing = true
        for _ in 0..<400 {
            while !world.daemon.operations.isEmpty || !world.daemon.held.isEmpty {
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
            "results=\(world.daemon.lastResult.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.outcome)" }) daemon=\(world.daemon.entries.map(\.id)) v=\(world.daemon.version) applied=\(applied)",
            "delivered=\(world.delivered.sorted { $0.key < $1.key }.map { "\($0.value)" }) streamed=\(world.daemon.streamed.sorted { $0.key < $1.key }.map { "\($0.value.fragments)" }) wire=\(world.wire.count) census=\(world.census.sorted(by: { $0.key < $1.key }))",
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
        let kind = envelope.body["kind"]?.string
        let isToken = envelope.event == "stream_delta" && ["text", "thinking", "tool_call"].contains(kind ?? "")
        if envelope.event == "stream_delta", kind != "end", let generation = envelope.body["generation"]?.string { world.delivered[generation, default: 0] += 1 }
        if isToken, kind == "text", let strand = envelope.body["strand"]?.string, let generation = envelope.body["generation"]?.string {
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

        // T7: when a generation's stream ends and the session was given every one of its fragments, once and
        // in order, the text it holds is exactly what the daemon wrote, however the fragments were cut.
        if envelope.event == "stream_delta", kind == "end", world.session.isLive,
           let generation = envelope.body["generation"]?.string, let strand = envelope.body["strand"]?.string,
           let written = world.daemon.streamed[generation], world.delivered[generation] == written.fragments,
           !world.injected.has(Fault.duplicate.rawValue), !world.injected.has(Fault.reorder.rawValue) {
            let held = world.session.conversation.streams[strand]
            if held?.generation == generation, held?.text != written.text || held?.thinking != written.thinking {
                throw Sim.Violation("T7", "the stream text \(String(describing: held?.text)) thinking \(String(describing: held?.thinking)) is not what the daemon wrote \(written.text) / \(written.thinking) after \(written.fragments) fragments")
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
        // A socket reports its end more than once, so this is sent to a lane that is already closed too.
        let wasLive = world.session.isLive
        let effects = world.session.receive(failed: .closed("the socket ended"), now: world.now)
        if !wasLive, !effects.isEmpty { world.daemon.violations.append(Sim.Violation("I5", "a closed session reported its end again: \(effects)")) }
        perform(&world, effects)
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
            world.daemon.socket.role = world.injected.has(Fault.observer.rawValue) ? "observer" : "owner"
            world.daemon.attach()
            world.wire = []
            world.attachments += 1
            world.rowBase = []
            world.seen = [:]
            world.host.stream = nil
            world.lastCutVersion = nil
            world.delivered = [:]
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
                if let command = Frames.decode(command: text) {
                    // O5: once the session knows it is an observer, it sends no mutation.
                    if world.session.conversation.role == "observer", Session.observerBlocked.contains(command.cmd) {
                        world.daemon.violations.append(Sim.Violation("O5", "an observer transmitted \(command.cmd)"))
                    }

                    // O3: an answer carries the sequence of a record the session held when the person answered.
                    if command.cmd == "approve" || command.cmd == "deny" {
                        let id = command.body["escalation_id"]?.string ?? ""
                        if world.decisions[id] != command.body["expected_seq"]?.int {
                            world.daemon.violations.append(Sim.Violation("O3", "\(command.cmd) for \(id) carried expected_seq \(String(describing: command.body["expected_seq"]?.int)), not a record the session held"))
                        }
                    }
                }
                let before = world.daemon.version
                if world.dropNextCommand, let command = Frames.decode(command: text), command.cmd == "prompt" || command.cmd == "steer" {
                    world.dropNextCommand = false
                    world.daemon.socket.owed += 1
                    continue
                }
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
                    // T5: the stream is projected at most once per flush window, whatever pushes arrive in it.
                    if let last = world.lastStream, world.now - last < 33 {
                        world.daemon.violations.append(Sim.Violation("T5", "the stream was projected twice within \(world.now - last) ms"))
                    }
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
            case .restoreReturned, .pushedEvent, .forgetImages:
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

        // X3: an approval is drawn at most once, and only one the daemon raised and has not decided.
        let drawn = world.session.conversation.escalations.map(\.id)
        guard Set(drawn).count == drawn.count else { throw Sim.Violation("X3", "an approval appears twice: \(drawn)") }
        for id in drawn where world.daemon.escalations[id] == nil {
            throw Sim.Violation("X3", "an approval \(id) the daemon never raised is drawn")
        }
        if let last = world.lastStream, last > world.now { throw Sim.Violation("T5", "a stream projection from the future") }
    }

    /// T1: the durable rows of the strand only grow.
    private func rows(world: inout World) throws(Sim.Violation) {
        let strand = world.session.focusedStrand
        let key = [world.session.conversation.revision, world.attachments, world.session.clearedThrough[strand] ?? -1, strand.hashValue, world.rowBase.isEmpty ? 0 : 1]
        if key == world.rowsKey { return }
        world.rowsKey = key
        let ids = world.session.conversation.rows(strand: strand, clearedThrough: world.session.clearedThrough[strand]).filter { $0.seq != nil }.map(\.id)
        let all = world.session.conversation.rows(strand: strand).map(\.id)
        guard Set(all).count == all.count else { throw Sim.Violation("X1", "a block appears twice in the transcript: \(all)") }
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
            && world.session.lane.waiting == 0 && world.session.flushAt == nil && world.daemon.operations.isEmpty
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
            let shown = conversation.rows(strand: "main").map { row -> String in
                switch row.kind {
                case .user(let text, _): return "u:" + text
                case .assistant(let text): return "a:" + text
                case .thinking(let text): return "th:" + text
                case .tool(let name, _, _, _): return "tool:" + name
                case .notice(let text): return text == "Stopped before the turn finished." ? "stopped" : "notice:" + text
                case .failure: return "error"
                default: return "?"
                }
            }
            let expected = world.daemon.chain(strand: "main").flatMap { entry -> [String] in
                switch entry.role {
                case "user": return ["u:" + entry.text]
                case "assistant":
                    return entry.blocks.map(\.label) + (entry.stopReason == "aborted" ? ["stopped"] : []) + (entry.errorMessage != nil ? ["error"] : [])
                default: return []
                }
            }
            guard shown == expected else { throw Sim.Violation("liveness", "the transcript \(shown) is not the daemon's chain \(expected)") }
        }

        // X4: once every turn has settled, no approval remains drawn as pending that the daemon decided.
        for escalation in conversation.escalations where world.daemon.escalations[escalation.id]?.status != "pending" {
            throw Sim.Violation("X4", "approval \(escalation.id) is still drawn as pending after the daemon decided it")
        }

        // X2: once every turn has settled, nothing is still drawn as live. A stream whose turn failed, or
        // was stopped, leaves nothing behind.
        for (strand, stream) in conversation.streams.sorted(by: { $0.key < $1.key }) {
            throw Sim.Violation("X2", "a stream for \(strand) (\(stream.generation ?? "?")) is still drawn after every turn settled")
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
        for key in ["send", "daemonProgress", "lostRequest", "lostReply", "disconnect", "reattach", "maybeSent", "restoreDraft", "offeredBack", "unrelatedEntry", "duplicatePush", "reorderedPushes"] where (seen[key] ?? 0) == 0 {
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
