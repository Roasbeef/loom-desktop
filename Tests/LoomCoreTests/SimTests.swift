import XCTest

/// The harness is itself code that can be wrong, so these tests run it on a spec with
/// a known bug and check that it finds, shrinks and replays it.
final class SimTests: XCTestCase {
    /// A counter that breaks when kind 3 follows kind 5. Everything else is honest.
    struct Counter: SimSpec {
        struct World { var last = -1; var hits = 0 }
        static let modes = 2
        static let maxSteps = 24

        func makeWorld(mode: Int, faults: Sim.FaultMask, rng: inout SimRandom) -> World { World() }

        func step(_ world: inout World, kind: Int, arg: Int, rng: inout SimRandom) throws(Sim.Violation) {
            if world.last == 5, kind == 3 { throw Sim.Violation("X1", "three after five") }
            world.last = kind
            world.hits += 1
        }

        func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {}
        func snapshot(_ world: World) -> String { "\(world.last) \(world.hits)" }
    }

    func testTheSwarmFindsAKnownBugAndShrinksItToTwoOps() throws {
        let failure = try XCTUnwrap(Sim.check(Counter(), runs: 20_000, generator: 1))
        XCTAssertEqual(failure.violation.tag, "X1")
        XCTAssertEqual(failure.shrunk.ops.count, 2, "shrinking by deletion leaves the two ops that matter: \(failure)")
        let again = Sim.run(Counter(), seed: failure.shrunk)
        guard case .failure(let replay) = again else { return XCTFail("the shrunk seed must still fail") }
        XCTAssertEqual(replay.violation.tag, "X1")
    }

    func testASeedRoundTripsThroughHexAndShortSeedsRunWithEveryFaultOn() throws {
        let seed = Sim.Seed(bytes: [1, 0x0F, 0x80, 0x35, 0x43])
        XCTAssertEqual(Sim.Seed(hex: seed.hex), seed)
        XCTAssertEqual(seed.mode, 1)
        XCTAssertEqual(seed.faults.bits, 0x800F)
        XCTAssertEqual(Sim.Seed(bytes: [0]).faults, .all)
        XCTAssertNil(Sim.Seed(hex: "abc"))
    }

    func testTheCorpusReportsASeedThatDiffersBetweenTwoRuns() {
        final class Counted: @unchecked Sendable { var calls = 0 }
        let counted = Counted()
        struct Flaky: SimSpec {
            let counted: Counted
            struct World { var value = 0 }
            static let modes = 1
            static let maxSteps = 4
            func makeWorld(mode: Int, faults: Sim.FaultMask, rng: inout SimRandom) -> World { counted.calls += 1; return World(value: counted.calls) }
            func step(_ world: inout World, kind: Int, arg: Int, rng: inout SimRandom) throws(Sim.Violation) {}
            func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {}
            func snapshot(_ world: World) -> String { "\(world.value)" }
        }
        XCTAssertEqual(Sim.corpus(Flaky(counted: counted), seeds: [Sim.Seed(bytes: [0, 0, 0, 1])]).count, 1)
        XCTAssertEqual(Sim.corpus(Counter(), seeds: [Sim.Seed(bytes: [0, 0, 0, 1, 2])]).count, 0)
    }

    func testTheOrderSeedFollowsTheOpsAndTheShuffleIsReproducible() {
        let a = Sim.Seed(bytes: [0, 0, 0, 1, 2, 3])
        let b = Sim.Seed(bytes: [0, 0, 0, 1, 2, 4])
        XCTAssertNotEqual(a.orderSeed, b.orderSeed)
        var one = SimRandom(seed: a.orderSeed), two = SimRandom(seed: a.orderSeed)
        var x = Array(0..<10), y = Array(0..<10)
        one.shuffle(&x)
        two.shuffle(&y)
        XCTAssertEqual(x, y)
        XCTAssertNotEqual(x, Array(0..<10))
    }
}
