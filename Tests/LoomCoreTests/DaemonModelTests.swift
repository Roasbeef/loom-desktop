import XCTest
import LoomKit
@testable import LoomCore

/// The simulation of one daemon connection: the control lane, the poll saga, the catalogue
/// and the attach decisions, against a `FakeControl`.
///
/// | Component | In the simulation |
/// | --- | --- |
/// | `Daemon`, `ControlLane` | production |
/// | the control socket | simulated FIFO with faults at both ends |
/// | the daemon | `FakeControl` |
/// | the clock | virtual |
/// | lanes of sessions | `Host.lanes`: an id, the epoch it attached under, and whether it is up |
/// | the shell's reconnect and attach | `Host`: performs `open` and `attach` as the app does |
///
/// Faults, one bit each: 0 the reply to a command is lost, 1 the socket closes mid-poll, 2 the
/// daemon restarts (a new epoch, same sessions), 3 a lane ends under a session, 4 the daemon refuses
/// the poll's commands, 5 the daemon is down and the socket cannot be opened, 6 a controller that was replaced reports its end late.
///
/// Rules: B6 no lane of an earlier epoch survives the hello of a new one. B7 after the heal,
/// every resident session with an approval has a lane and every ended lane is replaced. H6 the
/// control lane never writes a background command while an owner command waits. Liveness: the
/// catalogue equals the daemon's, and the next due instant is the idle poll and nothing else.
struct DaemonModel: SimSpec {
    static let modes = 2
    static let maxSteps = 64

    enum Fault: Int {
        case lostReply = 0, closeSocket, restart, laneEnds, refusePoll, daemonDown, lateEnd
    }

    static let tickSizes = [10, 100, 500, 1_999, 2_000, 2_001, 3_000, 6_000, 16_000]

    struct HostLane: Equatable {
        var epoch: String
        var up: Bool
        var generation: Int
    }

    struct World {
        var daemon: Daemon
        var fake = FakeControl()
        var now = 0
        var wire: [String] = []
        var lanes: [String: HostLane] = [:]
        var faults: Sim.FaultMask
        var markers = 0
        var ownerQueued: Set<Int> = []
        var settled: [Int: Daemon.Settlement] = [:]
        var tags: Set<Int> = []
        var helloEpoch: String?
        var census: [String: Int] = [:]
        var opens = 0
        var endedLanes: Set<String> = []
        var generation = 0
        /// Lanes that were replaced or dropped, whose controller may still report an end.
        var retired: [(session: String, generation: Int)] = []

        mutating func count(_ key: String) { census[key, default: 0] += 1 }
    }

    // MARK: Spec

    func makeWorld(mode: Int, faults: Sim.FaultMask, rng: inout SimRandom) -> World {
        var fake = FakeControl()
        if mode == 1 {
            for index in 1...3 {
                fake.sessions.append(.init(id: "s\(index)", resident: true, approvals: index == 2 ? 1 : 0, createdAt: index))
            }
        }
        var world = World(daemon: Daemon(), fake: fake, faults: faults)
        let effects = world.daemon.start(now: 0)
        perform(&world, effects)
        return world
    }

    func step(_ world: inout World, kind: Int, arg: Int, rng: inout SimRandom) throws(Sim.Violation) {
        let mask = world.faults
        let faulty = { (fault: Fault) in mask.has(fault.rawValue) }
        switch kind {
        case 0:
            world.fake.counter += 1
            world.fake.sessions.append(.init(id: "w\(world.fake.counter)", resident: true, approvals: arg % 3 == 0 ? 1 : 0, createdAt: 100 + world.fake.counter))
            world.fake.version += 1
        case 1:
            if let index = world.fake.sessions.indices.first(where: { world.fake.sessions[$0].resident }) {
                world.fake.sessions[index].resident = false
                world.fake.version += 1
            }
        case 2:
            if !world.fake.sessions.isEmpty { world.fake.sessions.remove(at: arg % world.fake.sessions.count); world.fake.version += 1 }
        case 3:
            if !world.fake.sessions.isEmpty {
                let index = arg % world.fake.sessions.count
                world.fake.sessions[index].approvals = world.fake.sessions[index].approvals > 0 ? 0 : 1
                world.fake.version += 1
            }
        case 4: try deliver(&world)
        case 5: while !world.wire.isEmpty { try deliver(&world) }
        case 6: try tick(&world, ms: Self.tickSizes[arg % Self.tickSizes.count])
        case 7: try jump(&world)
        case 8: faulty(.laneEnds) ? endLane(&world, arg: arg) : try deliver(&world)
        case 9: faulty(.restart) ? restart(&world) : try deliver(&world)
        case 10: faulty(.closeSocket) ? closeSocket(&world) : try deliver(&world)
        case 11: faulty(.lostReply) ? lose(&world) : try deliver(&world)
        case 12: ownerCommand(&world)
        case 13: backgroundReview(&world)
        case 14: world.wire += world.fake.releaseReview()
        default:
            if arg % 3 == 1, faulty(.refusePoll) {
                world.fake.refusePolls = true
                world.count("refusePoll")
            } else if arg % 3 == 2, faulty(.lateEnd), let old = world.retired.randomElementDeterministic(arg) {
                // A controller that was detached or replaced reports its end late.
                world.daemon.laneEnded(old.session, generation: old.generation)
                world.count("lateEnd")
            } else if arg % 3 == 2, faulty(.daemonDown) {
                world.fake.isUp = false
                world.count("daemonDown")
            } else {
                try deliver(&world)
            }
        }
        try check(&world)
    }

    func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {
        world.faults = .none
        for _ in 0..<300 {
            world.wire += world.fake.releaseReview()
            world.fake.refusePolls = false
            if !world.fake.isUp { world.fake.isUp = true }
            while !world.wire.isEmpty { try deliver(&world) }
            try check(&world)
            if settled(world) { break }
            let due = world.daemon.nextDue ?? world.now + 1_000
            world.now = max(world.now, due)
            try tickNow(&world)
        }
        guard settled(world) else {
            throw Sim.Violation("liveness", "never settled: connection=\(world.daemon.connection) wire=\(world.wire.count) retry=\(String(describing: world.daemon.retryAt))")
        }
        let truth = world.fake.sessions.sorted { $0.id < $1.id }.map(\.id)
        let known = world.daemon.sessions.map(\.id).sorted()
        guard truth == known else { throw Sim.Violation("liveness", "the catalogue \(known) is not the daemon's \(truth)") }
        for session in world.fake.sessions where session.resident {
            let wanted = session.approvals > 0 || world.lanes[session.id] != nil
            if wanted, world.lanes[session.id]?.up != true {
                throw Sim.Violation("B7", "resident session \(session.id) (approvals \(session.approvals)) has no lane after the heal")
            }
        }
        for id in world.tags.sorted() where world.settled[id] == nil {
            throw Sim.Violation("liveness", "command \(id) was never settled")
        }
    }

    func snapshot(_ world: World) -> String {
        let lanes = world.lanes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.epoch):\($0.value.up)" }
        return [
            "now=\(world.now) conn=\(world.daemon.connection) epoch=\(String(describing: world.daemon.epoch)) ticks=\(world.daemon.ticks)",
            "sessions=\(world.daemon.sessions.map(\.id)) lanes=\(lanes)",
            "fake=\(world.fake.sessions.map { "\($0.id)\($0.resident)\($0.approvals)" }) epoch=\(world.fake.epoch)",
            "wire=\(world.wire.count) census=\(world.census.sorted { $0.key < $1.key })",
        ].joined(separator: "\n")
    }

    func tallies(_ world: World) -> [String: Int] { world.census }

    // MARK: Ops

    private func deliver(_ world: inout World) throws(Sim.Violation) {
        guard !world.wire.isEmpty else { return }
        guard world.daemon.isConnected || world.daemon.connection == .connecting else {
            world.wire = []
            return
        }
        let frame = world.wire.removeFirst()
        if let envelope = try? EventEnvelope.decode(frame), envelope.replyTo != nil { world.fake.owed = max(0, world.fake.owed - 1) }
        perform(&world, world.daemon.receive(frame, now: world.now))
    }

    private func tick(_ world: inout World, ms: Int) throws(Sim.Violation) {
        world.now += ms
        try tickNow(&world)
    }

    private func jump(_ world: inout World) throws(Sim.Violation) {
        if let due = world.daemon.nextDue { world.now = max(world.now, due) }
        try tickNow(&world)
    }

    private func tickNow(_ world: inout World) throws(Sim.Violation) {
        if let due = world.daemon.nextDue, due <= world.now { perform(&world, world.daemon.tick(now: world.now)) }
    }

    private func endLane(_ world: inout World, arg: Int) {
        let ups = world.lanes.filter { $0.value.up }.keys.sorted()
        guard !ups.isEmpty else { return }
        let id = ups[arg % ups.count]
        world.lanes[id]?.up = false
        world.endedLanes.insert(id)
        world.daemon.laneEnded(id, generation: world.lanes[id]?.generation ?? 0)
        world.count("laneEnded")
    }

    private func restart(_ world: inout World) {
        world.fake.restart()
        world.wire = []
        perform(&world, world.daemon.receive(failed: .closed("the daemon restarted"), now: world.now))
        world.count("restart")
    }

    private func closeSocket(_ world: inout World) {
        guard world.daemon.isConnected else { return }
        world.wire = []
        world.fake.socketOpen = false
        perform(&world, world.daemon.receive(failed: .closed("the socket ended"), now: world.now))
        world.count("closeSocket")
    }

    private func lose(_ world: inout World) {
        guard !world.wire.isEmpty else { return }
        world.wire.removeFirst()
        world.count("lostReply")
    }

    /// A person's action, written before any background command queued after it.
    private func ownerCommand(_ world: inout World) {
        world.markers += 1
        let marker = world.markers
        world.ownerQueued.insert(marker)
        world.tags.insert(marker)
        perform(&world, world.daemon.submit(
            .init("sessions.create", body: ["request_key": .string("k\(marker % 3)"), "marker": .int(Int64(marker))], priority: .owner),
            tag: marker, now: world.now
        ))
        world.count("ownerCommand")
    }

    private func backgroundReview(_ world: inout World) {
        world.markers += 1
        let marker = world.markers
        world.tags.insert(marker)
        perform(&world, world.daemon.submit(.init("sessions.review", body: ["marker": .int(Int64(marker))], priority: .background), tag: marker, now: world.now))
        world.count("review")
    }

    // MARK: Performing effects

    private func perform(_ world: inout World, _ effects: [Daemon.Effect]) {
        var pendingFailure = false
        defer { _ = pendingFailure }
        for effect in effects {
            switch effect {
            case .open:
                world.opens += 1
                world.fake.socketOpen = false
                if world.fake.isUp {
                    world.wire = world.fake.open()
                } else {
                    // The socket cannot be opened. The host reports that as the end of one.
                    world.wire = []
                    pendingFailure = true
                }
            case .transmit(let text):
                if let command = Frames.decode(command: text) {
                    let marker = command.body["marker"]?.int
                    if command.cmd == "sessions.create", let marker { world.ownerQueued.remove(marker) }

                    // H6: a background command written while an owner command waits is the
                    // head-of-line blocking the priority exists to remove.
                    if command.cmd != "sessions.create", !world.ownerQueued.isEmpty {
                        world.fake.violations.append(Sim.Violation("H6", "\(command.cmd) was written while owner commands \(world.ownerQueued.sorted()) waited"))
                    }
                }
                world.wire += world.fake.receive(command: text)
            case .shut:
                world.fake.socketOpen = false
                world.wire = []
            case .state, .catalogue:
                break
            case .attach(let id, let inheriting):
                // A lane that ended is replaced by one that takes over what it held, and one that did not end is not.
                if inheriting == .previous, !world.endedLanes.contains(id) {
                    world.fake.violations.append(Sim.Violation("B7", "session \(id) was attached again with inheritance though its lane had not ended"))
                }
                if world.endedLanes.remove(id) != nil, inheriting != .previous {
                    world.fake.violations.append(Sim.Violation("B7", "session \(id) lost its lane and was attached fresh, dropping what the old lane held"))
                }
                if let old = world.lanes[id] { world.retired.append((id, old.generation)) }
                world.generation += 1
                world.lanes[id] = HostLane(epoch: world.fake.epoch, up: true, generation: world.generation)
                world.daemon.laneAttached(id, generation: world.generation)
                world.count(inheriting == .previous ? "reattach" : "attach")
            case .detachAll:
                for (id, lane) in world.lanes { world.retired.append((id, lane.generation)) }
                world.lanes = [:]
                world.endedLanes = []
                world.count("detachAll")
            case .due:
                world.count("due")
            case .settled(let tag, let settlement):
                world.settled[tag] = settlement
                world.ownerQueued.remove(tag)
            }
        }
        if pendingFailure {
            perform(&world, world.daemon.receive(failed: .closed("the daemon is down"), now: world.now))
        }
    }

    // MARK: Invariants

    private func check(_ world: inout World) throws(Sim.Violation) {
        if let violation = world.fake.violations.first { throw violation }

        // B6: no lane of an earlier epoch survives a new epoch's hello.
        if world.daemon.isConnected, let epoch = world.daemon.epoch {
            for (id, lane) in world.lanes where lane.up && lane.epoch != epoch && lane.epoch != world.fake.epoch {
                throw Sim.Violation("B6", "session \(id) keeps a lane from epoch \(lane.epoch) under epoch \(epoch)")
            }
            for (id, lane) in world.lanes where lane.epoch != epoch {
                throw Sim.Violation("B6", "session \(id) keeps a lane from epoch \(lane.epoch) under epoch \(epoch)")
            }
        }
    }

    private func settled(_ world: World) -> Bool {
        world.daemon.isConnected && !world.daemon.isBusy && world.wire.isEmpty && world.fake.held == nil && world.daemon.ownerWaiting == false
            && world.daemon.sessions.map(\.id).sorted() == world.fake.sessions.map(\.id).sorted()
            && world.fake.sessions.allSatisfy { session in
                !session.resident || ((session.approvals > 0 || world.lanes[session.id] != nil) ? world.lanes[session.id]?.up == true : true)
            }
            && world.daemon.epoch == world.fake.epoch
    }
}

final class DaemonModelTests: XCTestCase {
    /// `SIM_REPLAY=<hex> swift test --filter DaemonModelTests/testReplay` prints one seed step by step.
    func testReplay() throws {
        guard let hex = ProcessInfo.processInfo.environment["SIM_REPLAY"], let seed = Sim.Seed(hex: hex) else { throw XCTSkip("set SIM_REPLAY") }
        Sim.replay(DaemonModel(), seed: seed) { print($0) }
    }

    func testTheSwarmKeepsEveryRuleOfTheDaemonConnection() {
        for generator in [Sim.generator(default: 1), Sim.generator(default: 1) + 1] {
            if let failure = Sim.check(DaemonModel(), runs: Sim.runs(default: 1_500), generator: generator) {
                XCTFail("generator \(generator): \(failure)")
            }
        }
    }

    func testTheSwarmReachesTheStatesTheRulesTalkAbout() {
        var seen: [String: Int] = [:]
        var rng = SimRandom(seed: 3)
        for _ in 0..<1_500 {
            let length = 3 + Int(rng.next() % UInt64(DaemonModel.maxSteps))
            let seed = Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if case .success(let outcome) = Sim.run(DaemonModel(), seed: seed) {
                for (key, value) in outcome.tallies { seen[key, default: 0] += value }
            }
        }
        for key in ["attach", "reattach", "detachAll", "restart", "closeSocket", "lostReply", "ownerCommand", "review", "laneEnded", "due", "refusePoll", "daemonDown", "lateEnd"] where (seen[key] ?? 0) == 0 {
            XCTFail("no run reached \(key); reached \(seen.sorted { $0.key < $1.key })")
        }
    }

    func testTheCorpusIsDeterministicOnTwoRuns() {
        var rng = SimRandom(seed: 21)
        let seeds = (0..<300).map { _ -> Sim.Seed in
            let length = 3 + Int(rng.next() % UInt64(DaemonModel.maxSteps))
            return Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        }
        XCTAssertEqual(Sim.corpus(DaemonModel(), seeds: seeds), [])
    }
}

private extension Array {
    /// An element chosen by `index`, or nil when there is none: the schedule picks, not a random source.
    func randomElementDeterministic(_ index: Int) -> Element? { isEmpty ? nil : self[index % count] }
}
