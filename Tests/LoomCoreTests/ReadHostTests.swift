import XCTest
import LoomCore
import LoomShell

/// The app's real `ReadHost`, run over a virtual clock. The simulation drives `Readers` itself; these
/// tests drive the host that carries its decisions out, which is where holders, tasks and timers live.
@MainActor
final class ReadHostTests: XCTestCase {
    private func surface(_ name: String, _ session: String, period: Int = 1_000, budget: Readers.Class = .unbudgeted) -> Readers.Surface {
        .init(name: name, session: session, periodMs: period, budget: budget)
    }

    /// Counts performs by label.
    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func bump(_ label: String) { lock.withLock { counts[label, default: 0] += 1 } }
        subscript(_ label: String) -> Int { lock.withLock { counts[label] ?? 0 } }
    }

    func testAHeldSurfaceIsReadAtOnceAndThenOncePerPeriod() async {
        let time = VirtualClock()
        let host = ReadHost(clock: time.clock)
        let tally = Tally()
        let holder = Task { await host.hold([.init(surface("rail", "s1", period: 1_000)) { tally.bump("rail"); return .read }]) }
        await time.settle()
        XCTAssertEqual(tally["rail"], 1, "the first read is at once")
        await time.advance(by: 999)
        XCTAssertEqual(tally["rail"], 1, "never inside the period")
        await time.advance(by: 1)
        XCTAssertEqual(tally["rail"], 2)
        holder.cancel()
        await time.settle()
        await time.advance(by: 5_000)
        XCTAssertEqual(tally["rail"], 2, "a surface nobody holds is not read")
    }

    /// Two windows that show one session each hold their own entries. Dropping one must not drop the
    /// other's, which a key made from the session alone did.
    func testTwoHoldersOfTheSameSurfaceAreBothFedAndOneLeavingKeepsTheOther() async {
        let time = VirtualClock()
        let host = ReadHost(clock: time.clock)
        let tally = Tally()
        let first = Task { await host.hold([.init(surface("thread.record", "s1")) { tally.bump("first"); return .read }]) }
        await time.settle()
        let second = Task { await host.hold([.init(surface("thread.record", "s1")) { tally.bump("second"); return .read }]) }
        await time.settle()
        await time.advance(by: 1_000)
        XCTAssertGreaterThanOrEqual(tally["first"], 1)
        XCTAssertGreaterThanOrEqual(tally["second"], 1, "every holder of a surface receives its read")
        first.cancel()
        await time.settle()
        let before = tally["second"]
        await time.advance(by: 2_000)
        XCTAssertGreaterThan(tally["second"], before, "the holder that stays still reads")
        second.cancel()
        await time.settle()
    }

    /// A pane reopened inside its period shows a new, empty model, so it must read at once.
    func testAPaneReopenedInsideItsPeriodReadsAtOnce() async {
        let time = VirtualClock()
        let host = ReadHost(clock: time.clock)
        let tally = Tally()
        let entry = { ReadHost.Entry(self.surface("thread.brief", "s1", period: 15_000, budget: .brief)) { tally.bump("brief"); return .read } }
        let first = Task { await host.hold([entry()]) }
        await time.settle()
        first.cancel()
        await time.settle()
        await time.advance(by: 3_000)
        let second = Task { await host.hold([entry()]) }
        await time.settle()
        XCTAssertEqual(tally["brief"], 2, "reopened three seconds later, read again at once and not at fifteen")
        second.cancel()
        await time.settle()
    }

    func testAnEntryThatStopsAfterItsReadIsReadOnceAndThenLetGo() async {
        let time = VirtualClock()
        let host = ReadHost(clock: time.clock)
        let tally = Tally()
        let holder = Task {
            await host.hold([.init(surface("ask.a1", "s1", period: 5_000), repeats: .untilRead) {
                tally.bump("ask")
                return tally["ask"] < 2 ? .failed : .read
            }])
        }
        await time.settle()
        await time.advance(by: 5_000)
        XCTAssertEqual(tally["ask"], 2, "a failed read is tried again after its period")
        await time.advance(by: 30_000)
        XCTAssertEqual(tally["ask"], 2, "once it lands it is not read again")
        holder.cancel()
        await time.settle()
    }

    func testManyBriefsAcrossHoldersNeverPassTheDaemonsSixInFourSeconds() async {
        let time = VirtualClock()
        let host = ReadHost(clock: time.clock)
        let tally = Tally()
        var holders: [Task<Void, Never>] = []
        for index in 1...10 {
            holders.append(Task { await host.hold([.init(surface("update.brief", "s\(index)", period: 1_000, budget: .brief)) { tally.bump("brief"); return .read }]) })
        }
        await time.settle()
        XCTAssertLessThanOrEqual(tally["brief"], 6, "ten surfaces, one window, six reads")
        await time.advance(by: 3_999)
        XCTAssertLessThanOrEqual(tally["brief"], 6)
        await time.advance(by: 1)
        XCTAssertGreaterThan(tally["brief"], 6, "the window emptied")
        holders.forEach { $0.cancel() }
        await time.settle()
    }
}
