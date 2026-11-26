import XCTest
import LoomKit
@testable import LoomCore

/// A dispatch against a daemon that loses replies, refuses and drops lanes.
///
/// The saga is the production `Dispatch`. The host performs one effect per op against a
/// `FakeControl`, honestly or with a fault, and a form retries with its own key as the sheet
/// does. Faults, one bit each: 0 the create reply is lost after the daemon applied it, 1 the
/// create refuses, 2 the open fails, 3 the first prompt is refused, 4 its reply is lost, 5 the
/// daemon ignores the worktree the form asked for.
///
/// Rules: one terminal outcome per attempt; every attempt of one form carries the same
/// request key (O4); the daemon holds at most one session per key; the first prompt is
/// written at most once per session (O2); and a dispatch whose session exists and whose prompt
/// was not acknowledged ends as `createdButUnsent` (H2).
struct DispatchModel: SimSpec {
    static let modes = 2
    static let maxSteps = 40

    enum Fault: Int {
        case createLost = 0, createRefused, openFails, promptRefused, promptLost, worktreeIgnored
    }

    struct World {
        var fake = FakeControl()
        var saga: Dispatch
        var queue: [Dispatch.Effect]
        var outcomes: [Dispatch.Outcome] = []
        var keys: Set<String> = []
        var promptWrites: [String: Int] = [:]
        var faults: Sim.FaultMask
        var attempts = 1
        var wantsWorktree: Bool
        var lastSend: Dispatch.SendResult?
        var ignored: Set<String> = []
        var census: [String: Int] = [:]
        let key: String

        mutating func count(_ name: String) { census[name, default: 0] += 1 }
    }

    func makeWorld(mode: Int, faults: Sim.FaultMask, rng: inout SimRandom) -> World {
        let saga = Dispatch(requestKey: "form-key", prompt: "go#")
        var fake = FakeControl()
        fake.socketOpen = true
        return World(fake: fake, saga: saga, queue: saga.start(), faults: faults, wantsWorktree: mode == 1, key: "form-key")
    }

    func step(_ world: inout World, kind: Int, arg: Int, rng: inout SimRandom) throws(Sim.Violation) {
        let mask = world.faults
        let faulty = { (fault: Fault) in mask.has(fault.rawValue) && arg % 2 == 0 }
        if kind == 15 { try retry(&world) } else { try perform(&world, faulty: faulty) }
        try check(world)
    }

    func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {
        // Heal: faults off. Each attempt that ended without the session sent is retried
        // with the same key until one succeeds or the budget runs out.
        world.faults = .none
        for _ in 0..<12 {
            while !world.queue.isEmpty { try perform(&world, faulty: { _ in false }) }
            if case .sent? = world.outcomes.last { break }
            if world.outcomes.isEmpty { break }
            try retry(&world)
        }
        guard !world.outcomes.isEmpty else { throw Sim.Violation("liveness", "no outcome") }
        let owned = world.fake.sessions.count
        guard owned <= world.keys.count else { throw Sim.Violation("O4", "\(owned) sessions for \(world.keys.count) keys") }
        try check(world)
    }

    func snapshot(_ world: World) -> String {
        "outcomes=\(world.outcomes) queue=\(world.queue) sessions=\(world.fake.sessions.map(\.id)) writes=\(world.promptWrites.sorted { $0.key < $1.key }) attempts=\(world.attempts) census=\(world.census.sorted { $0.key < $1.key })"
    }

    func tallies(_ world: World) -> [String: Int] { world.census }

    // MARK: Ops

    /// Performs the next effect and reports what the host saw.
    private func perform(_ world: inout World, faulty: (Fault) -> Bool) throws(Sim.Violation) {
        guard !world.queue.isEmpty else { return }
        let effect = world.queue.removeFirst()
        var events: [Dispatch.Event] = []
        switch effect {
        case .create(let key):
            world.keys.insert(key)
            if key != world.key { throw Sim.Violation("O4", "an attempt carried key \(key), not the form's \(world.key)") }
            if faulty(.createRefused) {
                events = [.createFailed(.refused("no capacity"))]
                world.count("createRefused")
            } else {
                let session = createdSession(&world, key: key)
                if faulty(.createLost) {
                    events = [.createFailed(.unknown)]
                    world.count("createLost")
                } else if world.wantsWorktree, faulty(.worktreeIgnored) {
                    world.ignored.insert(session)
                    events = [.createFailed(.worktreeNotHonoured(session: session))]
                    world.count("worktreeIgnored")
                } else {
                    events = [.created(session: session)]
                }
            }
        case .open(let session):
            if faulty(.openFails) {
                events = [.openFailed("the session did not open")]
                world.count("openFailed")
            } else {
                if let index = world.fake.sessions.firstIndex(where: { $0.id == session }) { world.fake.sessions[index].resident = true }
                events = [.opened]
            }
        case .refresh:
            events = [.refreshed]
        case .attach:
            events = [.attached]
        case .send:
            let session = world.fake.keys[world.key] ?? "?"
            world.promptWrites[session, default: 0] += 1
            if faulty(.promptRefused) {
                world.lastSend = .refused("busy")
                events = [.sendSettled(.refused("busy"))]
                world.count("promptRefused")
            } else if faulty(.promptLost) {
                world.lastSend = .unknown
                events = [.sendSettled(.unknown)]
                world.count("promptLost")
            } else {
                world.lastSend = .acknowledged
                events = [.sendSettled(.acknowledged)]
            }
        case .cleanUp(let session):
            world.fake.sessions.removeAll { $0.id == session }
            world.fake.keys[world.key] = nil
            events = [.cleanedUp]
        case .finish(let outcome):
            world.outcomes.append(outcome)
            world.count("finish:\(label(outcome))")
        }
        for event in events { world.queue += world.saga.apply(event) }
    }

    /// The sheet's retry: the same key, a fresh saga, after an attempt that did not send.
    private func retry(_ world: inout World) throws(Sim.Violation) {
        guard world.queue.isEmpty, let last = world.outcomes.last else { return }
        if case .sent = last { return }
        world.saga = Dispatch(requestKey: world.key, prompt: "go#")
        world.queue = world.saga.start()
        world.attempts += 1
        world.count("retry")
    }

    private func createdSession(_ world: inout World, key: String) -> String {
        _ = world.fake.receive(command: Frames.text(["v": 2, "id": 1, "cmd": "sessions.create", "body": ["request_key": .string(key)]]))
        world.fake.owed = 0
        return world.fake.keys[key] ?? "?"
    }

    private func label(_ outcome: Dispatch.Outcome) -> String {
        switch outcome {
        case .sent: return "sent"
        case .createdButUnsent: return "createdButUnsent"
        case .unknownCreate: return "unknownCreate"
        case .failed: return "failed"
        }
    }

    // MARK: Invariants

    private func check(_ world: World) throws(Sim.Violation) {
        // One terminal outcome per attempt.
        guard world.outcomes.count <= world.attempts else { throw Sim.Violation("liveness", "\(world.outcomes.count) outcomes for \(world.attempts) attempts") }

        // O2: the first prompt is written at most once per session by one attempt.
        for (session, writes) in world.promptWrites where writes > world.attempts {
            throw Sim.Violation("O2", "the first prompt crossed the wire \(writes) times for \(session) in \(world.attempts) attempts")
        }
        guard world.fake.sessions.count <= world.keys.count else { throw Sim.Violation("O4", "a second session was made for one key") }

        // H2: an attempt that ended with the prompt not acknowledged never reports `sent`.
        if let outcome = world.outcomes.last, case .sent(let session) = outcome {
            if world.promptWrites[session, default: 0] == 0 { throw Sim.Violation("H2", "sent was reported but no prompt was written") }
            if world.lastSend != .acknowledged { throw Sim.Violation("H2", "sent was reported though the first prompt ended as \(String(describing: world.lastSend))") }
        }

        // A session the daemon made without the worktree asked for is removed, not left listed.
        if world.queue.isEmpty, !world.outcomes.isEmpty {
            for session in world.ignored where world.fake.sessions.contains(where: { $0.id == session }) {
                throw Sim.Violation("cleanup", "session \(session) was made without its worktree and was left behind")
            }
        }
    }
}

final class DispatchModelTests: XCTestCase {
    func testTheSwarmKeepsEveryRuleOfADispatch() {
        for generator in [Sim.generator(default: 1), Sim.generator(default: 1) + 1] {
            if let failure = Sim.check(DispatchModel(), runs: Sim.runs(default: 3_000), generator: generator) {
                XCTFail("generator \(generator): \(failure)")
            }
        }
    }

    func testTheSwarmReachesEveryOutcome() {
        var seen: [String: Int] = [:]
        var rng = SimRandom(seed: 9)
        for _ in 0..<3_000 {
            let length = 3 + Int(rng.next() % UInt64(DispatchModel.maxSteps))
            let seed = Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if case .success(let outcome) = Sim.run(DispatchModel(), seed: seed) {
                for (key, value) in outcome.tallies { seen[key, default: 0] += value }
            }
        }
        for key in ["finish:sent", "finish:createdButUnsent", "finish:unknownCreate", "finish:failed", "createLost", "promptRefused", "promptLost", "retry", "worktreeIgnored"] where (seen[key] ?? 0) == 0 {
            XCTFail("no run reached \(key); reached \(seen.sorted { $0.key < $1.key })")
        }
    }

    func testAFirstPromptThatIsRefusedOrLostEndsAsCreatedButUnsentAndIsNeverResent() {
        for result in [Dispatch.SendResult.refused("busy"), .unknown] {
            var saga = Dispatch(requestKey: "k", prompt: "go")
            XCTAssertEqual(saga.start(), [.create(requestKey: "k")])
            XCTAssertEqual(saga.apply(.created(session: "s1")), [.open(session: "s1")])
            XCTAssertEqual(saga.apply(.opened), [.refresh])
            XCTAssertEqual(saga.apply(.refreshed), [.attach(session: "s1")])
            XCTAssertEqual(saga.apply(.attached), [.send(prompt: "go")])
            let ended = saga.apply(.sendSettled(result))
            guard ended.count == 1, case .finish(let outcome) = ended[0], case .createdButUnsent(let session, _) = outcome else { return XCTFail("\(ended)") }
            XCTAssertEqual(session, "s1")
            XCTAssertTrue(saga.apply(.sendSettled(.acknowledged)).isEmpty, "a finished saga ignores a late event")
        }
    }

    func testALostCreateReplyKeepsTheKeySoARetryRecoversTheSession() {
        var saga = Dispatch(requestKey: "k", prompt: "go")
        _ = saga.start()
        XCTAssertEqual(saga.apply(.createFailed(.unknown)), [.finish(.unknownCreate(requestKey: "k"))])
        XCTAssertEqual(Dispatch(requestKey: "k", prompt: "go").start(), [.create(requestKey: "k")])
    }
}
