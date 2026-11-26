/// Which background reads are due, from the surfaces that are shown.
///
/// Reads used to be started by whichever view or model happened to be alive: a `.task` in a
/// panel, the thread reader's loop, the update watcher's one-second loop, the rail's
/// five-second one. Which reads were sent, and how many in a window, depended on which views
/// were on screen. This value takes the set of surfaces the shell says are shown and decides
/// from it, with a clock reading, which read to start.
///
/// ## Rules it keeps
///
/// - A read is started only for a surface that is shown.
/// - A surface has at most one read in flight.
/// - A surface is read again after its own period, never sooner, while it stays shown. A surface
///   that becomes shown is read at once, because its view is new and empty, and a budgeted class is
///   still held to its allowance.
/// - The reads of one class never exceed the daemon's budget for a credential in any window
///   of `windowMs`: six `session.brief` reads in four seconds, and two review reads in four
///   seconds. A read that would pass the budget waits for the oldest start in the window to
///   leave it, so the app never meets the daemon's refusal by asking too often.
///
/// The shell performs each `read` effect and reports how it ended.
public struct Readers: Sendable, Equatable {
    /// The window the daemon's budgets are counted over.
    public static let windowMs = 4_000

    /// Which budget a read draws on.
    public enum Class: Sendable, Equatable, Hashable {
        /// `session.brief`: six in a window.
        case brief
        /// `sessions.review`: two in a window.
        case review
        /// Reads with no daemon budget of their own.
        case unbudgeted

        public var limit: Int {
            switch self {
            case .brief: return 6
            case .review: return 2
            case .unbudgeted: return .max
            }
        }
    }

    /// One thing the shell can show that needs a read.
    public struct Surface: Sendable, Equatable, Hashable, Comparable {
        public let name: String
        public let session: String
        public let periodMs: Int
        public let budget: Class

        public init(name: String, session: String, periodMs: Int, budget: Class) {
            self.name = name
            self.session = session
            self.periodMs = periodMs
            self.budget = budget
        }

        /// A surface is what is read and for which session. How often, and against which budget, can
        /// change while it is shown (the update cards' period follows how many there are), and a change
        /// of either must not make it a new surface with no memory of when it was last read.
        public static func == (lhs: Surface, rhs: Surface) -> Bool {
            lhs.name == rhs.name && lhs.session == rhs.session
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(session)
        }

        public static func < (lhs: Surface, rhs: Surface) -> Bool {
            (lhs.session, lhs.name) < (rhs.session, rhs.name)
        }
    }

    public enum Outcome: Sendable, Equatable {
        case read
        case failed
    }

    public enum Effect: Sendable, Equatable {
        case read(Surface)
    }

    private struct State: Sendable, Equatable {
        var lastStart: Int?
        var inFlight = false
    }

    /// What is known of every surface that has been shown, including those hidden since.
    private var states: [Surface: State] = [:]
    private var shown: Set<Surface> = []
    private var starts: [Class: [Int]] = [:]

    public init() {}

    /// The shell reports which surfaces are shown. A read in flight for a surface that was
    /// hidden still ends normally, and a surface that returns while it runs is not read again.
    ///
    /// A surface that becomes shown is read at once, whatever it was last read: what draws it is a
    /// new view with a model that starts empty, so waiting out the period of a read made for the
    /// previous view would leave it blank for up to a whole period. The budget still applies, so a
    /// surface that comes and goes is limited by the daemon's allowance and not by this rule.
    public mutating func show(_ surfaces: Set<Surface>, now: Int) -> [Effect] {
        for surface in surfaces.subtracting(shown) { states[surface]?.lastStart = nil }
        shown = surfaces
        return due(now: now)
    }

    /// A read the shell was asked for has ended.
    public mutating func finished(_ surface: Surface, _ outcome: Outcome, now: Int) -> [Effect] {
        guard var state = states[surface] else { return due(now: now) }
        state.inFlight = false
        states[surface] = state
        return due(now: now)
    }

    public mutating func tick(now: Int) -> [Effect] {
        due(now: now)
    }

    /// The instant a tick can next start a read.
    public var nextDue: Int? {
        var soonest: Int?
        for surface in shown {
            let state = states[surface] ?? State()
            guard !state.inFlight else { continue }
            let ready = max(state.lastStart.map { $0 + surface.periodMs } ?? 0, roomAt(surface.budget) ?? 0)
            soonest = min(soonest ?? ready, ready)
        }
        return soonest
    }

    // MARK: Internals

    /// When the class has room for one more start, or nil if it has room now.
    private func roomAt(_ budget: Class) -> Int? {
        let limit = budget.limit
        let recent = starts[budget] ?? []
        guard recent.count >= limit else { return nil }
        return recent[recent.count - limit] + Self.windowMs
    }

    private mutating func due(now: Int) -> [Effect] {
        for key in starts.keys { starts[key] = starts[key]?.filter { $0 > now - Self.windowMs } }
        var effects: [Effect] = []

        // Never read first, then the longest ago, with the name breaking a tie, so two runs agree.
        let order = shown.sorted { lhs, rhs in
            let (a, b) = (states[lhs]?.lastStart ?? Int.min, states[rhs]?.lastStart ?? Int.min)
            return a != b ? a < b : lhs < rhs
        }
        for surface in order {
            var state = states[surface] ?? State()
            guard !state.inFlight else { continue }
            if let last = state.lastStart, now < last + surface.periodMs { continue }
            if (starts[surface.budget] ?? []).count >= surface.budget.limit { continue }
            state.lastStart = now
            state.inFlight = true
            states[surface] = state
            starts[surface.budget, default: []].append(now)
            effects.append(.read(surface))
        }
        return effects
    }
}
