import Foundation

/// The client's side of the daemon's control socket, as a value.
///
/// This file is held to the same purity rule as `Sources/LoomCore` (`scripts/core-purity.sh`
/// scans it), because it decides and does nothing else. It lives in LoomKit so that
/// `ControlClient`, the shell around it, can use it without a dependency cycle.
///
/// The control socket opens with a `hello` that names the daemon's epoch, and then
/// answers one command at a time. Like `Lane` this value reads no clock, owns no
/// socket and starts no task: the host feeds it frames, a close and ticks with `now`,
/// and performs the outputs it returns.
///
/// ## Priority (audit finding H6)
///
/// Every control command shares one stop-and-wait credit, and `sessions.review` may
/// hold it for 16 s. Before, the credit was a FIFO, so the poll's next `status`, a
/// created session and an answered ask all queued behind a background read in the order
/// they asked. Here each command carries a priority. When the credit is free the lane
/// writes the oldest `owner` command before any `background` one, so a person's action
/// waits behind at most the one read already on the wire, never behind reads that
/// queued after it began. The protocol's rule is unchanged: the read on the wire is not
/// preempted, because the daemon answers in order. The bound is the in-flight command's
/// deadline, 16 s for a review and 6 s for everything else.
///
/// ## What a lost reply means
///
/// A command whose reply does not arrive in time ends the lane and reports `lost` for
/// exactly that ticket. A command never resent automatically (client protocol section
/// 6.5), so a caller that retries must carry its own idempotency key, as
/// `sessions.create` does with `request_key`.
public struct ControlLane: Sendable, Equatable {
    /// How long one command may wait for its reply, in milliseconds.
    public static func deadlineMs(for command: String) -> Int {
        command == "sessions.review" ? 16_000 : 6_000
    }

    /// How long the daemon has to send `hello`.
    public static let helloDeadlineMs = 6_000

    /// Who is waiting on a command.
    public enum Priority: Sendable, Equatable {
        /// A person's action: create, stop, answer, open.
        case owner
        /// A poll or a background read.
        case background
    }

    public struct Command: Sendable, Equatable {
        public let name: String
        public let body: JSONValue
        public let priority: Priority

        public init(_ name: String, body: JSONValue = .object([:]), priority: Priority) {
            self.name = name
            self.body = body
            self.priority = priority
        }
    }

    public typealias Ticket = Int

    public enum Out: Sendable, Equatable {
        case transmit(String)
        case shut
    }

    public enum Update: Sendable, Equatable {
        /// The daemon's opening frame, with its whole body for the host to decode.
        case hello(epoch: String, body: JSONValue)
        case replied(Ticket, JSONValue)
        case refused(Ticket, code: String, message: String, details: JSONValue?)
        /// The reply was lost, so the command may have taken effect.
        case lost(Ticket, command: String)
        /// The command never reached the wire, or was a read the lane ended on.
        case failed(Ticket, LoomError)
        case closed(LoomError?)
    }

    public enum Phase: Sendable, Equatable {
        case awaitingHello, ready, awaitingReply, closed
    }

    public private(set) var phase: Phase = .awaitingHello
    public private(set) var epoch: String?
    public private(set) var deadline: Int
    public private(set) var nextID = 1

    private struct Inflight: Sendable, Equatable {
        var id: Int
        var ticket: Ticket
        var command: String
    }

    private struct Waiting: Sendable, Equatable {
        var ticket: Ticket
        var command: Command
    }

    private var inflight: Inflight?
    private var queue: [Waiting] = []
    private var nextTicket = 1
    private var outbox: [Out] = []

    public init(now: Int) {
        deadline = now + Self.helloDeadlineMs
    }

    public var isOpen: Bool { phase == .ready || phase == .awaitingReply }

    /// Whether an owner command is waiting, which a background read must not pass.
    public var ownerWaiting: Bool { queue.contains { $0.command.priority == .owner } }

    public var waiting: Int { queue.count }

    /// The instant a tick can next act: the hello or reply deadline.
    public var nextDue: Int? {
        switch phase {
        case .awaitingHello, .awaitingReply: return deadline
        case .ready, .closed: return nil
        }
    }

    public mutating func takeOutputs() -> [Out] {
        defer { outbox = [] }
        return outbox
    }

    /// Admits a command. Before the hello it waits, because every command after it names
    /// the epoch the hello gave.
    public mutating func submit(_ command: Command, now: Int) -> (ticket: Ticket, updates: [Update]) {
        let ticket = nextTicket
        nextTicket += 1
        guard phase != .closed else {
            return (ticket, [.failed(ticket, .closed("the control connection has ended"))])
        }
        queue.append(Waiting(ticket: ticket, command: command))
        return (ticket, sendNext(now: now))
    }

    public mutating func receive(_ text: String, now: Int) -> [Update] {
        guard phase != .closed else { return [] }
        let frame: EventEnvelope
        do {
            frame = try EventEnvelope.decode(text)
        } catch {
            return fail((error as? LoomError) ?? .protocolViolation("a frame did not decode"))
        }
        switch phase {
        case .awaitingHello:
            guard frame.event == "hello", frame.replyTo == nil, let epoch = frame.body["epoch"]?.string else {
                return fail(.protocolViolation("the control socket did not open with hello"))
            }
            self.epoch = epoch
            phase = .ready
            return [.hello(epoch: epoch, body: frame.body)] + sendNext(now: now)
        case .awaitingReply:
            guard let pending = inflight, frame.replyTo == pending.id else {
                return fail(.protocolViolation("reply_to \(frame.replyTo ?? -1) answers no outstanding command"))
            }
            inflight = nil
            phase = .ready
            let update: Update
            if frame.event == "error" {
                update = .refused(
                    pending.ticket,
                    code: frame.body["code"]?.string ?? "unknown",
                    message: frame.body["message"]?.string ?? "",
                    details: frame.body["details"]
                )
            } else {
                update = .replied(pending.ticket, frame.body)
            }
            return [update] + sendNext(now: now)
        case .ready, .closed:
            // The control socket pushes nothing after hello.
            return fail(.protocolViolation("an unsolicited frame on the control socket"))
        }
    }

    public mutating func receive(failed error: LoomError) -> [Update] {
        guard phase != .closed else { return [] }
        return fail(error)
    }

    public mutating func tick(now: Int) -> [Update] {
        switch phase {
        case .awaitingHello:
            guard now >= deadline else { return [] }
            return fail(.outcomeUnknown(command: "hello"))
        case .awaitingReply:
            guard now >= deadline, let pending = inflight else { return [] }
            return fail(.outcomeUnknown(command: pending.command))
        case .ready, .closed:
            return []
        }
    }

    public mutating func close() -> [Update] {
        guard phase != .closed else { return [] }
        return end(error: nil, cause: .closed("the control connection has ended"))
    }

    // MARK: Internals

    /// Writes the oldest owner command, else the oldest background one, when the credit is free.
    private mutating func sendNext(now: Int) -> [Update] {
        guard phase == .ready, !queue.isEmpty else { return [] }
        let index = queue.firstIndex { $0.command.priority == .owner } ?? 0
        let next = queue.remove(at: index)
        let id = nextID
        nextID += 1
        outbox.append(.transmit((try? encodeCommand(id: id, cmd: next.command.name, body: next.command.body)) ?? ""))
        inflight = Inflight(id: id, ticket: next.ticket, command: next.command.name)
        phase = .awaitingReply
        deadline = now + Self.deadlineMs(for: next.command.name)
        return []
    }

    private mutating func fail(_ error: LoomError) -> [Update] {
        end(error: error, cause: error)
    }

    private mutating func end(error: LoomError?, cause: LoomError) -> [Update] {
        var updates: [Update] = []
        if let pending = inflight {
            updates.append(.lost(pending.ticket, command: pending.command))
        }
        updates += queue.map { .failed($0.ticket, cause) }
        inflight = nil
        queue = []
        phase = .closed
        outbox.append(.shut)
        updates.append(.closed(error))
        return updates
    }
}
