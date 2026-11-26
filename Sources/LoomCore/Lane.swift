import Foundation
import LoomKit

/// The client's side of one session socket, as a value that decides and does nothing else.
///
/// This is a port of Loom's `session_view/session_channel.gleam`. A lane reads no
/// clock, owns no socket and starts no task. The host feeds it what happened (a
/// received frame, a close, a tick, a command to send) together with `now`, a
/// monotonic reading in milliseconds, and it answers with updates for the model
/// and with outputs for the transport. Every transition is a function of the
/// lane and its arguments, so one schedule always produces one result, and a
/// simulation can run thousands of schedules a second.
///
/// ## The rules the lane keeps
///
/// The session protocol allows one command in flight per socket (stop-and-wait
/// credit) and one open snapshot transfer. A lane enforces both by construction,
/// because it holds at most one `inflight` request and a FIFO of `queue`d ones.
/// The model test in `LaneModelTests` checks these rules after every step under
/// the tags Loom's own model test uses:
///
/// - I1 a correlated command is written only while no request awaits its reply,
///   except the `snapshot_next` that a transfer's own reply grants.
/// - I2 request identities strictly increase.
/// - I3 a mutation crosses the wire at most once, and a lane that fails while it
///   awaits the reply reports an unknown outcome for exactly that identity, once.
/// - I4 a waiting mutation is later written once or reported not sent once.
/// - I5 nothing is written after the close, and there is one close.
/// - I6 one `snapshot_next` per granted fragment, naming the granted transfer.
/// - I7 a reply whose `reply_to` is stale produces no update and closes the lane.
/// - I8 a pushed frame allocates no identity, spends no credit and cannot fail it.
/// - L1 to L5 and N1 pin the refresh and deadline instants.
///
/// ## Differences from the Gleam lane
///
/// The Gleam lane holds one waiting command because the terminal has one
/// operator. The desktop issues several reads at once from different panels, so
/// this lane keeps a FIFO and applies the Loom rule to each queued command. A
/// refused catch-up on a lane that already holds a cut is retried at the next
/// refresh instead of closing the lane, as the Swift lane has always done. The
/// goal-board read is a Loom terminal feature the desktop does not have. A completed ticketed
/// transfer (history, lineage, decided) does not ask for an early refresh as Loom's does, and a
/// `resumed` reply to `catch_up` is a protocol violation here, because no daemon path sends it.
///
/// ## Timing
///
/// The constants are Loom's. A command's reply deadline is 10 s and a capture's is
/// 30 s, the transfer lifetime (client protocol section 8, "Timeouts"; the 6 s
/// there is the daemon's own bound for answering, so the client waits longer than
/// the daemon takes). The idle refresh is 250 ms until the lane has seen a pushed
/// frame and 5 s after, the cadence section 8 recommends and
/// `session_channel.polling_refresh_ms` and `pushing_refresh_ms` implement.
public struct Lane: Sendable, Equatable {
    /// How long one command may wait for its reply, in milliseconds.
    public static let commandDeadlineMs = 10_000
    /// How long a lane's own capture, subscribe or catch-up, may take, in milliseconds.
    public static let captureDeadlineMs = 30_000
    /// The idle refresh of a lane that has seen no pushed frame.
    public static let pollingRefreshMs = 250
    /// The idle refresh of a lane the daemon has pushed to.
    public static let pushingRefreshMs = 5_000

    /// Where the lane is in the exchange it owes. The names are the Gleam phases.
    public enum Phase: Sendable, Equatable {
        /// The lane's own subscribe or catch-up awaits its `snapshot_begin`.
        case awaitingBegin
        /// A transfer is open and each chunk earns one `snapshot_next`.
        case receiving
        /// A caller's command awaits its one correlated reply.
        case awaitingReply
        /// Nothing is outstanding, so a queued command or a refresh may issue.
        case ready
        /// Nothing more may be written.
        case closed
    }

    /// What a command may do, which decides how a lost reply is reported.
    public enum Kind: Sendable, Equatable {
        /// Changes nothing. A lost reply costs a retry.
        case read
        /// May change the session. A lost reply is an unknown outcome and is never resent.
        case mutation
        /// Answers with a snapshot transfer: `history`, `history_lineage`, `escalations_decided`.
        case transfer
    }

    /// One command the host wants sent.
    public struct Command: Sendable, Equatable {
        public let name: String
        public let body: JSONValue
        public let kind: Kind

        public init(_ name: String, body: JSONValue = .object([:]), kind: Kind) {
            self.name = name
            self.body = body
            self.kind = kind
        }
    }

    /// Names a command from admission to its outcome, because a wire id exists only
    /// once the command is written.
    public typealias Ticket = Int

    /// What admitting a command did.
    public enum Disposition: Sendable, Equatable {
        /// The command was written now, under this wire id.
        case sent(id: Int)
        /// The command waits for the exchange in flight.
        case waiting
        /// Nothing was written, and nothing will be.
        case notSent(reason: String)
    }

    /// What made the lane ask for a capture.
    public enum Trigger: Sendable, Equatable {
        /// The lane's own subscribe.
        case requested
        /// A pushed frame asked for it.
        case notified
        /// The idle refresh asked for it.
        case refreshed
    }

    /// What the lane asks the transport to do, in decision order.
    public enum Out: Sendable, Equatable {
        case transmit(String)
        case shut
    }

    /// What the lane reports to the model.
    public enum Update: Sendable, Equatable {
        /// A waiting command was written under this wire id.
        case sent(Ticket, id: Int)
        /// A waiting command was cancelled before it was written.
        case notSent(Ticket, reason: String)
        /// A read or mutation was answered.
        case replied(Ticket, EventEnvelope)
        /// The daemon refused one command. The lane stays open.
        case refused(Ticket, code: String, message: String, details: JSONValue?)
        /// A transfer completed. A nil ticket is the lane's own capture.
        case cut(Ticket?, Cut, Trigger)
        /// A mutation's reply was lost, so its outcome is unknown.
        case unknown(Ticket, command: String, id: Int)
        /// A read or transfer was lost with the lane.
        case failed(Ticket, command: String, LoomError)
        /// A frame the daemon pushed on its own initiative.
        case pushed(EventEnvelope)
        /// A commit notice arrived, whatever the lane did about it.
        case noticed(seq: Int)
        /// The lane ended once. A nil error is a close this client asked for.
        case closed(LoomError?)
    }

    /// Who decides whether an attachment may mutate.
    public enum Admission: Sendable, Equatable {
        /// The lane refuses a mutation locally when the attachment's role is `observer`
        /// (ADR-010), as Loom's terminal does.
        case roleGated
        /// The lane sends and the daemon refuses by code. The desktop uses this,
        /// because its `request` carries reads such as `models` that an observer may
        /// make, and the lane cannot tell them from a change.
        case daemonDecides
    }

    public let sessionID: String
    public let admission: Admission
    /// Commands an observer never sends, whatever the admission rule says of the rest. The
    /// desktop's lane lets the daemon decide, because its generic request carries reads too, but
    /// the commands that change a session are named, and the lane refuses them locally once the
    /// role is known, including ones queued before it was.
    public let guarded: Set<String>
    public private(set) var phase: Phase = .ready

    /// The next wire id, which is also one more than the last one used.
    public private(set) var nextID = 1
    /// The reading at which an in-flight request fails the lane.
    public private(set) var deadline = 0
    /// The reading at which an idle lane with a cut captures again.
    public private(set) var refreshAt = 0
    /// Whether the daemon has pushed to this lane. It only moves from polling to pushing.
    public private(set) var delivery: Delivery = .polling
    /// The cursor catch-ups start from: the highest `next_seq` of a live cut.
    public private(set) var cursor = 0
    /// The attachment's identity, fixed by the first transfer.
    public private(set) var identity: Cut.Identity?

    /// Whether a lane has evidence the daemon pushes.
    public enum Delivery: Sendable, Equatable {
        case polling
        case pushing
    }

    private struct Inflight: Sendable, Equatable {
        var id: Int
        var ticket: Ticket?
        var command: String
        var kind: Kind
    }

    private struct Waiting: Sendable, Equatable {
        var ticket: Ticket
        var command: Command
    }

    private var inflight: Inflight?
    private var assembler: TransferAssembler?
    private var queue: [Waiting] = []
    private var nextTicket = 1
    private var holdsCut = false
    private var refreshDue = false
    private var trigger: Trigger = .requested
    private var outbox: [Out] = []

    /// Opens a lane by writing its subscribe, so request 1 is outstanding.
    public static func start(sessionID: String, admission: Admission = .roleGated, guarded: Set<String> = [], now: Int) -> Lane {
        var lane = Lane(sessionID: sessionID, admission: admission, guarded: guarded)
        lane.issueCapture(command: "subscribe", body: ["session": .string(sessionID)], trigger: .requested, now: now)
        return lane
    }

    private init(sessionID: String, admission: Admission, guarded: Set<String>) {
        self.guarded = guarded
        self.sessionID = sessionID
        self.admission = admission
    }

    // MARK: Questions the host asks

    /// Whether this attachment may change the session. An unknown role is allowed,
    /// because the daemon enforces it and refuses by code.
    public var canMutate: Bool { phase != .closed && identity?.role != "observer" }

    private func refuses(_ command: Command) -> Bool {
        (command.kind == .mutation && admission == .roleGated && !canMutate)
            || (guarded.contains(command.name) && identity?.role == "observer")
    }

    /// Whether the lane holds a cut, which is what a catch-up reconciles from.
    public var isSynchronized: Bool { holdsCut }

    /// The commands waiting for the exchange in flight.
    public var waiting: Int { queue.count }

    /// Whether a request is outstanding.
    public var isInFlight: Bool {
        switch phase {
        case .awaitingBegin, .receiving, .awaitingReply: return true
        case .ready, .closed: return false
        }
    }

    /// The earliest reading at which `tick` can act, or nil when nothing a tick can
    /// do is pending. A tick before it changes nothing and a tick at it acts (N1).
    public var nextDue: Int? {
        switch phase {
        case .awaitingBegin, .receiving, .awaitingReply: return deadline
        case .ready: return holdsCut ? refreshAt : nil
        case .closed: return nil
        }
    }

    /// Hands the host everything the lane decided to write or close, in order.
    public mutating func takeOutputs() -> [Out] {
        defer { outbox = [] }
        return outbox
    }

    // MARK: Admission

    /// Admits a command: written now if the lane is idle, queued behind the exchange
    /// in flight otherwise, and refused if the lane is closed or this attachment may
    /// not mutate.
    ///
    /// The returned ticket names the command in every later update. A refused
    /// command never reaches the wire, and the ticket says so by `notSent`.
    public mutating func submit(_ command: Command, now: Int) -> (ticket: Ticket, disposition: Disposition, updates: [Update]) {
        let ticket = nextTicket
        nextTicket += 1
        guard phase != .closed else {
            return (ticket, .notSent(reason: "the lane has ended"), [])
        }
        if refuses(command) {
            return (ticket, .notSent(reason: "this attachment is read-only"), [])
        }
        if phase == .ready, queue.isEmpty {
            let id = send(command, ticket: ticket, now: now)
            return (ticket, .sent(id: id), [])
        }
        queue.append(Waiting(ticket: ticket, command: command))
        return (ticket, .waiting, [])
    }

    /// Cancels the commands that have not been written, which is what Escape does to
    /// an unsent message. A written command is untouched.
    public mutating func cancelWaiting(reason: String) -> [Update] {
        let cancelled = queue
        queue = []
        return cancelled.map { notice(for: $0, reason: reason) }
    }

    // MARK: Frames

    /// Reduces one text frame from the socket.
    public mutating func receive(_ text: String, now: Int) -> [Update] {
        guard phase != .closed else { return [] }
        let frame: EventEnvelope
        do {
            frame = try EventEnvelope.decode(text)
        } catch {
            return fail((error as? LoomError) ?? .protocolViolation("a frame did not decode"))
        }
        guard let replyTo = frame.replyTo else {
            return pushed(frame, now: now)
        }

        // A reply names the one request in flight. Anything else is a request
        // that is finished or never was, so the stop-and-wait order is broken.
        guard let pending = inflight, pending.id == replyTo, phase != .ready else {
            return fail(.protocolViolation("reply_to \(replyTo) answers no outstanding command"))
        }
        return reply(frame, to: pending, now: now)
    }

    /// Reduces the transport's report that the socket ended or failed.
    public mutating func receive(failed error: LoomError) -> [Update] {
        // A socket reports its end more than once, and a close this client asked for is followed
        // by the transport's own. The lane is closed once and tells nobody twice.
        guard phase != .closed else { return [] }
        return fail(error)
    }

    /// Drives the deadline and the idle refresh. A host may call it as often as it
    /// likes, because it acts only at or after `nextDue`.
    public mutating func tick(now: Int) -> [Update] {
        switch phase {
        case .closed:
            return []
        case .awaitingBegin, .receiving, .awaitingReply:
            guard now >= deadline, let pending = inflight else { return [] }
            return fail(.outcomeUnknown(command: pending.command))
        case .ready:
            guard holdsCut, refreshAt <= now else { return [] }
            issueCapture(command: "catch_up", body: ["from_seq": .int(Int64(cursor))], trigger: .refreshed, now: now)
            return []
        }
    }

    /// Ends the lane because this client asked to. It is the quit path: the
    /// outstanding mutation is reported unknown, because it was written, and each
    /// waiting command is reported not sent.
    public mutating func close() -> [Update] {
        guard phase != .closed else { return [] }
        return end(with: nil, because: .closed("the lane has ended"))
    }

    // MARK: Replies

    private mutating func reply(_ frame: EventEnvelope, to pending: Inflight, now: Int) -> [Update] {
        let isError = frame.event == "error"
        switch phase {
        case .awaitingBegin:
            return beginOwn(frame, pending: pending, isError: isError, now: now)
        case .awaitingReply:
            if isError {
                return settle(pending, refusedBy: frame, now: now)
            }
            if pending.kind == .transfer {
                return begin(frame, pending: pending)
            }
            guard frame.event != "snapshot_begin" else {
                return fail(.protocolViolation("\(pending.command) began a transfer"))
            }
            return answered(frame, pending: pending, now: now)
        case .receiving:
            return receiveFragment(frame, pending: pending, isError: isError, now: now)
        case .ready, .closed:
            return fail(.protocolViolation("an unsolicited reply"))
        }
    }

    /// The lane's own capture: a begin opens the transfer, a refusal retries it
    /// later if a cut is held and ends the lane otherwise.
    private mutating func beginOwn(_ frame: EventEnvelope, pending: Inflight, isError: Bool, now: Int) -> [Update] {
        if isError {
            let code = frame.body["code"]?.string ?? "unknown"
            guard holdsCut else {
                return fail(.server(code: code, message: frame.body["message"]?.string ?? "", details: frame.body["details"]))
            }

            // A refusal leaves the socket healthy, so the next refresh retries.
            inflight = nil
            phase = .ready
            refreshAt = now + refreshInterval
            return sendQueued(now: now)
        }
        return begin(frame, pending: pending)
    }

    private mutating func begin(_ frame: EventEnvelope, pending: Inflight) -> [Update] {
        guard frame.event == "snapshot_begin" else {
            return fail(.protocolViolation("\(pending.command) did not begin a transfer"))
        }
        do {
            assembler = try TransferAssembler(begin: frame.body, expectedSession: sessionID, expectedIdentity: identity)
        } catch {
            return fail((error as? LoomError) ?? .protocolViolation("snapshot_begin was refused"))
        }
        return grantCredit(pending: pending)
    }

    private mutating func receiveFragment(_ frame: EventEnvelope, pending: Inflight, isError: Bool, now: Int) -> [Update] {
        if isError {
            return fail(.server(
                code: frame.body["code"]?.string ?? "unknown",
                message: frame.body["message"]?.string ?? "",
                details: frame.body["details"]
            ))
        }
        guard var open = assembler else {
            return fail(.protocolViolation("a fragment arrived with no open transfer"))
        }
        switch frame.event {
        case "snapshot_chunk":
            do {
                try open.absorb(chunk: frame.body)
            } catch {
                return fail((error as? LoomError) ?? .protocolViolation("a chunk was refused"))
            }
            assembler = open
            return grantCredit(pending: pending)
        case "snapshot_end":
            do {
                return complete(try open.finish(end: frame.body), pending: pending, now: now)
            } catch {
                return fail((error as? LoomError) ?? .protocolViolation("snapshot_end was refused"))
            }
        default:
            return fail(.protocolViolation("unexpected \(frame.event) inside a transfer"))
        }
    }

    /// Asks for the next fragment. The reply to the last one released the wire, so
    /// this is the one correlated write a transfer makes while it is open (I6).
    private mutating func grantCredit(pending: Inflight) -> [Update] {
        guard let open = assembler else { return [] }
        let id = allocate()
        write(id: id, command: "snapshot_next", body: [
            "snapshot_id": .string(open.snapshotID),
            "index": .int(Int64(open.index)),
        ])
        inflight = Inflight(id: id, ticket: pending.ticket, command: pending.command, kind: pending.kind)
        phase = .receiving
        return []
    }

    private mutating func complete(_ cut: Cut, pending: Inflight, now: Int) -> [Update] {
        assembler = nil
        inflight = nil
        phase = .ready
        identity = cut.identity

        // A history window pages backward and must not move the reconcile cursor,
        // or the live tail would be skipped.
        let paged = ["history", "lineage", "decided", "escalations"].contains(cut.window)
        if !paged { cursor = max(cursor, cut.nextSeq) }
        let reason = trigger
        var updates: [Update] = []
        if pending.ticket == nil {
            holdsCut = true
            refreshAt = now + refreshInterval
            updates.append(.cut(nil, cut, reason))
        } else {
            updates.append(.cut(pending.ticket, cut, .requested))
        }
        return updates + sendQueued(now: now)
    }

    private mutating func answered(_ frame: EventEnvelope, pending: Inflight, now: Int) -> [Update] {
        inflight = nil
        phase = .ready
        guard let ticket = pending.ticket else { return sendQueued(now: now) }

        // A committed mutation is worth seeing now, not at the next refresh.
        if pending.kind == .mutation { refreshAt = now }
        return [.replied(ticket, frame)] + sendQueued(now: now)
    }

    private mutating func settle(_ pending: Inflight, refusedBy frame: EventEnvelope, now: Int) -> [Update] {
        inflight = nil
        phase = .ready
        guard let ticket = pending.ticket else { return sendQueued(now: now) }
        let refusal = Update.refused(
            ticket,
            code: frame.body["code"]?.string ?? "unknown",
            message: frame.body["message"]?.string ?? "",
            details: frame.body["details"]
        )
        return [refusal] + sendQueued(now: now)
    }

    // MARK: Pushes

    /// A pushed frame arrives in every open phase. It spends no credit, allocates no
    /// identity and cannot fail the lane (I8). What a commit notice does is move a
    /// catch-up earlier, which makes it idempotent and order-free: a sequence the lane
    /// holds says nothing new, a lost notice is repaired by the refresh, and a daemon
    /// that pushes nothing leaves the refresh as the only path.
    private mutating func pushed(_ frame: EventEnvelope, now: Int) -> [Update] {
        delivery = .pushing
        var updates: [Update] = [.pushed(frame)]
        switch frame.event {
        case "committed":
            let seq = frame.seq ?? .max
            updates.append(.noticed(seq: seq))
            if !holdsCut || seq >= cursor { captureOrDefer(now: now) }
        case "presence", "attachment", "input_queue_changed":
            captureOrDefer(now: now)
        default:
            break
        }
        return updates
    }

    /// Issues a catch-up now if the wire is free, or remembers that one is owed. One
    /// owed catch-up is enough, because an invalidation carries no state of its own.
    private mutating func captureOrDefer(now: Int) {
        guard holdsCut else { return }
        switch phase {
        case .ready:
            refreshDue = false
            issueCapture(command: "catch_up", body: ["from_seq": .int(Int64(cursor))], trigger: .notified, now: now)
        case .awaitingBegin, .receiving, .awaitingReply:
            refreshDue = true
        case .closed:
            break
        }
    }

    // MARK: Issuing

    /// Spends the free wire: the first waiting command, then a deferred catch-up.
    private mutating func sendQueued(now: Int) -> [Update] {
        var updates: [Update] = []
        while phase == .ready, !queue.isEmpty {
            let next = queue.removeFirst()
            if refuses(next.command) {
                updates.append(.notSent(next.ticket, reason: "this attachment is read-only"))
                continue
            }
            let id = send(next.command, ticket: next.ticket, now: now)
            updates.append(.sent(next.ticket, id: id))
        }
        if phase == .ready, refreshDue, holdsCut {
            refreshDue = false
            issueCapture(command: "catch_up", body: ["from_seq": .int(Int64(cursor))], trigger: .notified, now: now)
        }
        return updates
    }

    private mutating func send(_ command: Command, ticket: Ticket, now: Int) -> Int {
        let id = allocate()
        write(id: id, command: command.name, body: command.body)
        inflight = Inflight(id: id, ticket: ticket, command: command.name, kind: command.kind)
        phase = .awaitingReply
        deadline = now + Self.commandDeadlineMs
        return id
    }

    private mutating func issueCapture(command: String, body: JSONValue, trigger: Trigger, now: Int) {
        let id = allocate()
        write(id: id, command: command, body: body)
        inflight = Inflight(id: id, ticket: nil, command: command, kind: .transfer)
        self.trigger = trigger
        phase = .awaitingBegin
        deadline = now + Self.captureDeadlineMs
    }

    private mutating func allocate() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// Queues one frame. The encoder cannot fail on the values a lane builds, so a
    /// frame that did not encode would be a defect, and an empty frame would be
    /// refused by the daemon rather than misread.
    private mutating func write(id: Int, command: String, body: JSONValue) {
        outbox.append(.transmit((try? encodeCommand(id: id, cmd: command, body: body)) ?? ""))
    }

    private var refreshInterval: Int {
        delivery == .polling ? Self.pollingRefreshMs : Self.pushingRefreshMs
    }

    // MARK: Ending

    private mutating func fail(_ error: LoomError) -> [Update] {
        end(with: error, because: error)
    }

    /// Closes the lane and settles every command it still owes an outcome. The
    /// outstanding mutation was written, so its outcome is unknown. A read or a
    /// transfer is simply lost. Each waiting command never reached the wire.
    private mutating func end(with error: LoomError?, because cause: LoomError) -> [Update] {
        var updates: [Update] = []
        if let pending = inflight, let ticket = pending.ticket {
            switch pending.kind {
            case .mutation:
                updates.append(.unknown(ticket, command: pending.command, id: pending.id))
            case .read, .transfer:
                updates.append(.failed(ticket, command: pending.command, cause))
            }
        }
        updates += queue.map { notice(for: $0, reason: cause.errorDescription ?? "the lane ended") }
        inflight = nil
        assembler = nil
        queue = []
        phase = .closed
        outbox.append(.shut)
        updates.append(.closed(error))
        return updates
    }

    private func notice(for waiting: Waiting, reason: String) -> Update {
        switch waiting.command.kind {
        case .mutation: return .notSent(waiting.ticket, reason: reason)
        case .read, .transfer: return .failed(waiting.ticket, command: waiting.command.name, .closed(reason))
        }
    }
}
