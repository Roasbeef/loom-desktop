import Foundation
import LoomCore
import LoomKit

/// What a lane reports to whoever drew it.
public enum LaneEvent: Sendable {
    /// A transfer completed.
    case cut(Cut)
    /// A frame the server pushed on its own initiative.
    case push(EventEnvelope)
    /// The lane ended. A nil error is a close this client asked for.
    case closed(LoomError?)
}

/// One attachment to one resident session: `/v2/sessions/<id>/ws`.
///
/// This actor is the shell around `LoomCore.Lane`. The lane decides: which
/// command is in flight, when a transfer asks for its next fragment, when the
/// refresh and the reply deadline fall, and what a lost reply means. The actor
/// only carries those decisions out. It forwards each received frame to the lane
/// with a clock reading, writes the lane's outputs to the socket in the order the
/// lane decided them, arms one timer for `nextDue`, and resumes the caller each
/// update names. It holds no protocol state of its own, so the rules the model
/// test checks are the rules that run here.
///
/// The public API is the one the app used before the lane became a value:
/// commands are `async` and return the daemon's reply, and `events` carries cuts,
/// pushes and the close.
public actor SessionLane {
    public let sessionID: String
    public nonisolated let events: AsyncStream<LaneEvent>

    /// What a caller waits for: a reply, or a completed transfer.
    private enum Outcome: Sendable {
        case reply(EventEnvelope)
        case cut(Cut)
    }

    private let continuation: AsyncStream<LaneEvent>.Continuation
    private let transport: any ControlTransport
    private let writes: AsyncStream<String>.Continuation
    private let writeQueue: AsyncStream<String>
    private let origin = ContinuousClock.now

    private var core: Lane
    private var waiters: [Lane.Ticket: CheckedContinuation<Outcome, Error>] = [:]
    private var firstCut: CheckedContinuation<Void, Error>?
    private var ended: LoomError?
    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    public init(endpoint: DaemonEndpoint, sessionID: String) throws {
        self.init(
            sessionID: sessionID,
            transport: WebSocket(url: try endpoint.url(path: "/v2/sessions/\(sessionID)/ws"), bearer: endpoint.token)
        )
    }

    /// A lane over any transport, for a test that stands in for the daemon.
    ///
    /// The subscribe is decided here and buffered, so a command submitted before
    /// `start` queues behind it in the lane, in the order the daemon will see.
    public init(sessionID: String, transport: any ControlTransport) {
        self.sessionID = sessionID
        self.transport = transport
        (events, continuation) = AsyncStream.makeStream(of: LaneEvent.self, bufferingPolicy: .unbounded)
        (writeQueue, writes) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        var lane = Lane.start(sessionID: sessionID, admission: .daemonDecides, now: 0)
        for case .transmit(let text) in lane.takeOutputs() { writes.yield(text) }
        core = lane
    }

    /// Subscribes, completes the initial transfer, and starts reconciling.
    public func start() async throws {
        guard readerTask == nil else { return }
        readerTask = Task { await self.readLoop() }
        writerTask = Task { await self.writeLoop() }
        arm()
        do {
            try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
                if let ended {
                    resume.resume(throwing: ended)
                } else if core.isSynchronized {
                    resume.resume()
                } else {
                    firstCut = resume
                }
            }
        } catch {
            // A lane with no first cut has nothing to reconcile from, so even a
            // plain refusal ends it. Otherwise it would look attached forever.
            throw (error as? LoomError) ?? .closed(error.localizedDescription)
        }
    }

    public func close() {
        apply { $0.close() }
    }

    // MARK: Commands

    /// Sends a prompt, returning the outcome status: `admitted` or `queued`.
    /// Neither is proof the write committed, so the transcript waits for a cut.
    public func prompt(strand: String, text: String) async throws -> String {
        try await mutate("prompt", body: ["strand": .string(strand), "text": .string(text)])
    }

    public func steer(strand: String, text: String) async throws -> String {
        try await mutate("steer", body: ["strand": .string(strand), "text": .string(text)])
    }

    public func abort(strand: String) async throws -> String {
        try await mutate("abort", body: ["strand": .string(strand)])
    }

    /// Approves exactly what the person was shown. The caller passes the record
    /// it displayed, so `grants` and `action` are never rebuilt from elsewhere.
    ///
    /// `remember` keeps the grant for the rest of the session, so the next call
    /// needing the same authority does not ask again.
    public func approve(_ record: Escalation, remember: Bool = false) async throws -> String {
        var body: [String: JSONValue] = [
            "escalation_id": .string(record.id),
            "grants": .array(record.grants),
            "action": .string(record.action),
            "expected_seq": .int(Int64(record.seq)),
        ]
        if remember { body["scope"] = "session" }
        return try await mutate("approve", body: .object(body))
    }

    public func deny(_ record: Escalation) async throws -> String {
        try await mutate("deny", body: [
            "escalation_id": .string(record.id),
            "expected_seq": .int(Int64(record.seq)),
        ])
    }

    /// Asks for the worktree board. The final board arrives as a push.
    public func requestWorktreeDiff() async throws {
        _ = try await mutate("worktree_diff", body: .object([:]))
    }

    /// Asks for a page of a remote child's transcript. The page arrives as a
    /// push, because the daemon reads it from the other orchestrator.
    public func requestChildHistory(child: String, before: Int = 0) async throws {
        _ = try await mutate("child_history", body: ["child": .string(child), "before": .int(Int64(before))])
    }

    /// Loads the entries just below `beforeSeq`.
    ///
    /// A `history` page ascends from its lower bound, while a person scrolling
    /// wants what sits nearest the window. So this picks a lower bound close
    /// below the window and follows `more_after` until that span is exhausted.
    /// It returns the lower bound it reached, the cursor for the next call. The
    /// sequence space is shared with non-entry writes, so a span can hold no
    /// entries, and a cursor taken from the entries alone would never move.
    @discardableResult
    public func loadOlder(beforeSeq: Int, span: Int = 400) async throws -> Int {
        let floor = max(0, beforeSeq - span)
        var after = floor
        while true {
            let cut = try await transfer(cmd: "history", body: [
                "after_seq": .int(Int64(after)),
                "before_seq": .int(Int64(beforeSeq)),
            ])
            guard let more = cut.moreAfter else { return floor }
            after = more
        }
    }

    /// Reads one page of a strand's records by following its parent links, ending
    /// at `from`. A page whose newest record is another entry is refused, because
    /// it is not the path that was asked for (protocol section 4.6.1).
    public func lineage(from: String) async throws -> Cut {
        let cut = try await transfer(cmd: "history_lineage", body: ["from": .string(from)])
        if let newest = cut.entries.last, newest["id"]?.string != from {
            throw LoomError.protocolViolation("history_lineage ended at another entry")
        }
        return cut
    }

    /// Reads the session's decided approvals, newest sixteen.
    public func decided() async throws -> Cut {
        try await transfer(cmd: "escalations_decided", body: .object([:]))
    }

    /// Sends any session command and returns its reply. New surfaces use this, so a
    /// command needs no method of its own to keep the credit's order. A reply that is
    /// a `snapshot` should go to `Conversation.apply(push:)`, the same as a push.
    /// The lane refreshes soon after it, because it may have changed the session.
    public func request(_ cmd: String, body: JSONValue = .object([:])) async throws -> EventEnvelope {
        guard case .reply(let reply) = try await submit(Lane.Command(cmd, body: body, kind: .mutation)) else {
            throw LoomError.protocolViolation("\(cmd) answered with a transfer")
        }
        return reply
    }

    /// Sends a command that changes nothing, so its reply needs no early reconcile. A
    /// panel that polls with this does not cost a catch-up transfer on every poll.
    public func read(_ cmd: String, body: JSONValue = .object([:])) async throws -> EventEnvelope {
        guard case .reply(let reply) = try await submit(Lane.Command(cmd, body: body, kind: .read)) else {
            throw LoomError.protocolViolation("\(cmd) answered with a transfer")
        }
        return reply
    }

    private func mutate(_ cmd: String, body: JSONValue) async throws -> String {
        let reply = try await request(cmd, body: body)
        return reply.body["status"]?.string ?? reply.event
    }

    private func transfer(cmd: String, body: JSONValue) async throws -> Cut {
        guard case .cut(let cut) = try await submit(Lane.Command(cmd, body: body, kind: .transfer)) else {
            throw LoomError.protocolViolation("\(cmd) did not begin a transfer")
        }
        return cut
    }

    // MARK: The bridge to the lane

    /// Admits one command and waits for the update that settles its ticket. The
    /// waiter is stored before the updates are handled, because an immediate
    /// refusal settles the ticket in the same step.
    private func submit(_ command: Lane.Command) async throws -> Outcome {
        try await withCheckedThrowingContinuation { resume in
            let admitted = core.submit(command, now: now())
            waiters[admitted.ticket] = resume
            var updates = admitted.updates
            if case .notSent(let reason) = admitted.disposition {
                updates.append(.notSent(admitted.ticket, reason: reason))
            }
            handle(updates)
        }
    }

    /// Runs one lane transition, then carries out what it decided: writes in order,
    /// callers resumed, and the timer armed for the new `nextDue`.
    private func apply(_ transition: (inout Lane) -> [Lane.Update]) {
        handle(transition(&core))
    }

    private func handle(_ updates: [Lane.Update]) {
        for output in core.takeOutputs() {
            switch output {
            case .transmit(let text): writes.yield(text)
            case .shut: writes.finish()
            }
        }
        for update in updates { route(update) }
        arm()
    }

    private func route(_ update: Lane.Update) {
        switch update {
        case .sent, .noticed:
            break
        case .notSent(let ticket, let reason):
            settle(ticket, .failure(LoomError.closed(reason)))
        case .replied(let ticket, let reply):
            settle(ticket, .success(.reply(reply)))
        case .refused(let ticket, let code, let message, let details):
            settle(ticket, .failure(LoomError.server(code: code, message: message, details: details)))
        case .cut(let ticket, let cut, _):
            continuation.yield(.cut(cut))
            if let ticket {
                settle(ticket, .success(.cut(cut)))
            } else if let waiting = firstCut {
                firstCut = nil
                waiting.resume()
            }
        case .unknown(let ticket, let command, _):
            settle(ticket, .failure(LoomError.outcomeUnknown(command: command)))
        case .failed(let ticket, _, let error):
            settle(ticket, .failure(error))
        case .pushed(let frame):
            continuation.yield(.push(frame))
        case .closed(let error):
            finish(error)
        }
    }

    private func settle(_ ticket: Lane.Ticket, _ result: Result<Outcome, Error>) {
        waiters.removeValue(forKey: ticket)?.resume(with: result)
    }

    private func finish(_ error: LoomError?) {
        ended = error ?? .closed("the lane has ended")
        readerTask?.cancel()
        timer?.cancel()
        transport.close()
        if let waiting = firstCut {
            firstCut = nil
            waiting.resume(throwing: ended ?? .closed("the lane has ended"))
        }
        continuation.yield(.closed(error))
        continuation.finish()
    }

    // MARK: Reader, writer and the one timer

    private func readLoop() async {
        while core.phase != .closed {
            do {
                let text = try await transport.receive()
                apply { $0.receive(text, now: now()) }
            } catch let error as LoomError {
                apply { $0.receive(failed: error) }
            } catch {
                apply { $0.receive(failed: .closed(error.localizedDescription)) }
            }
        }
    }

    /// Writes frames in the order the lane decided them. One writer keeps that
    /// order, which separate tasks per frame would not.
    private func writeLoop() async {
        for await text in writeQueue {
            do {
                try await transport.send(text)
            } catch let error as LoomError {
                apply { $0.receive(failed: error) }
            } catch {
                apply { $0.receive(failed: .closed(error.localizedDescription)) }
            }
        }
    }

    /// Arms the single wake-up the lane asks for. Nothing ticks on a fixed cadence.
    private func arm() {
        timer?.cancel()
        timer = nil
        guard let due = core.nextDue else { return }
        let wait = max(1, due - now())
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled else { return }
            await self?.wake()
        }
    }

    private func wake() {
        apply { $0.tick(now: now()) }
    }

    /// Milliseconds since this lane was made, a monotonic reading.
    private func now() -> Int {
        let elapsed = ContinuousClock.now - origin
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
