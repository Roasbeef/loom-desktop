import LoomKit

/// One daemon the app is connected to, as a value: the control exchange, the poll
/// schedule, the catalogue it reads, and which sessions have a lane.
///
/// `DaemonConnection` used to interleave six awaited reads with assignments, so any other
/// main-actor job could run at each `await` and the function then wrote results computed
/// from values read before the suspension. Here the poll is a saga of background commands
/// on the control lane. Each reply is one event, applied in one step, and the catalogue,
/// the attach decisions and the periodic reads are decided from that step's state alone.
///
/// ## Schedule
///
/// A poll starts when `pollAt` passes: `status`, then every page of `sessions.list`, then
/// `sessions.activity` in batches of 24 for the resident sessions. The next poll is due
/// two seconds after one completes. A failure of any kind, including a refused command,
/// ends the connection, and the host reconnects three seconds later, as the old loop did.
/// The periodic reads (deployment every 8th poll, attention every 15th, projects every
/// 4th, review every 3rd) are not decided here but announced as `due` effects, and the
/// host performs each as a background command through `apply`.
///
/// ## Attach decisions
///
/// A resident session whose activity reports an approval gets a lane, so the inbox can
/// read the record it must show. A session whose lane ended while it is still resident is
/// attached again and inherits what the old lane held. A new epoch voids every ephemeral
/// fact, so every lane is dropped when `hello` names an epoch other than the last one.
///
/// ## Invariants
///
/// `DaemonModelTests` checks them after every step:
///
/// - B6 no lane of an earlier epoch survives a new epoch.
/// - B7 a resident session with a pending approval has a lane within one poll of a
///   connection that is up, and one whose lane ended is attached again within one poll.
/// - H6 an owner command is written before any background command that queued after it,
///   so it waits at most for the one read already on the wire.
public struct Daemon: Sendable, Equatable {
    public static let pollMs = 2_000
    public static let retryMs = 3_000
    public static let activityBatch = 24
    public static let deploymentEvery = 8
    public static let attentionEvery = 15
    public static let projectsEvery = 4
    public static let reviewEvery = 3

    /// A read the host performs beside the catalogue.
    public enum Periodic: Sendable, Equatable, Hashable {
        case deployment, attention, review, projects
    }

    public enum Connection: Sendable, Equatable {
        case connecting
        case connected
        case unavailable(String)
    }

    /// How a command the host submitted ended.
    public enum Settlement: Sendable, Equatable {
        case reply(JSONValue)
        case refused(code: String, message: String, details: JSONValue?)
        /// The reply was lost. The command may have taken effect.
        case lost(command: String)
        case failed(LoomError)
    }

    public enum Effect: Sendable, Equatable {
        /// Open the control socket and forward its frames and its end.
        case open
        case transmit(String)
        case shut
        case state(Connection)
        /// The catalogue, the activity or the status changed.
        case catalogue
        case attach(session: String, inheriting: Inheritance)
        case detachAll
        case due(Periodic)
        case settled(tag: Int, Settlement)
    }

    /// Whether a new lane takes over what the one it replaces held.
    public enum Inheritance: Sendable, Equatable {
        case fresh
        case previous
    }

    public private(set) var connection: Connection = .connecting
    public private(set) var epoch: String?
    public private(set) var status: JSONValue?
    /// The body of the daemon's `hello`, for the host to decode who it is talking to.
    public private(set) var hello: JSONValue?
    public private(set) var sessions: [SessionRecord] = []
    public private(set) var activity: [String: SessionActivity] = [:]
    /// The sessions that have had a lane, and whether it is still up.
    public private(set) var lanes: [String: LaneState] = [:]
    /// Which lane each session's record is about, as the host numbered it. A report about any other
    /// lane is stale and is ignored, so a controller that was detached cannot end the one that replaced it.
    private var generations: [String: Int] = [:]
    public private(set) var ticks = 0
    public private(set) var retryAt: Int?
    public private(set) var pollAt: Int?

    public enum LaneState: Sendable, Equatable {
        case up
        case ended
    }

    private enum Poll: Sendable, Equatable {
        case status(ControlLane.Ticket)
        case list(ControlLane.Ticket, collected: [SessionRecord])
        case activity(ControlLane.Ticket, remaining: [[String]], collected: [String: SessionActivity], listed: [SessionRecord])
    }

    private var control: ControlLane?
    private var poll: Poll?
    private var pending: [ControlLane.Ticket: Int] = [:]
    private var resident: [String] = []
    private var firstStatus: JSONValue?

    public init() {}

    /// The instant the host must wake for, if any.
    public var nextDue: Int? {
        [control?.nextDue, poll == nil && connection == .connected ? pollAt : nil, retryAt].compactMap { $0 }.min()
    }

    /// Whether a poll is out, which a caller who has just changed something must not count as reading the change.
    public var isPolling: Bool { poll != nil }

    /// Whether the control socket is up and has said hello.
    public var isConnected: Bool { connection == .connected }

    /// Whether a poll or a command is on the wire or waiting for it.
    public var isBusy: Bool { poll != nil || control?.phase == .awaitingReply || (control?.waiting ?? 0) > 0 }

    /// How many owner commands wait for the credit.
    public var ownerWaiting: Bool { control?.ownerWaiting ?? false }

    // MARK: Events

    /// Begins connecting.
    public mutating func start(now: Int) -> [Effect] {
        reconnect(now: now)
    }

    /// Reduces one frame from the control socket.
    public mutating func receive(_ text: String, now: Int) -> [Effect] {
        guard control != nil else { return [] }
        return route(control?.receive(text, now: now) ?? [], now: now)
    }

    /// Reduces the transport's report that the control socket ended or could not open.
    public mutating func receive(failed error: LoomError, now: Int) -> [Effect] {
        guard control != nil else { return [] }
        return route(control?.receive(failed: error) ?? [], now: now)
    }

    /// Acts on whatever has come due: a reply deadline, a poll, or the reconnect.
    public mutating func tick(now: Int) -> [Effect] {
        var effects: [Effect] = []
        if control != nil { effects += route(control?.tick(now: now) ?? [], now: now) }
        if let at = retryAt, at <= now { effects += reconnect(now: now) }
        if connection == .connected, poll == nil, let at = pollAt, at <= now { effects += beginPoll(now: now) }
        return effects
    }

    /// A poll now, because the host just changed something the catalogue shows (a session was
    /// created, stopped or moved) and wants to read the result. A poll already out is enough.
    public mutating func pollSoon(now: Int) -> [Effect] {
        guard connection == .connected, poll == nil else { return [] }
        return beginPoll(now: now)
    }

    /// A lane this daemon asked for has ended. The generation names which lane: the host numbers each lane it makes.
    public mutating func laneEnded(_ session: String, generation: Int) {
        guard generations[session] == generation, lanes[session] != nil else { return }
        lanes[session] = .ended
    }

    /// A session was stopped or removed, so it has no lane to keep.
    public mutating func forget(_ session: String) {
        lanes[session] = nil
        generations[session] = nil
    }

    /// Submits a command the host wants answered, settled by `tag`.
    public mutating func submit(_ command: ControlLane.Command, tag: Int, now: Int) -> [Effect] {
        guard control != nil else { return [.settled(tag: tag, .failed(.closed("the daemon is not connected")))] }
        let admitted = control?.submit(command, now: now) ?? (ticket: 0, updates: [])
        pending[admitted.ticket] = tag
        return route(admitted.updates, now: now)
    }

    // MARK: Connection

    private mutating func reconnect(now: Int) -> [Effect] {
        retryAt = nil
        control = ControlLane(now: now)
        connection = .connecting
        return [.state(.connecting), .open]
    }

    private mutating func route(_ updates: [ControlLane.Update], now: Int) -> [Effect] {
        var effects: [Effect] = drain()
        for update in updates { effects += handle(update, now: now) }
        effects += drain()
        return effects
    }

    private mutating func drain() -> [Effect] {
        (control?.takeOutputs() ?? []).map { output in
            switch output {
            case .transmit(let text): return .transmit(text)
            case .shut: return .shut
            }
        }
    }

    private mutating func handle(_ update: ControlLane.Update, now: Int) -> [Effect] {
        switch update {
        case .hello(let epoch, let body):
            hello = body
            var effects: [Effect] = []

            // A new epoch means every ephemeral fact is void (protocol section 6.7).
            if let previous = self.epoch, previous != epoch {
                lanes = [:]
                generations = [:]
                effects.append(.detachAll)
            }
            self.epoch = epoch
            connection = .connected
            ticks = 0
            pollAt = now
            return effects + [.state(.connected)] + beginPoll(now: now)
        case .replied(let ticket, let body):
            return replied(ticket, body, now: now)
        case .refused(let ticket, let code, let message, let details):
            if isPoll(ticket) { return lose(.server(code: code, message: message, details: details), now: now) }
            return settle(ticket, .refused(code: code, message: message, details: details))
        case .lost(let ticket, let command):
            if isPoll(ticket) { return [] }
            return settle(ticket, .lost(command: command))
        case .failed(let ticket, let error):
            if isPoll(ticket) { return [] }
            return settle(ticket, .failed(error))
        case .closed(let error):
            return lose(error ?? .closed("the control connection ended"), now: now)
        }
    }

    /// Ends the connection and schedules the reconnect. Lanes stay, as before: a daemon that
    /// comes back with the same epoch finds them, and a new epoch drops them at `hello`.
    private mutating func lose(_ error: LoomError, now: Int) -> [Effect] {
        var effects: [Effect] = []
        if control != nil, control?.phase != .closed {
            // The lane reports what the close cost every command it still holds: the one written is
            // lost, and each that waited behind it never was written. A refused poll command ends the
            // connection through here, so those callers are settled now and not left waiting.
            let closing = control?.close() ?? []
            effects += drain()
            for update in closing {
                switch update {
                case .lost(let ticket, let command): if !isPoll(ticket) { effects += settle(ticket, .lost(command: command)) }
                case .failed(let ticket, let reason): if !isPoll(ticket) { effects += settle(ticket, .failed(reason)) }
                default: break
                }
            }
        }
        for ticket in pending.keys.sorted() { effects += settle(ticket, .failed(.closed("the daemon connection ended"))) }
        control = nil
        poll = nil
        pollAt = nil
        retryAt = now + Self.retryMs
        let words = error.localizedDescription
        connection = .unavailable(words)
        return effects + [.state(.unavailable(words))]
    }

    private func isPoll(_ ticket: ControlLane.Ticket) -> Bool {
        switch poll {
        case .status(let t)?, .list(let t, _)?, .activity(let t, _, _, _)?: return t == ticket
        case nil: return false
        }
    }

    private mutating func settle(_ ticket: ControlLane.Ticket, _ settlement: Settlement) -> [Effect] {
        guard let tag = pending.removeValue(forKey: ticket) else { return [] }
        return [.settled(tag: tag, settlement)]
    }

    // MARK: The poll

    private mutating func beginPoll(now: Int) -> [Effect] {
        guard poll == nil, control != nil else { return [] }
        let admitted = control?.submit(.init("status", priority: .background), now: now) ?? (ticket: 0, updates: [])
        poll = .status(admitted.ticket)
        return route(admitted.updates, now: now)
    }

    private mutating func replied(_ ticket: ControlLane.Ticket, _ body: JSONValue, now: Int) -> [Effect] {
        guard isPoll(ticket), let current = poll else { return settle(ticket, .reply(body)) }
        switch current {
        case .status:
            firstStatus = body
            return advance(.list(0, collected: []), command: .init("sessions.list", body: ["after": ""], priority: .background), now: now)
        case .list(_, let collected):
            let rows = body["sessions"]?.array ?? []
            let records = collected + rows.compactMap(SessionRecord.init).filter { !$0.hasMoved }
            if !rows.isEmpty, let next = body["after"]?.string {
                return advance(.list(0, collected: records), command: .init("sessions.list", body: ["after": .string(next)], priority: .background), now: now)
            }
            let ids = records.filter { $0.state.isResident }.map(\.id)
            var batches: [[String]] = []
            for start in stride(from: 0, to: ids.count, by: Self.activityBatch) {
                batches.append(Array(ids[start..<min(start + Self.activityBatch, ids.count)]))
            }
            return nextBatch(remaining: batches, collected: [:], listed: records, now: now)
        case .activity(_, let remaining, var collected, let listed):
            for row in (body["activity"]?.array ?? []).compactMap(SessionActivity.init) { collected[row.sessionID] = row }
            return nextBatch(remaining: remaining, collected: collected, listed: listed, now: now)
        }
    }

    private mutating func advance(_ next: Poll, command: ControlLane.Command, now: Int) -> [Effect] {
        let admitted = control?.submit(command, now: now) ?? (ticket: 0, updates: [])
        switch next {
        case .list(_, let collected): poll = .list(admitted.ticket, collected: collected)
        default: break
        }
        return route(admitted.updates, now: now)
    }

    private mutating func nextBatch(remaining: [[String]], collected: [String: SessionActivity], listed: [SessionRecord], now: Int) -> [Effect] {
        guard let batch = remaining.first, let epoch else {
            return complete(listed: listed, activity: collected, now: now)
        }
        let admitted = control?.submit(.init("sessions.activity", body: [
            "sessions": .array(batch.map { .string($0) }),
            "epoch": .string(epoch),
        ], priority: .background), now: now) ?? (ticket: 0, updates: [])
        poll = .activity(admitted.ticket, remaining: Array(remaining.dropFirst()), collected: collected, listed: listed)
        return route(admitted.updates, now: now)
    }

    /// One poll finished: everything it read is applied in this one step, and the decisions
    /// that follow come from it alone.
    private mutating func complete(listed: [SessionRecord], activity read: [String: SessionActivity], now: Int) -> [Effect] {
        poll = nil
        pollAt = now + Self.pollMs
        status = firstStatus
        sessions = listed.sorted { $0.createdAt > $1.createdAt }
        activity = read
        resident = listed.filter { $0.state.isResident }.map(\.id).sorted()
        var effects: [Effect] = [.catalogue]

        for step in Self.attachPlan(resident: resident, approvals: activity.mapValues(\.approvals), lanes: lanes) {
            lanes[step.session] = .up
            generations[step.session] = nil
            effects.append(.attach(session: step.session, inheriting: step.inheriting))
        }
        if ticks % Self.deploymentEvery == 0 { effects.append(.due(.deployment)) }
        if ticks % Self.attentionEvery == 0 { effects.append(.due(.attention)) }
        if ticks % Self.reviewEvery == 0 { effects.append(.due(.review)) }
        if ticks % Self.projectsEvery == 0 { effects.append(.due(.projects)) }
        ticks += 1
        return effects
    }

    /// One lane to make.
    public struct Attach: Sendable, Equatable {
        public let session: String
        public let inheriting: Inheritance
    }

    /// Which resident sessions need a lane now. A session that asks for an approval and has
    /// had no lane gets a fresh one, so the inbox can read the record it must show. A session
    /// whose lane ended is attached again and inherits what the old lane held, including
    /// when it also asks for an approval, which the app's two separate loops once let skip
    /// the inheritance. The order is the sorted session id, so two runs of one schedule agree.
    public static func attachPlan(resident: [String], approvals: [String: Int], lanes: [String: LaneState]) -> [Attach] {
        var plan: [Attach] = []
        for id in resident.sorted() {
            switch lanes[id] {
            case nil:
                if (approvals[id] ?? 0) > 0 { plan.append(Attach(session: id, inheriting: .fresh)) }
            case .ended?:
                plan.append(Attach(session: id, inheriting: .previous))
            case .up?:
                break
            }
        }
        return plan
    }

    /// Records that the host made a lane for a session, whether the core asked for it or someone opened the session.
    public mutating func laneAttached(_ session: String, generation: Int) {
        lanes[session] = .up
        generations[session] = generation
    }
}
