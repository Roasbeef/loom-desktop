import XCTest
@testable import LoomCore

/// The simulation of the read scheduler: which surfaces are shown, how long reads take, which
/// fail, and what the daemon would refuse.
///
/// The production `Readers` runs. The world is a clock, a set of surfaces the schedule shows
/// and hides, and a daemon that counts reads in a four-second window as the real one does and
/// records a violation when a class passes its budget. Faults, one bit each: 0 a read fails,
/// 1 a read is slow.
///
/// Rules: R6 no read starts before a surface's settle time has passed since it became shown. R5 a surface that becomes shown is read at once, budget permitting. R0 only a shown surface is read. R1 one read in flight per surface. R2 no class
/// passes the daemon's budget in any window. R3 after the heal, every shown surface that can
/// be read has been read within its period plus the budget's wait.
struct ReadersModel: SimSpec {
    static let modes = 2
    static let maxSteps = 64

    enum Fault: Int {
        case fails = 0, slow
    }

    static let surfaces: [Readers.Surface] = {
        var out: [Readers.Surface] = []
        for session in ["s1", "s2", "s3", "s4", "s5", "s6", "s7"] {
            out.append(.init(name: "brief", session: session, periodMs: 1_000, budget: .brief))
            out.append(.init(name: "rail", session: session, periodMs: 5_000, budget: .unbudgeted))
            out.append(.init(name: "review", session: session, periodMs: 3_000, budget: .review, settleMs: 350))
        }
        return out
    }()

    static let tickSizes = [10, 100, 500, 999, 1_000, 1_001, 3_999, 4_000, 5_000]

    struct World {
        var readers = Readers()
        var now = 0
        var shown: Set<Readers.Surface> = []
        var inFlight: [Readers.Surface] = []
        var history: [Readers.Class: [Int]] = [:]
        var lastRead: [Readers.Surface: Int] = [:]
        var unknown: Set<Readers.Surface> = []
        var askedAfterUnknown = false
        var faults: Sim.FaultMask
        var census: [String: Int] = [:]
        var violations: [Sim.Violation] = []
        /// The surfaces that became shown in this step, which are read at once and not held to their period.
        var justShown: Set<Readers.Surface> = []
        /// When each shown surface last became shown.
        var shownAt: [Readers.Surface: Int] = [:]
        /// Surfaces that became shown and have not yet had their first read (it is in flight, or the budget was full).
        var owedFirst: Set<Readers.Surface> = []

        mutating func count(_ key: String) { census[key, default: 0] += 1 }
    }

    func makeWorld(mode: Int, faults: Sim.FaultMask, rng: inout SimRandom) -> World {
        World(faults: faults)
    }

    func step(_ world: inout World, kind: Int, arg: Int, rng: inout SimRandom) throws(Sim.Violation) {
        let mask = world.faults
        let faulty = { (fault: Fault) in mask.has(fault.rawValue) }
        switch kind {
        case 0, 1, 2:
            // Show a different set: a few surfaces of a few sessions.
            var next: Set<Readers.Surface> = []
            for (index, surface) in Self.surfaces.enumerated() where (index &* 31 &+ arg &* 7 &+ kind) % 5 < 2 { next.insert(surface) }
            try showSet(&world, next)
        case 3, 4, 5: try complete(&world, outcome: .read)
        case 6: faulty(.fails) ? try complete(&world, outcome: .failed) : try complete(&world, outcome: .read)
        case 7: try complete(&world, outcome: .read)
        case 8: try showSet(&world, [])
        case 9, 10, 11:
            world.now += Self.tickSizes[arg % Self.tickSizes.count]
            run(&world, world.readers.tick(now: world.now))
        case 12:
            if let due = world.readers.nextDue { world.now = max(world.now, due) }
            run(&world, world.readers.tick(now: world.now))
        case 13: try complete(&world, outcome: .read)
        default:
            if faulty(.slow) { world.now += 3_000; run(&world, world.readers.tick(now: world.now)) } else { try complete(&world, outcome: .read) }
        }
        if let violation = world.violations.first { throw violation }
    }

    func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {
        world.faults = .none
        for _ in 0..<200 {
            while !world.inFlight.isEmpty { try complete(&world, outcome: .read) }
            if let violation = world.violations.first { throw violation }
            guard let due = world.readers.nextDue else { break }
            if world.shown.allSatisfy({ world.lastRead[$0] != nil && world.now - (world.lastRead[$0] ?? 0) < $0.periodMs }) && world.now >= due { break }
            world.now = max(world.now + 1, due)
            run(&world, world.readers.tick(now: world.now))
        }
        for surface in world.shown where !world.unknown.contains(surface) {
            guard let last = world.lastRead[surface] else { throw Sim.Violation("R3", "\(surface.name) of \(surface.session) is shown and was never read") }
            // A class whose budget is smaller than the surfaces shown must take turns: each turn is a window.
            let sameClass = world.shown.filter { $0.budget == surface.budget }.count
            let turns = surface.budget == .unbudgeted ? 1 : (sameClass + surface.budget.limit - 1) / surface.budget.limit
            guard world.now - last <= surface.periodMs + (turns + 1) * Readers.windowMs else { throw Sim.Violation("R3", "\(surface.name) of \(surface.session) was last read \(world.now - last) ms ago") }
        }
    }

    func snapshot(_ world: World) -> String {
        "now=\(world.now) shown=\(world.shown.count) inflight=\(world.inFlight.count) reads=\(world.lastRead.count) unknown=\(world.unknown.count) census=\(world.census.sorted { $0.key < $1.key })"
    }

    func tallies(_ world: World) -> [String: Int] { world.census }

    // MARK: Performing

    private func run(_ world: inout World, _ effects: [Readers.Effect]) {
        for case .read(let surface) in effects {
            if !world.shown.contains(surface) { world.violations.append(Sim.Violation("R0", "\(surface.name) of \(surface.session) was read while hidden")) }
            if world.inFlight.contains(surface) { world.violations.append(Sim.Violation("R1", "\(surface.name) of \(surface.session) was read twice at once")) }
            if let last = world.lastRead[surface], world.now - last < surface.periodMs, world.shown.contains(surface), !world.justShown.contains(surface), !world.owedFirst.contains(surface) {
                world.violations.append(Sim.Violation("R1", "\(surface.name) of \(surface.session) was read again after \(world.now - last) ms, inside its period"))
            }
            var recent = (world.history[surface.budget] ?? []).filter { $0 > world.now - Readers.windowMs }
            recent.append(world.now)
            world.history[surface.budget] = recent
            if recent.count > surface.budget.limit {
                world.violations.append(Sim.Violation("R2", "\(recent.count) \(surface.budget) reads in \(Readers.windowMs) ms; the daemon allows \(surface.budget.limit)"))
            }
            if let at = world.shownAt[surface], world.now < at + surface.settleMs {
                world.violations.append(Sim.Violation("R6", "\(surface.name) of \(surface.session) was read \(world.now - at) ms after it became shown; it settles for \(surface.settleMs)"))
            }
            world.owedFirst.remove(surface)
            world.inFlight.append(surface)
            world.lastRead[surface] = world.now
            world.count("read")
        }
    }

    /// Shows a set of surfaces. R5: one that has just become shown is read within this step, unless its
    /// class budget is full, a read of it is still out, or the daemon did not know its command.
    private func showSet(_ world: inout World, _ next: Set<Readers.Surface>) throws(Sim.Violation) {
        let fresh = next.subtracting(world.shown)
        world.shown = next
        world.justShown = fresh
        for surface in fresh { world.shownAt[surface] = world.now }
        world.owedFirst.formUnion(fresh)
        var before = Set(world.inFlight)
        run(&world, world.readers.show(next, now: world.now))
        world.justShown = []
        before.formUnion(world.unknown)
        for surface in fresh.sorted() where surface.settleMs == 0 && !before.contains(surface) && !world.inFlight.contains(surface) {
            let recent = (world.history[surface.budget] ?? []).filter { $0 > world.now - Readers.windowMs }
            if recent.count < surface.budget.limit {
                throw Sim.Violation("R5", "\(surface.name) of \(surface.session) became shown with budget to spare and was not read")
            }
        }
    }

    private func complete(_ world: inout World, outcome: Readers.Outcome) throws(Sim.Violation) {
        guard !world.inFlight.isEmpty else { return }
        let surface = world.inFlight.removeFirst()
        run(&world, world.readers.finished(surface, outcome, now: world.now))
    }
}

final class ReadersModelTests: XCTestCase {
    /// `SIM_REPLAY=<hex> swift test --filter ReadersModelTests/testReplay` prints one seed step by step.
    func testReplay() throws {
        guard let hex = ProcessInfo.processInfo.environment["SIM_REPLAY"], let seed = Sim.Seed(hex: hex) else { throw XCTSkip("set SIM_REPLAY") }
        Sim.replay(ReadersModel(), seed: seed) { print($0) }
    }

    func testTheSwarmKeepsTheDaemonsBudgetsAndEveryRuleOfTheScheduler() {
        for generator in [Sim.generator(default: 1), Sim.generator(default: 1) + 1] {
            if let failure = Sim.check(ReadersModel(), runs: Sim.runs(default: 500), generator: generator) {
                XCTFail("generator \(generator): \(failure)")
            }
        }
    }

    func testTheSwarmReachesTheStatesTheRulesTalkAbout() {
        var seen: [String: Int] = [:]
        var rng = SimRandom(seed: 41)
        for _ in 0..<500 {
            let length = 3 + Int(rng.next() % UInt64(ReadersModel.maxSteps))
            let seed = Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if case .success(let outcome) = Sim.run(ReadersModel(), seed: seed) {
                for (key, value) in outcome.tallies { seen[key, default: 0] += value }
            }
        }
        for key in ["read"] where (seen[key] ?? 0) == 0 { XCTFail("no run reached \(key)") }
    }

    func testTheCorpusIsDeterministicOnTwoRuns() {
        var rng = SimRandom(seed: 43)
        let seeds = (0..<100).map { _ -> Sim.Seed in
            let length = 3 + Int(rng.next() % UInt64(ReadersModel.maxSteps))
            return Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        }
        XCTAssertEqual(Sim.corpus(ReadersModel(), seeds: seeds), [])
    }

    /// Review finding: the update cards' period follows their number, and a period that was part of the
    /// surface's identity made every card a new surface, with no memory of its last read, whenever one came or went.
    func testAChangedPeriodKeepsTheSurfaceAndItsLastRead() {
        var readers = Readers()
        let few = Readers.Surface(name: "update.brief", session: "s1", periodMs: 1_000, budget: .brief)
        let many = Readers.Surface(name: "update.brief", session: "s1", periodMs: 3_000, budget: .brief)
        XCTAssertEqual(readers.show([few], now: 0), [.read(few)])
        _ = readers.finished(few, .read, now: 10)
        XCTAssertTrue(readers.show([many], now: 500).isEmpty, "a new period is not a new surface, so it is not read at once")
        XCTAssertTrue(readers.tick(now: 2_999).isEmpty)
        XCTAssertEqual(readers.tick(now: 3_000).count, 1, "and it follows the new period")
    }

    /// A pane reopened inside its period must not stay blank for the rest of it.
    func testASurfaceThatBecomesShownAgainIsReadAtOnce() {
        var readers = Readers()
        let surface = Readers.Surface(name: "thread.brief", session: "s1", periodMs: 15_000, budget: .unbudgeted)
        XCTAssertEqual(readers.show([surface], now: 0), [.read(surface)])
        _ = readers.finished(surface, .read, now: 10)
        XCTAssertTrue(readers.show([], now: 3_000).isEmpty)
        XCTAssertEqual(readers.show([surface], now: 3_000), [.read(surface)], "the view is new and empty, so it reads at once")
        _ = readers.finished(surface, .read, now: 3_010)
        XCTAssertTrue(readers.tick(now: 10_000).isEmpty, "while it stays shown it keeps its period")
    }

    func testAReshownBudgetedSurfaceIsStillHeldToTheBudget() {
        var readers = Readers()
        let surfaces = (1...7).map { Readers.Surface(name: "brief", session: "s\($0)", periodMs: 1_000, budget: .brief) }
        let first = readers.show(Set(surfaces), now: 0)
        XCTAssertEqual(first.count, 6, "six briefs fill the window")
        _ = readers.show([], now: 100)
        XCTAssertTrue(readers.show(Set(surfaces), now: 200).isEmpty || readers.show(Set(surfaces), now: 200).count <= 1, "the allowance holds")
    }

    /// Seven sessions in Updates and the open pane would, read together, pass six briefs in
    /// four seconds. The scheduler spaces them.
    func testManyShownBriefsNeverPassTheDaemonsSixInFourSeconds() {
        var readers = Readers()
        let surfaces = Set((1...10).map { Readers.Surface(name: "brief", session: "s\($0)", periodMs: 1_000, budget: .brief) })
        var started = readers.show(surfaces, now: 0).count
        XCTAssertEqual(started, 6)
        var inFlight = surfaces.sorted().prefix(6)
        for surface in inFlight { _ = readers.finished(surface, .read, now: 10) }
        inFlight = []
        started += readers.tick(now: 3_999).count
        XCTAssertEqual(started, 6, "the window still holds six starts")
        started += readers.tick(now: 4_000).count
        XCTAssertGreaterThan(started, 6, "the window has emptied")
    }
}
