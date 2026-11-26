import Foundation

/// The clock a host reads and sleeps on.
///
/// The core values take `now` as an argument and name `nextDue`, so a host needs two things from a
/// clock: a monotonic reading in milliseconds, and a way to wait until a later one. They are given
/// as closures so that a test can supply a virtual clock and drive the app's real hosting code,
/// `DaemonHost` and `ReadHost`, with time that moves only when the test says so.
public struct HostClock: Sendable {
    /// Milliseconds since this clock started, a monotonic reading.
    public let now: @Sendable () -> Int
    /// Suspends for this many milliseconds of this clock's time.
    public let sleep: @Sendable (Int) async -> Void

    public init(now: @escaping @Sendable () -> Int, sleep: @escaping @Sendable (Int) async -> Void) {
        self.now = now
        self.sleep = sleep
    }

    /// The system's continuous clock, started when this value is made.
    public static func real() -> HostClock {
        let origin = ContinuousClock.now
        return HostClock(
            now: {
                let elapsed = ContinuousClock.now - origin
                return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            },
            sleep: { milliseconds in try? await Task.sleep(for: .milliseconds(milliseconds)) }
        )
    }
}
