import XCTest
import LoomKit
@testable import LoomCore

/// Model-based tests over the pure lane, ported from Loom's
/// `packages/tui/test/session_channel_property_test.gleam` and tagged the same way.
///
/// The oracle never reads the lane's state. It rebuilds what a daemon would know
/// from the frames the lane wrote: which request is outstanding, which snapshot
/// fragment the lane was granted, which mutations crossed the wire. The lane's
/// updates are then held to that account. The generated server answers whatever
/// request is outstanding, so a schedule is a list of abstract events whose meaning
/// depends on the state each arrives in, and any sub-list is another valid schedule.
///
/// Time is part of the schedule. The lane reads no clock: each transition is passed
/// the oracle's `now`, which starts at zero and moves only on a generated tick.
///
/// The rules, by tag (the Gleam test's own):
///
/// - I1 a correlated command is written only while no request awaits its reply, except
///   the `snapshot_next` that a transfer's own reply grants.
/// - I2 request identities strictly increase.
/// - I3 a mutation crosses the wire at most once, and a lane that fails while it awaits
///   the reply reports an unknown outcome for exactly that identity, once.
/// - I4 a waiting mutation is later written once or reported not sent once, never both.
/// - I5 nothing is written after the close, there is one close, and a closed lane is inert.
/// - I6 one `snapshot_next` per granted fragment, naming the granted transfer and index,
///   written in the step that granted it.
/// - I7 a reply whose `reply_to` is stale produces no update and closes the lane.
/// - I8 a pushed frame allocates no identity, spends no credit and cannot fail the lane.
/// - L1 a well-formed answer never fails the lane and yields exactly its own update.
/// - L2 a notice at or above the cut, received while a request was in flight, is captured
///   at the lane's next ready transition.
/// - L3 an idle lane with a cut issues its catch-up once its refresh interval has passed:
///   250 ms until a pushed frame has reached it, 5 s after.
/// - L4 an in-flight request fails the lane on the first tick at or past its deadline
///   (10 s for a command, 30 s for a capture, not extended by credits), and not before.
/// - L5 admission: a closed lane refuses, an observer's mutation is refused once the role
///   is known, and a mutation before the first cut waits.
/// - N1 `nextDue` is exact. A tick one millisecond before it changes nothing, a tick at it
///   acts, and a lane that names none is left unchanged by a tick however late.
///
/// Two obligations are narrower than a reader might expect, because the lane documents
/// them that way: a waiting read is reported failed rather than not sent, and a close the
/// client asked for reports the same outcomes as a failure, without a `failed` reason.
struct LaneModel: SimSpec {
    static let modes = 2
    static let maxSteps = 48

    /// Fault classes, one bit each. An op whose class is off acts honestly.
    enum Fault: Int {
        case refuse = 0, stale, garbage, disconnect, close, notice
    }

    /// The tick sizes straddle the 250 ms refresh and the 10 s and 30 s deadlines.
    static let tickSizes = [20, 100, 249, 250, 251, 1_000, 4_999, 5_000, 9_999, 10_000, 10_001, 29_999, 30_000, 30_001, 60_000]

    struct Written: Equatable {
        let id: Int
        let cmd: String
        let body: JSONValue
    }

    /// What the oracle knows is outstanding, from what the lane wrote.
    enum Await: Equatable {
        case none
        case begin(id: Int, cmd: String, ticket: Lane.Ticket?)
        case fragment(id: Int, ticket: Lane.Ticket?)
        case reply(id: Int, cmd: String, ticket: Lane.Ticket)
    }

    enum Settled: Equatable {
        case waiting, sent(Int), done
    }

    struct Ticket: Equatable {
        let command: String
        let kind: Lane.Kind
        var state: Settled
    }

    struct Transfer: Equatable {
        var snapshot: String
        var window: String
        var cmd: String
        var ticket: Lane.Ticket?
        var records: Int
        var delivered = 0
        var nextSeq: Int
    }

    struct World {
        var lane: Lane
        var now = 0
        var mode: Int
        var faults: Sim.FaultMask

        // The oracle's account of the daemon, built from the frames the lane wrote.
        var written: [Written] = []
        var lastID = 0
        var await: Await = .none
        var deadline = 0
        var grant: (snapshot: String, index: Int)?
        var transfer: Transfer?
        var tickets: [Lane.Ticket: Ticket] = [:]
        var waiting: [Lane.Ticket] = []
        var promptWrites: [String: Int] = [:]
        var closed = false
        var shuts = 0
        var holdsCut = false
        var cursor = 0
        var pushed = false
        var refreshAt = 0
        var owed = false
        var head = 1
        var role = ""
        var counter = 0
        var cause: Lane.Trigger = .requested
        /// True while a tick is being checked, which is the only thing that makes the refresh capture.
        var ticking = false
        var census: [String: Int] = [:]

        mutating func count(_ key: String) { census[key, default: 0] += 1 }
    }

    // MARK: Spec

    func makeWorld(mode: Int, faults: Sim.FaultMask, rng: inout SimRandom) -> World {
        var world = World(lane: Lane.start(sessionID: "s1", admission: .roleGated, now: 0), mode: mode, faults: faults)
        world.role = mode == 0 ? "operator" : "observer"
        world.deadline = Lane.captureDeadlineMs
        var outs = world.lane.takeOutputs()
        try? absorb(&world, outs: &outs, updates: [])
        return world
    }

    func step(_ world: inout World, kind: Int, arg: Int, rng: inout SimRandom) throws(Sim.Violation) {
        let mask = world.faults
        let faulty = { (fault: Fault) in mask.has(fault.rawValue) }
        switch kind {
        case 0: try submit(&world, Lane.Command("prompt", body: ["text": .string("p\(world.counter)")], kind: .mutation))
        case 1: try submit(&world, Lane.Command("notes", kind: .read))
        case 2: try submit(&world, Lane.Command("history", body: ["after_seq": 0], kind: .transfer))
        case 3, 4, 5: try answer(&world, choice: arg)
        case 6: faulty(.refuse) ? try refuse(&world) : try answer(&world, choice: arg)
        case 7: faulty(.stale) ? try stale(&world, offset: arg) : try answer(&world, choice: arg)
        case 8: faulty(.garbage) ? try garbage(&world) : try answer(&world, choice: arg)
        case 9: faulty(.disconnect) ? try disconnect(&world) : try answer(&world, choice: arg)
        case 10: faulty(.notice) ? try oldNotice(&world) : try notice(&world, advance: arg % 3)
        case 11: try notice(&world, advance: 1 + arg % 3)
        case 12: try push(&world, event: arg % 2 == 0 ? "stream_delta" : "presence")
        case 13, 14: try tick(&world, ms: Self.tickSizes[arg % Self.tickSizes.count])
        default:
            if arg % 2 == 0 {
                faulty(.close) ? try closeFromHost(&world) : try cancelWaiting(&world)
            } else {
                try cancelWaiting(&world)
            }
        }
        try quiet(world)
    }

    func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {
        // The final retirement: whatever the lane still owes is settled by closing it.
        if !world.closed { try closeFromHost(&world) }
        for (ticket, state) in world.tickets.sorted(by: { $0.key < $1.key }) where state.state != .done {
            throw Sim.Violation("I4", "ticket \(ticket) (\(state.command)) was never settled by the close")
        }
        guard world.shuts == 1 else { throw Sim.Violation("I5", "\(world.shuts) closes at the end of the run") }
    }

    func snapshot(_ world: World) -> String {
        "\(world.lane)|written=\(world.written.map { "\($0.id):\($0.cmd)" })|now=\(world.now)|census=\(world.census.sorted(by: { $0.key < $1.key }))"
    }

    func tallies(_ world: World) -> [String: Int] { world.census }

    // MARK: Events

    private func submit(_ world: inout World, _ command: Lane.Command) throws(Sim.Violation) {
        world.counter += 1
        let before = world.written.count
        let wasClosed = world.closed
        let admitted = world.lane.submit(command, now: world.now)
        var outs = world.lane.takeOutputs()
        let ticket = admitted.ticket
        world.tickets[ticket] = Ticket(command: command.name, kind: command.kind, state: .waiting)

        if wasClosed {
            guard case .notSent = admitted.disposition else { throw Sim.Violation("L5", "a closed lane admitted \(command.name): \(admitted.disposition)") }
            world.tickets[ticket]?.state = .done
            world.count("closedRefused")
            guard outs.isEmpty, world.written.count == before else { throw Sim.Violation("I5", "a closed lane wrote after submit") }
            return
        }
        let refusedByRole = command.kind == .mutation && world.holdsCut && world.role == "observer"
        if refusedByRole {
            guard case .notSent = admitted.disposition else { throw Sim.Violation("L5", "an observer's mutation was admitted: \(admitted.disposition)") }
            world.tickets[ticket]?.state = .done
            world.count("observerRefused")
            guard outs.isEmpty else { throw Sim.Violation("L5", "a refused mutation was written") }
            return
        }
        let idle = world.await == .none && world.waiting.isEmpty
        switch admitted.disposition {
        case .sent:
            guard idle else { throw Sim.Violation("I1", "\(command.name) was written while a request awaits its reply") }
            world.count("sentNow")
        case .waiting:
            guard !idle else { throw Sim.Violation("L5", "\(command.name) waited on an idle lane") }
            world.waiting.append(ticket)
            world.count("waiting")
        case .notSent(let reason):
            throw Sim.Violation("L5", "\(command.name) was refused on a healthy lane: \(reason)")
        }
        try absorb(&world, outs: &outs, updates: admitted.updates, ticketForNext: ticket)
    }

    /// The server answers whatever request is outstanding, well-formed.
    private func answer(_ world: inout World, choice: Int) throws(Sim.Violation) {
        var frame: String
        switch world.await {
        case .none:
            return
        case .begin(let id, let cmd, let ticket):
            let window = cmd == "subscribe" ? "recent" : cmd == "catch_up" ? "catch_up" : "history"
            let next = window == "history" ? max(1, world.head / 2) : world.head
            world.transfer = Transfer(
                snapshot: "t\(id)", window: window, cmd: cmd, ticket: ticket,
                records: 1 + choice % 2, nextSeq: next
            )
            frame = Frames.begin(replyTo: id, snapshot: "t\(id)", window: window, nextSeq: next, session: "s1", role: world.role)
            world.grant = ("t\(id)", 0)
            world.await = .none
        case .fragment(let id, _):
            guard var transfer = world.transfer else {
                throw Sim.Violation("I6", "a fragment was awaited with no transfer")
            }
            if transfer.delivered < transfer.records {
                let index = transfer.delivered
                let first = index == 0
                frame = Frames.chunk(
                    replyTo: id, snapshot: transfer.snapshot, index: index,
                    kind: first ? "metadata" : "entry", record: first ? "m" : "e\(index)",
                    seq: first ? nil : transfer.nextSeq - 1,
                    payload: first ? ["cells": []] : .object(["id": .string("e\(index)"), "seq": .int(Int64(transfer.nextSeq - 1)), "parentId": .null, "type": "custom"])
                )
                transfer.delivered += 1
                world.transfer = transfer
                world.grant = (transfer.snapshot, transfer.delivered)
            } else {
                frame = Frames.end(replyTo: id, snapshot: transfer.snapshot, nextSeq: transfer.nextSeq)
                world.grant = nil
                world.await = .none
            }
        case .reply(let id, let cmd, _):
            frame = cmd == "prompt"
                ? Frames.envelope(replyTo: id, event: "ack", body: ["status": "admitted"])
                : Frames.envelope(replyTo: id, event: "snapshot", body: ["mode": "notes"])
            world.await = .none
            if cmd == "prompt" { world.refreshAt = world.now }
        }

        let updates = world.lane.receive(frame, now: world.now)
        var outs = world.lane.takeOutputs()
        try expectNoFailure(updates, "L1")
        try finishAnswer(&world, updates: updates)
        try absorb(&world, outs: &outs, updates: updates)
    }

    /// What a completed exchange must have produced, by what it answered.
    private func finishAnswer(_ world: inout World, updates: [Lane.Update]) throws(Sim.Violation) {
        // A reply to a command settles its ticket with exactly one `replied`.
        for update in updates {
            switch update {
            case .replied(let ticket, _):
                guard var state = world.tickets[ticket], case .sent = state.state else { throw Sim.Violation("L1", "replied for unsent ticket \(ticket)") }
                state.state = .done
                world.tickets[ticket] = state
            case .cut(let ticket, let cut, let trigger):
                try finishTransfer(&world, ticket: ticket, cut: cut, trigger: trigger)
            default:
                break
            }
        }
    }

    private func finishTransfer(_ world: inout World, ticket: Lane.Ticket?, cut: Cut, trigger: Lane.Trigger) throws(Sim.Violation) {
        guard let transfer = world.transfer else { throw Sim.Violation("L1", "a cut arrived with no transfer open") }
        guard cut.nextSeq == transfer.nextSeq, cut.window == transfer.window else { throw Sim.Violation("L1", "the cut is not the transfer the daemon sent") }
        guard ticket == transfer.ticket else { throw Sim.Violation("L1", "the cut names ticket \(String(describing: ticket)), expected \(String(describing: transfer.ticket))") }
        world.transfer = nil
        if let ticket {
            world.tickets[ticket]?.state = .done
            guard trigger == .requested else { throw Sim.Violation("L1", "a caller's transfer carries trigger \(trigger)") }
        } else {
            let expected: Lane.Trigger = transfer.cmd == "subscribe" ? .requested : world.cause
            guard trigger == expected else { throw Sim.Violation("L1", "a capture carries trigger \(trigger), expected \(expected)") }
            world.holdsCut = true
            world.refreshAt = world.now + (world.pushed ? Lane.pushingRefreshMs : Lane.pollingRefreshMs)
            world.count(world.pushed ? "refreshedPushing" : "refreshedPolling")
        }
        if !["history", "lineage", "decided", "escalations"].contains(transfer.window) {
            world.cursor = max(world.cursor, transfer.nextSeq)
        }
    }

    private func refuse(_ world: inout World) throws(Sim.Violation) {
        let frame: String
        switch world.await {
        case .none:
            return
        case .begin(let id, let cmd, _):
            frame = Frames.error(replyTo: id, code: "busy")
            if cmd == "catch_up", world.holdsCut {
                // A refused catch-up on a lane holding a cut is retried at the next refresh.
                world.await = .none
                world.refreshAt = world.now + (world.pushed ? Lane.pushingRefreshMs : Lane.pollingRefreshMs)
                world.count("refusedCapture")
                let updates = world.lane.receive(frame, now: world.now)
                var outs = world.lane.takeOutputs()
                try expectNoFailure(updates, "L1")
                try absorb(&world, outs: &outs, updates: updates)
                return
            }
            if cmd == "subscribe" || cmd == "catch_up" {
                try closing(&world, frame: frame, why: "refused capture")
                return
            }
            world.await = .none
            try settleRefusal(&world, frame: frame)
        case .fragment:
            try closing(&world, frame: Frames.error(replyTo: awaitID(world), code: "stale_snapshot"), why: "refused fragment")
        case .reply(let id, _, _):
            world.await = .none
            try settleRefusal(&world, frame: Frames.error(replyTo: id, code: "busy"))
        }
    }

    private func settleRefusal(_ world: inout World, frame: String) throws(Sim.Violation) {
        let updates = world.lane.receive(frame, now: world.now)
        var outs = world.lane.takeOutputs()
        var refused = 0
        for update in updates {
            if case .refused(let ticket, let code, _, _) = update {
                refused += 1
                guard code == "busy", var state = world.tickets[ticket], case .sent = state.state else { throw Sim.Violation("L1", "a refusal named the wrong ticket \(ticket)") }
                state.state = .done
                world.tickets[ticket] = state
            }
        }
        guard refused == 1 else { throw Sim.Violation("L1", "a refusal produced \(refused) refused updates") }
        try expectNoFailure(updates, "L1")
        world.count("refused")
        try absorb(&world, outs: &outs, updates: updates)
    }

    private func awaitID(_ world: World) -> Int {
        switch world.await {
        case .none: return 0
        case .begin(let id, _, _), .fragment(let id, _), .reply(let id, _, _): return id
        }
    }

    private func stale(_ world: inout World, offset: Int) throws(Sim.Violation) {
        guard !world.closed else { return }
        let id = awaitID(world)
        let wrong = [id + 1, max(0, id - 1), 999, id + 2][offset % 4]
        let reply = world.await == .none ? 7 : wrong
        let frame = Frames.envelope(replyTo: reply == id ? id + 1 : reply, event: "snapshot", body: ["mode": "notes"])
        world.count("staleClose")
        try closing(&world, frame: frame, why: "a stale reply")
    }

    private func garbage(_ world: inout World) throws(Sim.Violation) {
        guard !world.closed else { return }
        world.count("garbageClose")
        try closing(&world, frame: "not json at all", why: "garbage")
    }

    private func disconnect(_ world: inout World) throws(Sim.Violation) {
        guard !world.closed else { return }
        let updates = world.lane.receive(failed: .closed("the socket ended"))
        var outs = world.lane.takeOutputs()
        try expectClosure(&world, updates: updates, outs: &outs, why: "disconnect")
    }

    /// Feeds a frame the lane must refuse by closing, and checks the closure.
    private func closing(_ world: inout World, frame: String, why: String) throws(Sim.Violation) {
        let updates = world.lane.receive(frame, now: world.now)
        var outs = world.lane.takeOutputs()
        for update in updates {
            switch update {
            case .replied, .cut, .refused:
                throw Sim.Violation("I7", "\(why) produced a presentation update: \(update)")
            default:
                break
            }
        }
        try expectClosure(&world, updates: updates, outs: &outs, why: why)
    }

    private func closeFromHost(_ world: inout World) throws(Sim.Violation) {
        guard !world.closed else {
            let updates = world.lane.close()
            let outs = world.lane.takeOutputs()
            guard updates.isEmpty, outs.isEmpty else { throw Sim.Violation("I5", "closing a closed lane did something") }
            return
        }
        let updates = world.lane.close()
        var outs = world.lane.takeOutputs()
        try expectClosure(&world, updates: updates, outs: &outs, why: "close")
    }

    private func cancelWaiting(_ world: inout World) throws(Sim.Violation) {
        let updates = world.lane.cancelWaiting(reason: "cancelled")
        let outs = world.lane.takeOutputs()
        guard outs.isEmpty else { throw Sim.Violation("I4", "cancelling wrote a frame") }
        var seen: [Lane.Ticket] = []
        for update in updates {
            switch update {
            case .notSent(let ticket, _), .failed(let ticket, _, _):
                seen.append(ticket)
                world.tickets[ticket]?.state = .done
            default:
                throw Sim.Violation("I4", "cancelling produced \(update)")
            }
        }
        guard seen == world.waiting else { throw Sim.Violation("I4", "cancelled \(seen), waiting was \(world.waiting)") }
        world.waiting = []
    }

    private func notice(_ world: inout World, advance: Int) throws(Sim.Violation) {
        world.head += advance
        try pushedFrame(&world, Frames.envelope(replyTo: nil, event: "committed", seq: world.head - 1, body: ["strand": "main"]), seq: world.head - 1)
    }

    private func oldNotice(_ world: inout World) throws(Sim.Violation) {
        guard world.cursor > 0 else { return try push(&world, event: "stream_delta") }
        try pushedFrame(&world, Frames.envelope(replyTo: nil, event: "committed", seq: world.cursor - 1, body: ["strand": "main"]), seq: world.cursor - 1)
    }

    private func push(_ world: inout World, event: String) throws(Sim.Violation) {
        try pushedFrame(&world, Frames.envelope(replyTo: nil, event: event, body: ["strand": "main"]), seq: nil, metadata: event == "presence")
    }

    /// I8 and L2: a push spends nothing, cannot fail the lane, and moves a catch-up earlier.
    private func pushedFrame(_ world: inout World, _ frame: String, seq: Int?, metadata: Bool = false) throws(Sim.Violation) {
        guard !world.closed else {
            let updates = world.lane.receive(frame, now: world.now)
            guard updates.isEmpty, world.lane.takeOutputs().isEmpty else { throw Sim.Violation("I5", "a push reached a closed lane") }
            return
        }
        let idBefore = world.lastID
        let busy = world.await != .none
        let updates = world.lane.receive(frame, now: world.now)
        var outs = world.lane.takeOutputs()
        world.pushed = true
        try expectNoFailure(updates, "I8")
        guard updates.contains(where: { if case .pushed = $0 { return true }; return false }) else { throw Sim.Violation("I8", "a push was not reported") }
        if let seq {
            guard updates.contains(.noticed(seq: seq)) else { throw Sim.Violation("I8", "a commit notice was not reported as noticed") }
        }
        let wantsCapture = world.holdsCut && (metadata || (seq.map { $0 >= world.cursor } ?? false))
        if wantsCapture, !busy {
            world.count("noticeCaptured")
        } else if wantsCapture {
            world.owed = true
            world.count("noticeDeferred")
        }
        try absorb(&world, outs: &outs, updates: updates)
        let wrote = world.lastID != idBefore
        if wrote, !(wantsCapture && !busy) { throw Sim.Violation("I8", "a push allocated an identity it had no right to") }
        if wantsCapture, !busy, !wrote { throw Sim.Violation("L2", "a notice at the cut was not captured by an idle lane") }
    }

    private func tick(_ world: inout World, ms: Int) throws(Sim.Violation) {
        world.now += ms
        let due = world.lane.nextDue

        // N1: a tick before the instant `nextDue` names changes nothing, and a tick at it acts.
        if let due {
            if due > 0 {
                var early = world.lane
                let updates = early.tick(now: due - 1)
                guard updates.isEmpty, early == world.lane else { throw Sim.Violation("N1", "a tick at \(due - 1) acted before nextDue \(due)") }
            }
            var onTime = world.lane
            let updates = onTime.tick(now: due)
            guard !updates.isEmpty || onTime != world.lane else { throw Sim.Violation("N1", "a tick at nextDue \(due) did nothing") }
        } else {
            var late = world.lane
            let updates = late.tick(now: world.now + 1_000_000)
            guard updates.isEmpty, late == world.lane else { throw Sim.Violation("N1", "a lane naming no due instant changed on a late tick") }
        }
        if world.closed {
            guard due == nil else { throw Sim.Violation("N1", "a closed lane named a due instant") }
        }

        let before = world.lane
        let updates = world.lane.tick(now: world.now)
        var outs = world.lane.takeOutputs()
        if world.closed {
            guard updates.isEmpty, outs.isEmpty, before == world.lane else { throw Sim.Violation("I5", "a closed lane ticked") }
            return
        }

        // L4 and L3: the oracle's own deadline and refresh instants.
        if world.await != .none {
            if world.now >= world.deadline {
                guard world.lane.phase == .closed else { throw Sim.Violation("L4", "no failure at \(world.now), deadline \(world.deadline)") }
                world.count("deadlineClose")
                try expectClosure(&world, updates: updates, outs: &outs, why: "deadline")
            } else {
                guard updates.isEmpty, outs.isEmpty, world.lane.phase != .closed else { throw Sim.Violation("L4", "failed at \(world.now) before deadline \(world.deadline)") }
            }
            return
        }
        let wantsRefresh = world.holdsCut && world.refreshAt <= world.now && world.waiting.isEmpty
        if wantsRefresh {
            let idBefore = world.lastID
            world.ticking = true
            defer { world.ticking = false }
            try absorb(&world, outs: &outs, updates: updates)
            guard world.lastID != idBefore, world.written.last?.cmd == "catch_up" else { throw Sim.Violation("L3", "no catch-up at \(world.now), refresh was due at \(world.refreshAt)") }
            world.count("tickRefresh")
        } else {
            guard updates.isEmpty, outs.isEmpty else { throw Sim.Violation("L3", "a tick at \(world.now) acted before the refresh at \(world.refreshAt)") }
        }
    }

    // MARK: The oracle's reading of what the lane wrote

    /// Reads the frames the lane wrote in a step, in order, and holds them to I1, I2, I3, I5 and I6.
    private func absorb(_ world: inout World, outs: inout [Lane.Out], updates: [Lane.Update], ticketForNext: Lane.Ticket? = nil) throws(Sim.Violation) {
        var sentTickets: [Lane.Ticket] = []
        var notSentTickets: [Lane.Ticket] = []
        for update in updates {
            switch update {
            case .sent(let ticket, _): sentTickets.append(ticket)
            case .notSent(let ticket, _): notSentTickets.append(ticket)
            default: break
            }
        }
        for out in outs {
            switch out {
            case .shut:
                world.shuts += 1
            case .transmit(let text):
                guard !world.closed, world.shuts == 0 else { throw Sim.Violation("I5", "a frame was written after the close") }
                guard let frame = Frames.decode(command: text) else { throw Sim.Violation("I1", "the lane wrote a frame that is not a command") }
                guard frame.id > world.lastID else { throw Sim.Violation("I2", "id \(frame.id) after \(world.lastID)") }
                world.lastID = frame.id
                world.written.append(Written(id: frame.id, cmd: frame.cmd, body: frame.body))
                if frame.cmd == "snapshot_next" {
                    guard let grant = world.grant, frame.body["snapshot_id"]?.string == grant.snapshot, frame.body["index"]?.int == grant.index else {
                        throw Sim.Violation("I6", "snapshot_next \(frame.body) is not the granted fragment \(String(describing: world.grant))")
                    }
                    world.grant = nil
                    world.await = .fragment(id: frame.id, ticket: world.transfer?.ticket)
                    continue
                }
                guard world.await == .none else { throw Sim.Violation("I1", "\(frame.cmd) written while \(world.await) awaits its reply") }
                guard world.grant == nil else { throw Sim.Violation("I6", "a command was written instead of the granted fragment") }
                try register(&world, frame: frame, sentTickets: &sentTickets)
            }
        }
        // I6: a grant not spent in the step that made it is a stalled transfer.
        if world.grant != nil, !world.closed, outs.allSatisfy({ if case .shut = $0 { return true }; return false }) || outs.isEmpty {
            throw Sim.Violation("I6", "the fragment granted to \(String(describing: world.grant)) was not asked for")
        }
        try settleWaiting(&world, sent: sentTickets, notSent: notSentTickets)
        if world.shuts > 1 { throw Sim.Violation("I5", "\(world.shuts) closes") }
        outs = []
    }

    /// Records the command the lane just wrote as the outstanding request.
    private func register(_ world: inout World, frame: (id: Int, cmd: String, body: JSONValue), sentTickets: inout [Lane.Ticket]) throws(Sim.Violation) {
        switch frame.cmd {
        case "subscribe", "catch_up":
            world.await = .begin(id: frame.id, cmd: frame.cmd, ticket: nil)
            world.deadline = world.now + Lane.captureDeadlineMs
            if frame.cmd == "catch_up" {
                world.cause = world.ticking ? .refreshed : .notified
                world.owed = false
                guard frame.body["from_seq"]?.int == world.cursor else { throw Sim.Violation("L2", "catch_up from \(String(describing: frame.body["from_seq"])), cursor \(world.cursor)") }
            }
        default:
            guard let ticket = oracleTicket(world, for: frame, sent: sentTickets) else {
                throw Sim.Violation("I4", "\(frame.cmd) \(frame.id) was written for no admitted ticket")
            }
            if let index = sentTickets.firstIndex(of: ticket) { sentTickets.remove(at: index) }
            if let index = world.waiting.firstIndex(of: ticket) { world.waiting.remove(at: index) }
            var state = world.tickets[ticket]
            if case .sent = state?.state { throw Sim.Violation("I3", "ticket \(ticket) written twice") }
            guard state?.state == .waiting else { throw Sim.Violation("I4", "ticket \(ticket) written after it was settled") }
            state?.state = .sent(frame.id)
            world.tickets[ticket] = state
            if frame.cmd == "prompt" {
                let label = frame.body["text"]?.string ?? ""
                world.promptWrites[label, default: 0] += 1
                guard world.promptWrites[label] == 1 else { throw Sim.Violation("I3", "mutation \(label) crossed the wire twice") }
            }
            world.deadline = world.now + Lane.commandDeadlineMs
            world.await = state?.kind == .transfer
                ? .begin(id: frame.id, cmd: frame.cmd, ticket: ticket)
                : .reply(id: frame.id, cmd: frame.cmd, ticket: ticket)
        }
    }

    /// Finds the ticket a written command belongs to: the oldest waiting one of that name,
    /// or the one just admitted, which is written in the same step.
    private func oracleTicket(_ world: World, for frame: (id: Int, cmd: String, body: JSONValue), sent: [Lane.Ticket]) -> Lane.Ticket? {
        let candidates = world.tickets
            .filter { $0.value.command == frame.cmd && $0.value.state == .waiting }
            .map(\.key)
            .sorted()
        if let queued = world.waiting.first(where: { candidates.contains($0) }) { return queued }
        return candidates.first
    }

    /// I4: each waiting command is later written (`sent`) or reported `notSent`, once, in FIFO order.
    private func settleWaiting(_ world: inout World, sent: [Lane.Ticket], notSent: [Lane.Ticket]) throws(Sim.Violation) {
        for ticket in sent {
            guard case .sent? = world.tickets[ticket].map(\.state) else { throw Sim.Violation("I4", "sent update for ticket \(ticket) with no frame") }
        }
        for ticket in notSent {
            guard world.tickets[ticket]?.state == .waiting || world.tickets[ticket]?.state == .done else { throw Sim.Violation("I4", "notSent for a ticket already on the wire") }
            if let index = world.waiting.firstIndex(of: ticket) { world.waiting.remove(at: index) }
            world.tickets[ticket]?.state = .done
        }
    }

    /// I3, I4, I5: every closure settles what the lane owes, once, and closes the socket once.
    private func expectClosure(_ world: inout World, updates: [Lane.Update], outs: inout [Lane.Out], why: String) throws(Sim.Violation) {
        guard world.lane.phase == .closed else { throw Sim.Violation("I5", "\(why) left the lane \(world.lane.phase)") }
        let closes = updates.filter { if case .closed = $0 { return true }; return false }
        guard closes.count == 1 else { throw Sim.Violation("I5", "\(why) reported \(closes.count) closes") }
        guard outs == [.shut] else { throw Sim.Violation("I5", "\(why) wrote \(outs), expected one shut") }
        world.shuts += 1
        world.closed = true
        world.count("closed:\(why)")

        // What was in flight.
        var unknown = 0
        var settled: Set<Lane.Ticket> = []
        for update in updates {
            switch update {
            case .unknown(let ticket, let command, let id):
                unknown += 1
                guard case .reply(let expectedID, let expectedCommand, let expectedTicket) = world.await, expectedID == id, expectedCommand == command, expectedTicket == ticket, command == "prompt" else {
                    throw Sim.Violation("I3", "unknown outcome for \(command) \(id) but the oracle awaits \(world.await)")
                }
                world.count("unknownReported")
                settled.insert(ticket)
            case .failed(let ticket, _, _):
                settled.insert(ticket)
            case .notSent(let ticket, _):
                guard world.waiting.contains(ticket) else { throw Sim.Violation("I4", "notSent for ticket \(ticket), which was not waiting") }
                settled.insert(ticket)
            case .closed, .pushed, .noticed:
                break
            default:
                throw Sim.Violation("I7", "a closure produced \(update)")
            }
        }
        if case .reply(let id, let command, _) = world.await, command == "prompt" {
            guard unknown == 1 else { throw Sim.Violation("I3", "mutation \(command) \(id) in flight at the close was reported unknown \(unknown) times") }
        } else {
            guard unknown == 0 else { throw Sim.Violation("I3", "unknown outcome reported with no mutation in flight") }
        }
        switch world.await {
        case .reply(_, _, let ticket), .begin(_, _, let ticket?), .fragment(_, let ticket?):
            guard settled.contains(ticket) else { throw Sim.Violation("I3", "the in-flight ticket \(ticket) was not settled by the close") }
        case .none, .begin, .fragment:
            break
        }
        for ticket in world.waiting {
            guard settled.contains(ticket) else { throw Sim.Violation("I4", "waiting ticket \(ticket) was not settled by the close") }
        }
        for ticket in settled { world.tickets[ticket]?.state = .done }
        world.waiting = []
        world.await = .none
        world.grant = nil
        world.transfer = nil
        outs = []
    }

    private func expectNoFailure(_ updates: [Lane.Update], _ tag: String) throws(Sim.Violation) {
        for update in updates {
            switch update {
            case .unknown, .failed, .closed:
                throw Sim.Violation(tag, "a well-formed frame ended the lane: \(update)")
            default:
                break
            }
        }
    }

    /// Checked after every step: a closed lane is inert and its due instant is nil.
    private func quiet(_ world: World) throws(Sim.Violation) {
        if world.closed {
            guard world.lane.phase == .closed, world.lane.nextDue == nil else { throw Sim.Violation("I5", "a closed lane is not inert") }
        }
    }
}

/// Runs the model as a campaign per role, as the Gleam test does, from fixed generator seeds.
final class LaneModelTests: XCTestCase {
    func testTheOperatorAndObserverCampaignsKeepEveryRule() throws {
        let spec = LaneModel()
        if let failure = Sim.check(spec, runs: 6_000, generator: 1) {
            XCTFail("\(failure)")
        }
        if let failure = Sim.check(spec, runs: 6_000, generator: 2) {
            XCTFail("\(failure)")
        }
    }

    func testTheCampaignsReachEveryStateTheRulesTalkAbout() {
        var seen: [String: Int] = [:]
        var rng = SimRandom(seed: 7)
        for _ in 0..<3_000 {
            let length = 3 + Int(rng.next() % UInt64(LaneModel.maxSteps))
            let seed = Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if case .success(let outcome) = Sim.run(LaneModel(), seed: seed) {
                for (key, value) in outcome.tallies { seen[key, default: 0] += value }
            }
        }
        let required = [
            "sentNow", "waiting", "closedRefused", "observerRefused", "refused", "refusedCapture", "staleClose",
            "garbageClose", "noticeCaptured", "noticeDeferred", "deadlineClose", "unknownReported", "tickRefresh",
            "refreshedPolling", "refreshedPushing", "closed:disconnect", "closed:close",
        ]
        for key in required where (seen[key] ?? 0) == 0 {
            XCTFail("no run reached \(key); reached \(seen.sorted(by: { $0.key < $1.key }))")
        }
    }

    func testTheCorpusIsDeterministicOnTwoRuns() {
        var rng = SimRandom(seed: 99)
        let seeds = (0..<200).map { _ -> Sim.Seed in
            let length = 3 + Int(rng.next() % UInt64(LaneModel.maxSteps))
            return Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        }
        XCTAssertEqual(Sim.corpus(LaneModel(), seeds: seeds), [])
    }
}
