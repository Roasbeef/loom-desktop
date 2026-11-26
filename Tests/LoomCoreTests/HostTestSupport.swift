import Foundation
import LoomShell

/// A clock whose time moves only when a test says so, for driving the app's real hosts.
///
/// `sleep` suspends until `advance` reaches its instant. `DaemonHost` and `ReadHost` read and sleep on
/// a `HostClock`, so with this one a test runs the same hosting code the app runs, over a fake
/// transport, with no real waiting and a timer that fires exactly when the schedule allows.
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var waiters: [(due: Int, resume: CheckedContinuation<Void, Never>)] = []

    var now: Int { lock.withLock { current } }

    var clock: HostClock {
        HostClock(now: { self.now }, sleep: { milliseconds in
            await withCheckedContinuation { resume in
                let due = self.lock.withLock { self.current + milliseconds }
                self.lock.lock()
                if due <= self.current {
                    self.lock.unlock()
                    resume.resume()
                } else {
                    self.waiters.append((due, resume))
                    self.lock.unlock()
                }
            }
        })
    }

    /// Moves time forward and wakes every sleeper that has come due, earliest first, letting each run
    /// before the next so a timer that re-arms sees the new time.
    func advance(by milliseconds: Int) async {
        let target = now + milliseconds
        while true {
            let next: (due: Int, resume: CheckedContinuation<Void, Never>)? = lock.withLock {
                guard let index = waiters.indices.filter({ waiters[$0].due <= target }).min(by: { waiters[$0].due < waiters[$1].due }) else {
                    current = target
                    return nil
                }
                let entry = waiters.remove(at: index)
                current = max(current, entry.due)
                return entry
            }
            guard let next else { return }
            next.resume.resume()
            await settle()
        }
    }

    /// Lets the tasks the last step woke run to their next suspension.
    func settle() async {
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
