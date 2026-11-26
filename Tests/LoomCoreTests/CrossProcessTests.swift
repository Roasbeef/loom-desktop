import CryptoKit
import XCTest

/// Writes a digest of every final snapshot of a fixed set of seeds, so two separate processes can be compared.
///
/// Swift seeds each process's hashing differently unless `SWIFT_DETERMINISTIC_HASHING` is set, so
/// a dictionary or set iterated in production code, or in the harness, gives different orders in
/// two processes while giving the same order twice in one. The in-process double run cannot see
/// that. `scripts/cross-process.sh` runs this test twice, once with the variable set and once
/// without, and compares the files. It runs only when `SIM_DIGEST_OUT` names a file.
final class CrossProcessTests: XCTestCase {
    private func digest<S: SimSpec>(_ name: String, _ spec: S, runs: Int, generator: UInt64) -> String {
        var rng = SimRandom(seed: generator)
        var lines: [String] = []
        for _ in 0..<runs {
            let length = 3 + Int(rng.next() % UInt64(S.maxSteps))
            let seed = Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            let snapshot: String
            switch Sim.run(spec, seed: seed) {
            case .success(let outcome): snapshot = outcome.snapshot
            case .failure(let failure): snapshot = "FAIL \(failure.violation) step \(failure.step)"
            }
            let hash = SHA256.hash(data: Data(snapshot.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            lines.append("\(name) \(seed.hex) \(hash)")
        }
        return lines.joined(separator: "\n")
    }

    func testWriteTheDigest() throws {
        guard let path = ProcessInfo.processInfo.environment["SIM_DIGEST_OUT"] else { throw XCTSkip("set SIM_DIGEST_OUT=<file>") }
        let runs = Sim.runs(default: 300)
        let generator = Sim.generator(default: 1)
        let parts = [
            digest("lane", LaneModel(), runs: runs, generator: generator),
            digest("session", SessionModel(), runs: runs, generator: generator),
            digest("daemon", DaemonModel(), runs: runs, generator: generator),
            digest("dispatch", DispatchModel(), runs: runs, generator: generator),
            digest("appcore", AppCoreModel(), runs: runs, generator: generator),
            digest("readers", ReadersModel(), runs: min(runs, 100), generator: generator),
            digest("form", DispatchFormModel(), runs: runs, generator: generator),
        ]
        try parts.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
