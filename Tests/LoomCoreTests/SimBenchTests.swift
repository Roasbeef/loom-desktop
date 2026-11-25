import XCTest

/// Measures how many schedules each simulation runs per second, and prints the figures.
/// It runs only with `SIM_BENCH=1`, so the gate stays quick:
/// `SIM_BENCH=1 SIM_RUNS=2000 swift test --filter SimBenchTests`.
final class SimBenchTests: XCTestCase {
    private func bench<S: SimSpec>(_ name: String, _ spec: S, runs: Int) {
        var rng = SimRandom(seed: 0xB3C4)
        var steps = 0
        let start = ContinuousClock.now
        for _ in 0..<runs {
            let length = 3 + Int(rng.next() % UInt64(S.maxSteps))
            let seed = Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if case .success(let outcome) = Sim.run(spec, seed: seed) { steps += outcome.steps }
        }
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(String(format: "bench %@ runs=%d seconds=%.3f schedules_per_second=%.0f steps_per_second=%.0f", name, runs, seconds, Double(runs) / seconds, Double(steps) / seconds))
    }

    func testThroughput() throws {
        guard let which = ProcessInfo.processInfo.environment["SIM_BENCH"] else { throw XCTSkip("set SIM_BENCH=1 (or a model name)") }
        let runs = Sim.runs(default: 2_000)
        let all = which == "1"
        if all || which == "lane" { bench("lane", LaneModel(), runs: runs) }
        if all || which == "session" { bench("session", SessionModel(), runs: runs) }
        if all || which == "daemon" { bench("daemon", DaemonModel(), runs: runs) }
        if all || which == "dispatch" { bench("dispatch", DispatchModel(), runs: runs) }
        if all || which == "appcore" { bench("appcore", AppCoreModel(), runs: runs) }
        if all || which == "readers" { bench("readers", ReadersModel(), runs: min(runs, 500)) }
        if all || which == "form" { bench("form", DispatchFormModel(), runs: runs) }
    }
}
