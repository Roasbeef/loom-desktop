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
/// in flight per surface and none sooner than its period, and the host performs it. Leaving the
/// screen cancels the holder's task, which drops its entries.
@MainActor
final class ReadHost {
    struct Entry {
        enum Repeat {
            case always
            /// Stop holding this surface once a read lands, for a read whose result is kept.
            case untilRead
        }

        let surface: Readers.Surface
        let repeats: Repeat
        let perform: @MainActor () async -> Readers.Outcome

        init(_ surface: Readers.Surface, repeats: Repeat = .always, perform: @escaping @MainActor () async -> Readers.Outcome) {
            self.surface = surface
            self.repeats = repeats
            self.perform = perform
        }
    }

    private var core = Readers()
    private var held: [String: [Entry]] = [:]
    private var timer: Task<Void, Never>?
    private let origin = ContinuousClock.now

    /// Holds `entries` for `owner` until the calling task is cancelled.
    func hold(owner: String, _ entries: [Entry]) async {
        held[owner] = entries
        sync()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3_600))
        }
        held[owner] = nil
        sync()
    }

    /// The core is told the whole set shown, which is every holder's entries together.
    private func sync() {
        run(core.show(Set(held.values.flatMap { $0 }.map(\.surface)), now: now()))
    }

    private func entry(for surface: Readers.Surface) -> Entry? {
        for entries in held.values {
            if let entry = entries.first(where: { $0.surface == surface }) { return entry }
        }
        return nil
    }

    private func run(_ effects: [Readers.Effect]) {
        for case .read(let surface) in effects {
            guard let entry = entry(for: surface) else {
                run(core.finished(surface, .failed, now: now()))
                continue
            }
            Task { @MainActor in
                let outcome = await entry.perform()
                if entry.repeats == .untilRead, outcome == .read {
                    for owner in held.keys { held[owner]?.removeAll { $0.surface == surface } }
                    run(core.show(Set(held.values.flatMap { $0 }.map(\.surface)), now: now()))
                }
                run(core.finished(surface, outcome, now: now()))
            }
        }
        arm()
    }

    private func arm() {
        timer?.cancel()
        timer = nil
        guard let due = core.nextDue else { return }
        let wait = max(1, due - now())
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.run(self.core.tick(now: self.now()))
        }
    }

    private func now() -> Int {
        let elapsed = ContinuousClock.now - origin
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
