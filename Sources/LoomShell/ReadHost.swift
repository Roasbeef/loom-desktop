import LoomCore
import LoomKit
import Observation

/// The shell around `LoomCore.Readers`: the one place a background read is started.
///
/// A view or a model that wants something read on a schedule while it is on screen does not run
/// a loop of its own. It holds a set of entries here, each a surface (what is read, for which
/// session, how often, against which of the daemon's budgets) and the read to perform. The core
/// decides from the union of what is held which read starts now, keeps the daemon's budgets for
/// a credential across every holder (six briefs and two reviews in four seconds), allows one read
/// in flight per surface and none sooner than its period while it stays shown, and the host
/// performs it. Leaving the screen cancels the holder's task, which drops its entries.
///
/// Every `hold` is its own holder, whatever it holds. Two windows that show the same session, or
/// two panes that read the same surface, each keep their entries and each is given the data, and
/// one going away never drops what the other still shows.
@MainActor
public final class ReadHost {
    public struct Entry {
        public enum Repeat {
            case always
            /// Stop holding this surface once a read lands, for a read whose result is kept.
            case untilRead
        }

        public let surface: Readers.Surface
        public let repeats: Repeat
        public let perform: @MainActor () async -> Readers.Outcome

        public init(_ surface: Readers.Surface, repeats: Repeat = .always, perform: @escaping @MainActor () async -> Readers.Outcome) {
            self.surface = surface
            self.repeats = repeats
            self.perform = perform
        }
    }

    private var core = Readers()
    private var held: [Int: [Entry]] = [:]
    private var nextKey = 1
    private var timer: Task<Void, Never>?
    private let clock: HostClock

    public init(clock: HostClock = .real()) {
        self.clock = clock
    }

    /// Holds `entries` until the calling task is cancelled.
    public func hold(_ entries: [Entry]) async {
        let key = nextKey
        nextKey += 1
        held[key] = entries
        sync()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3_600))
        }
        held[key] = nil
        sync()
    }

    /// The core is told the whole set shown, which is every holder's entries together.
    private func sync() {
        run(core.show(Set(held.values.flatMap { $0 }.map(\.surface)), now: clock.now()))
    }

    private func run(_ effects: [Readers.Effect]) {
        for case .read(let surface) in effects {
            let matches = held.keys.sorted().flatMap { key in
                (held[key] ?? []).filter { $0.surface == surface }.map { (key, $0) }
            }
            guard !matches.isEmpty else {
                run(core.finished(surface, .failed, now: clock.now()))
                continue
            }
            Task { @MainActor in
                var landed = false
                for (key, entry) in matches {
                    guard await entry.perform() == .read else { continue }
                    landed = true
                    if entry.repeats == .untilRead { held[key]?.removeAll { $0.surface == surface } }
                }
                if matches.contains(where: { $0.1.repeats == .untilRead }) {
                    run(core.show(Set(held.values.flatMap { $0 }.map(\.surface)), now: clock.now()))
                }
                run(core.finished(surface, landed ? .read : .failed, now: clock.now()))
            }
        }
        arm()
    }

    private func arm() {
        timer?.cancel()
        timer = nil
        guard let due = core.nextDue else { return }
        let wait = max(1, due - clock.now())
        let clock = self.clock
        timer = Task { [weak self] in
            await clock.sleep(wait)
            guard !Task.isCancelled, let self else { return }
            self.run(self.core.tick(now: self.clock.now()))
        }
    }
}
