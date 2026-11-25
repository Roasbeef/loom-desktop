import Foundation

/// The deterministic simulation harness: a seeded swarm over a spec, with shrinking.
///
/// This is a Swift port of the parts of Loom's `statem` that matter here, shaped by
/// the DST method. A spec builds a world (the production core, the simulated daemon
/// and a virtual clock), then executes one scripted step per seed byte and checks its
/// invariants after every step. The same seed always produces the same run, so a
/// failure is a reproducible bug report that names its seed, run, step and tag.
///
/// ## Seed format
///
/// ```
/// byte 0       mode        (byte % modes selects a configuration of production)
/// bytes 1..2   fault mask  (one bit per fault class, little-endian)
/// bytes 3..    ops         (truncated to the spec's step limit)
/// op = value % 16 selects a kind, value / 16 is its argument
/// ```
///
/// A seed shorter than the header runs with every fault class on. An op whose
/// fault class is masked off performs an honest action, so every seed makes
/// progress. The order seed, which breaks ties between events due at the same
/// instant, is a hash of the op bytes, so deleting an op while shrinking changes it.
/// Any sub-list of a schedule is still a valid schedule.
enum Sim {
    /// A broken rule. `tag` is what a failure is shrunk against, so shrinking keeps
    /// the same rule failing, and what a corpus names (`I3`, `T3`, `O1`).
    struct Violation: Error, Equatable, CustomStringConvertible {
        let tag: String
        let detail: String
        var description: String { "\(tag): \(detail)" }

        init(_ tag: String, _ detail: String) {
            self.tag = tag
            self.detail = detail
        }
    }

    /// One bit per fault class. Each spec names its own classes.
    struct FaultMask: Equatable, Hashable, CustomStringConvertible {
        var bits: UInt16

        static let all = FaultMask(bits: .max)
        static let none = FaultMask(bits: 0)

        func has(_ bit: Int) -> Bool { bits & (1 << UInt16(bit)) != 0 }
        var description: String { String(bits, radix: 2).leftPad(16) }
    }

    /// A decoded seed.
    struct Seed: Equatable, CustomStringConvertible {
        var bytes: [UInt8]

        var mode: Int { bytes.first.map(Int.init) ?? 0 }
        var faults: FaultMask {
            bytes.count < 3 ? .all : FaultMask(bits: UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        }
        var ops: [UInt8] { bytes.count > 3 ? Array(bytes[3...]) : [] }

        /// A hash of the op bytes, which seeds tie-breaking and any choice the spec makes.
        var orderSeed: UInt64 {
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in ops {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
            return hash ^ UInt64(mode) << 56 ^ UInt64(faults.bits) << 32
        }

        var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

        init(bytes: [UInt8]) { self.bytes = bytes }

        init?(hex: String) {
            guard hex.count % 2 == 0 else { return nil }
            var out: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                out.append(byte)
                index = next
            }
            bytes = out
        }

        var description: String { hex }
    }

    /// Where a run stopped: the step that broke a rule, and the rule.
    struct Stop: Error {
        let step: Int
        let violation: Violation
    }

    /// What one clean run reports.
    struct Outcome: Equatable {
        var snapshot: String
        var steps: Int
        var tallies: [String: Int]
    }

    /// One failing run, with the seed shrunk against the same tag.
    struct Failure: CustomStringConvertible {
        var seed: Seed
        var shrunk: Seed
        var run: Int
        var step: Int
        var violation: Violation

        var description: String {
            "violation \(violation) at run \(run) step \(step)\n  seed   \(seed.hex)\n  shrunk \(shrunk.hex)"
        }
    }

    /// Runs one seed. The spec's `step` throws on the first broken rule, and the
    /// result says which step it was.
    static func run<S: SimSpec>(_ spec: S, seed: Seed) -> Result<Outcome, Stop> {
        var rng = SimRandom(seed: seed.orderSeed)
        var world = spec.makeWorld(mode: seed.mode % S.modes, faults: seed.faults, rng: &rng)
        var steps = 0
        do {
            for byte in seed.ops.prefix(S.maxSteps) {
                try spec.step(&world, kind: Int(byte % 16), arg: Int(byte / 16), rng: &rng)
                steps += 1
            }
            try spec.finish(&world, rng: &rng)
        } catch {
            return .failure(Stop(step: steps, violation: error))
        }
        return .success(Outcome(snapshot: spec.snapshot(world), steps: steps, tallies: spec.tallies(world)))
    }

    /// Generates seeds from a generator seed and runs each until one fails. Each
    /// seed is `3 + n` random bytes, `n` up to the spec's step limit.
    static func check<S: SimSpec>(_ spec: S, runs: Int, generator: UInt64) -> Failure? {
        var rng = SimRandom(seed: generator)
        for run in 0..<runs {
            let length = 3 + Int(rng.next() % UInt64(S.maxSteps))
            let seed = Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if case .failure(let failure) = Sim.run(spec, seed: seed) {
                let shrunk = shrink(spec, seed: seed, tag: failure.violation.tag)
                return Failure(seed: seed, shrunk: shrunk, run: run, step: failure.step, violation: failure.violation)
            }
        }
        return nil
    }

    /// Runs a fixed corpus twice and compares every snapshot. A mismatch means the
    /// harness failed to control an order, or production used unordered iteration.
    static func corpus<S: SimSpec>(_ spec: S, seeds: [Seed]) -> [String] {
        var problems: [String] = []
        for seed in seeds {
            switch (Sim.run(spec, seed: seed), Sim.run(spec, seed: seed)) {
            case (.success(let a), .success(let b)):
                if a != b { problems.append("seed \(seed.hex) is not deterministic:\n\(a.snapshot)\n--- vs ---\n\(b.snapshot)") }
            case (.failure(let a), .failure(let b)):
                problems.append("seed \(seed.hex) fails (\(a.violation), step \(a.step))" + (a.violation == b.violation ? "" : " and differently on a second run: \(b.violation)"))
            case (.failure(let a), _), (_, .failure(let a)):
                problems.append("seed \(seed.hex) fails on only one of two runs: \(a.violation)")
            }
        }
        return problems
    }

    /// Deletes runs of ops, then fault bits, while the same tag keeps failing.
    static func shrink<S: SimSpec>(_ spec: S, seed: Seed, tag: String, budget: Int = 3_000) -> Seed {
        var best = seed
        var remaining = budget
        func fails(_ candidate: Seed) -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            if case .failure(let failure) = Sim.run(spec, seed: candidate) { return failure.violation.tag == tag }
            return false
        }
        var progress = true
        while progress {
            progress = false
            var chunk = max(1, best.ops.count / 2)
            while chunk >= 1 {
                var start = 0
                while start < best.ops.count {
                    var ops = best.ops
                    ops.removeSubrange(start..<min(start + chunk, ops.count))
                    let candidate = Seed(bytes: Array(best.bytes.prefix(3)) + ops)
                    if fails(candidate) {
                        best = candidate
                        progress = true
                    } else {
                        start += chunk
                    }
                }
                chunk /= 2
            }
            for bit in 0..<16 where best.faults.has(bit) {
                var candidate = best
                let bits = best.faults.bits & ~(1 << UInt16(bit))
                candidate.bytes[1] = UInt8(bits & 0xFF)
                candidate.bytes[2] = UInt8(bits >> 8)
                if candidate.bytes.count >= 3, fails(candidate) {
                    best = candidate
                    progress = true
                }
            }
        }
        return best
    }
}

/// What a spec supplies: the world, one step, the heal and the snapshot.
protocol SimSpec {
    associatedtype World

    /// How many configurations of production a mode byte selects among.
    static var modes: Int { get }
    /// The most ops a seed may run.
    static var maxSteps: Int { get }

    /// Setup: fresh stores, the production core, the simulated daemon, time zero.
    func makeWorld(mode: Int, faults: Sim.FaultMask, rng: inout SimRandom) -> World

    /// One scripted step, then the invariants, which throw the first broken rule.
    func step(_ world: inout World, kind: Int, arg: Int, rng: inout SimRandom) throws(Sim.Violation)

    /// Heal then settle. Faults go off and time keeps moving, but the heal may not
    /// reconnect or reset what production would have to reconnect or reset for itself.
    func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation)

    /// Everything a double run compares. Not a summary: the final state itself.
    func snapshot(_ world: World) -> String

    /// Counted excuses and census figures, by name.
    func tallies(_ world: World) -> [String: Int]
}

extension SimSpec {
    func tallies(_ world: World) -> [String: Int] { [:] }
}

/// SplitMix64, so a seed gives the same stream on every platform and run.
struct SimRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// A value in `0..<bound`.
    mutating func below(_ bound: Int) -> Int {
        bound <= 1 ? 0 : Int(next() % UInt64(bound))
    }

    /// True once in `n` on average.
    mutating func oneIn(_ n: Int) -> Bool { below(n) == 0 }

    /// Fisher-Yates, so events due together are ordered by the seed.
    mutating func shuffle<T>(_ items: inout [T]) {
        guard items.count > 1 else { return }
        for index in stride(from: items.count - 1, to: 0, by: -1) {
            items.swapAt(index, below(index + 1))
        }
    }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
