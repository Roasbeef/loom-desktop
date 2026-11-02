import Foundation

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
/// A lane enforces the session protocol's two rules of order. At most one
/// command is in flight, and at most one transfer is open, so `CreditLock` is
/// held across a whole transfer and a prompt typed mid-transfer waits its turn.
/// Reads and replies share one socket, so a reader task routes each frame: a
/// frame with `reply_to` answers the outstanding command, and any other frame
/// is a push that may arrive in any phase.
public actor SessionLane {
    /// The server answers one command within six seconds.
    private static let replyDeadline = 6.0
    /// The reconcile cadence with no notice to act on. `catch_up` is also the
    /// only way to see metadata-only changes, which produce no notice, so the
    /// refresh never stops. It relaxes while cuts keep coming back empty and
    /// tightens at the first notice, so a resting session costs almost nothing.
    private static let idleRefresh: Duration = .seconds(1)
    private static let restingRefresh: Duration = .seconds(5)

    public let sessionID: String
    public nonisolated let events: AsyncStream<LaneEvent>

    private let continuation: AsyncStream<LaneEvent>.Continuation
    private let socket: WebSocket
    private let credit = CreditLock()

    private var nextID = 1
    private var outstanding: (id: Int, reply: CheckedContinuation<EventEnvelope, Error>)?
    private var identity: Cut.Identity?
    private var nextSeq = 0
    private var dirty = false
    private var refreshInterval = SessionLane.idleRefresh
    private var closed = false
    private var readerTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    public init(endpoint: DaemonEndpoint, sessionID: String) throws {
        self.sessionID = sessionID
        socket = WebSocket(url: try endpoint.url(path: "/v2/sessions/\(sessionID)/ws"), bearer: endpoint.token)
        (events, continuation) = AsyncStream.makeStream(of: LaneEvent.self, bufferingPolicy: .unbounded)
    }

    /// Subscribes, completes the initial transfer, and starts reconciling.
    public func start() async throws {
        readerTask = Task { await self.readLoop() }
        do {
            try await transfer(cmd: "subscribe", body: ["session": .string(sessionID)])
        } catch {
            // A lane with no first cut has nothing to reconcile from, so even a
            // plain refusal ends it. Otherwise it would look attached forever.
            let reason = (error as? LoomError) ?? .closed(error.localizedDescription)
            finish(reason)
            throw reason
        }
        refreshTask = Task { await self.refreshLoop() }
    }

    public func close() {
        finish(nil)
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

    private func mutate(_ cmd: String, body: JSONValue) async throws -> String {
        await credit.acquire()
        do {
            let reply = try await exchange(cmd, body: body)
            await credit.release()

            // A committed mutation is worth seeing now, not at the next tick.
            dirty = true
            return reply.body["status"]?.string ?? reply.event
        } catch {
            await credit.release()
            throw error
        }
    }

    // MARK: The credited exchange

    /// Sends one command and waits for its correlated reply. The caller holds
    /// the credit. A timeout closes the lane because the outcome is unknown and
    /// the stop-and-wait order can no longer be trusted.
    private func exchange(_ cmd: String, body: JSONValue) async throws -> EventEnvelope {
        guard !closed else { throw LoomError.closed("the lane has ended") }
        let id = nextID
        nextID += 1
        let text = try encodeCommand(id: id, cmd: cmd, body: body)
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(Self.replyDeadline))

            // A reply that landed just before the deadline must not end the lane.
            await self?.expire(id: id, command: cmd)
        }
        defer { timeout.cancel() }

        let reply: EventEnvelope = try await withCheckedThrowingContinuation { resume in
            outstanding = (id, resume)
            Task { [socket] in
                do {
                    try await socket.send(text)
                } catch let error as LoomError {
                    self.finish(error)
                } catch {
                    self.finish(.closed(error.localizedDescription))
                }
            }
        }
        if reply.event == "error" {
            throw LoomError.server(
                code: reply.body["code"]?.string ?? "unknown",
                message: reply.body["message"]?.string ?? "",
                details: reply.body["details"]
            )
        }
        return reply
    }

    private func expire(id: Int, command: String) {
        if outstanding?.id == id { finish(.outcomeUnknown(command: command)) }
    }

    /// Runs one snapshot transfer under the credit and reports the whole cut.
    @discardableResult
    private func transfer(cmd: String, body: JSONValue) async throws -> Cut {
        await credit.acquire()
        do {
            let begin = try await exchange(cmd, body: body)
            guard begin.event == "snapshot_begin" else {
                throw LoomError.protocolViolation("\(cmd) did not begin a transfer")
            }
            var assembler = try TransferAssembler(begin: begin.body, expectedSession: sessionID, expectedIdentity: identity)
            while true {
                let frame = try await exchange("snapshot_next", body: [
                    "snapshot_id": .string(assembler.snapshotID),
                    "index": .int(Int64(assembler.index)),
                ])
                if frame.event == "snapshot_chunk" {
                    try assembler.absorb(chunk: frame.body)
                } else if frame.event == "snapshot_end" {
                    let cut = try assembler.finish(end: frame.body)
                    await credit.release()
                    identity = cut.identity

                    // A history window pages backward and must not move the
                    // reconcile cursor, or the live tail would be skipped.
                    if cut.window != "history" && cut.window != "lineage" {
                        nextSeq = max(nextSeq, cut.nextSeq)
                    }
                    continuation.yield(.cut(cut))
                    return cut
                } else {
                    throw LoomError.protocolViolation("unexpected \(frame.event) inside a transfer")
                }
            }
        } catch {
            await credit.release()
            if let error = error as? LoomError, case .protocolViolation = error {
                finish(error)
            }
            throw error
        }
    }

    // MARK: Reader and reconcile loops

    private func readLoop() async {
        while !closed {
            do {
                let text = try await socket.receive()
                try route(try EventEnvelope.decode(text))
            } catch let error as LoomError {
                finish(error)
            } catch {
                finish(.closed(error.localizedDescription))
            }
        }
    }

    private func route(_ frame: EventEnvelope) throws {
        guard let replyTo = frame.replyTo else {
            handlePush(frame)
            return
        }
        guard let pending = outstanding, pending.id == replyTo else {
            throw LoomError.protocolViolation("reply_to \(replyTo) answers no outstanding command")
        }
        outstanding = nil
        pending.reply.resume(returning: frame)
    }

    private func handlePush(_ frame: EventEnvelope) {
        switch frame.event {
        case "committed":
            // A notice is a hint to reconcile, idempotent and order-free.
            refreshInterval = Self.idleRefresh
            if (frame.seq ?? .max) >= nextSeq { dirty = true }
        case "input_queue_changed", "stream_delta":
            refreshInterval = Self.idleRefresh
            if frame.event == "input_queue_changed" { dirty = true }
        default:
            break
        }
        continuation.yield(.push(frame))
    }

    /// Reconciles soon after a notice and on an idle cadence regardless, since
    /// the refresh is what makes a lost notice harmless (protocol section 6.3).
    private func refreshLoop() async {
        var sinceRefresh: Duration = .zero
        let tick: Duration = .milliseconds(100)
        while !closed {
            try? await Task.sleep(for: tick)
            sinceRefresh += tick
            guard dirty || sinceRefresh >= refreshInterval else { continue }
            dirty = false
            sinceRefresh = .zero
            do {
                let cut = try await transfer(cmd: "catch_up", body: ["from_seq": .int(Int64(nextSeq))])
                if cut.entries.isEmpty {
                    refreshInterval = min(refreshInterval * 2, Self.restingRefresh)
                } else {
                    refreshInterval = Self.idleRefresh
                }
            } catch let error as LoomError {
                // A server refusal leaves the socket healthy, and the next tick
                // retries. Every other failure has already ended the lane.
                if case .server = error { continue }
                finish(error)
            } catch {
                finish(.closed(error.localizedDescription))
            }
        }
    }

    private func finish(_ error: LoomError?) {
        guard !closed else { return }
        closed = true
        refreshTask?.cancel()
        readerTask?.cancel()
        socket.close()
        if let pending = outstanding {
            outstanding = nil
            pending.reply.resume(throwing: error ?? LoomError.closed("the lane has ended"))
        }
        continuation.yield(.closed(error))
        continuation.finish()
    }
}
