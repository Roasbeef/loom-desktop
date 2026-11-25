import Foundation

/// A client of the daemon's `/v2/control` endpoint: the catalogue and lifecycle.
///
/// This actor is the shell around `ControlLane`. The lane decides: which command is on the
/// wire, which waits, when a reply is overdue. The actor forwards frames to it with a
/// clock reading, writes its outputs in order, arms one timer for its next deadline, and
/// resumes the caller a settled ticket names.
///
/// Commands carry a priority. A person's action (create, stop, answer) is `owner`, and the
/// poll and other background reads are `background`. The lane writes the oldest owner
/// command before any background one, so an action waits behind at most the read already on
/// the wire and never behind reads that queued after it began. Before, one FIFO credit made
/// a created session wait behind a `sessions.review` of up to 16 s and the polls queued
/// after it (audit finding H6).
public actor ControlClient {
    /// `sessions.activity` accepts at most this many ids per request.
    static let activityBatch = 24

    private let transport: any ControlTransport
    private var core: ControlLane
    private let writes: AsyncStream<String>.Continuation
    private let writeQueue: AsyncStream<String>
    private let origin = ContinuousClock.now
    private var waiters: [ControlLane.Ticket: CheckedContinuation<JSONValue, Error>] = [:]
    private var helloWaiter: CheckedContinuation<DaemonHello, Error>?
    private var ended: LoomError?
    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    public private(set) var hello: DaemonHello?

    public init(endpoint: DaemonEndpoint) throws {
        self.init(transport: WebSocket(url: try endpoint.url(path: "/v2/control"), bearer: endpoint.token))
    }

    /// A client over any transport, for a test that stands in for the daemon.
    public init(transport: any ControlTransport) {
        self.transport = transport
        core = ControlLane(now: 0)
        (writeQueue, writes) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }

    /// How long a reply may take before its outcome is called unknown. Most commands
    /// answer at once. `sessions.review` runs Git in the session's sandbox and the
    /// protocol lets it wait up to 14 seconds (section 3.35), so its deadline is longer
    /// than that, or a slow read would be reported lost and would close the socket.
    static func deadline(for command: String) -> Double {
        Double(ControlLane.deadlineMs(for: command)) / 1000
    }

    /// Starts reading and writing, and waits for the `hello` every other command depends
    /// on for the epoch. The lane gives the daemon six seconds to send it.
    @discardableResult
    public func connect() async throws -> DaemonHello {
        if let hello { return hello }
        startIfNeeded()
        return try await withCheckedThrowingContinuation { resume in
            if let ended {
                resume.resume(throwing: ended)
            } else if let hello {
                resume.resume(returning: hello)
            } else {
                helloWaiter = resume
            }
        }
    }

    public func close() {
        apply { $0.close() }
    }

    /// Starts the reader and the writer once, so a command sent before `connect` still
    /// finds the `hello` it waits for.
    private func startIfNeeded() {
        guard readerTask == nil else { return }
        readerTask = Task { await self.readLoop() }
        writerTask = Task { await self.writeLoop() }
        arm()
    }

    public func status() async throws -> DaemonStatus {
        DaemonStatus(try await request("status", body: .object([:]), priority: .background))
    }

    /// Walks every page of the catalogue, dropping moved-away tombstones.
    public func listSessions() async throws -> [SessionRecord] {
        var after = ""
        var records: [SessionRecord] = []
        while true {
            let page = try await request("sessions.list", body: ["after": .string(after)], priority: .background)
            let rows = page["sessions"]?.array ?? []
            records += rows.compactMap(SessionRecord.init).filter { !$0.hasMoved }
            guard !rows.isEmpty, let next = page["after"]?.string else { return records }
            after = next
        }
    }

    /// Reads activity for `sessions`, batching at the server's per-request bound.
    ///
    /// The server pushes no activity, so the caller polls. A session absent
    /// from the result is inactive.
    public func activity(sessions: [String]) async throws -> [String: SessionActivity] {
        let epoch = try currentEpoch()
        var result: [String: SessionActivity] = [:]
        for start in stride(from: 0, to: sessions.count, by: Self.activityBatch) {
            let batch = sessions[start..<min(start + Self.activityBatch, sessions.count)]
            let body = try await request("sessions.activity", body: [
                "sessions": .array(batch.map { .string($0) }),
                "epoch": .string(epoch),
            ], priority: .background)
            for row in (body["activity"]?.array ?? []).compactMap(SessionActivity.init) {
                result[row.sessionID] = row
            }
        }
        return result
    }

    /// Creates a session. `requestKey` is durable, so a retry with the same key
    /// recovers the original identity instead of creating a second session.
    public func createSession(
        requestKey: String,
        workspace: String,
        name: String,
        configuration: String,
        placement: PlacementChoice = .local,
        options: CreationOptions = CreationOptions()
    ) async throws -> SessionRecord {
        var fields: [String: JSONValue] = [
            "request_key": .string(requestKey),
            "workspace": .string(workspace),
            "name": .string(name),
            "configuration": .string(configuration),
        ]

        // With either of these, `workspace` is a name registered on that machine
        // rather than a path on this one.
        switch placement {
        case .local: break
        case .executor(let name): fields["executor"] = .string(name)
        case .pool(let name): fields["pool"] = .string(name)
        }
        options.add(to: &fields)
        let body = try await request("sessions.create", body: .object(fields))
        guard let record = SessionRecord(body) else {
            throw LoomError.protocolViolation("sessions.create returned no record")
        }

        // An older daemon ignores the `worktree` key and starts the session in the
        // folder, so the reply's own `worktree` member is the only confirmation.
        if options.worktree != nil, record.worktree == nil {
            throw WorktreeNotHonoured(sessionID: record.id)
        }
        return record
    }

    /// The models and profiles a configuration defines, and which models read
    /// images (`models.list`). A daemon that predates the command answers
    /// `unsupported`, which the caller turns into a fallback.
    public func listModels(configuration: String) async throws -> ModelCatalogue {
        let body = try await request("models.list", body: ["configuration": .string(configuration)])
        guard let catalogue = ModelCatalogue(reply: body) else {
            throw LoomError.protocolViolation("models.list returned no catalogue")
        }
        return catalogue
    }

    /// Opens a saved session and waits until it is resident, which a session
    /// upgrade requires (protocol section 3.8).
    public func openUntilResident(sessionID: String, timeout: Duration = .seconds(60)) async throws -> SessionState {
        let epoch = try currentEpoch()
        let opened = try await request("sessions.open", body: [
            "session_id": .string(sessionID),
            "epoch": .string(epoch),
        ])
        var state = SessionState(opened)
        let deadline = ContinuousClock.now + timeout
        while case .opening(let operation) = state {
            guard ContinuousClock.now < deadline else {
                throw LoomError.closed("The session did not open within \(timeout).")
            }
            try await Task.sleep(for: .milliseconds(150))
            let body = try await request("operations.get", body: [
                "session_id": .string(sessionID),
                "operation": .string(operation),
                "epoch": .string(epoch),
            ])
            state = SessionState(body["status"])
        }
        return state
    }

    public func stopSession(sessionID: String) async throws {
        _ = try await request("sessions.stop", body: [
            "session_id": .string(sessionID),
            "epoch": .string(try currentEpoch()),
        ])
    }

    /// Asks the daemon to drain and exit. It is the owner's alone, and the harness
    /// uses it to stop throwaway daemons without signalling a process.
    public func shutdown() async throws {
        _ = try await request("daemon.shutdown", body: ["epoch": .string(try currentEpoch())])
    }

    /// Reads the deployment: every machine this daemon is configured with, and
    /// where a session may be placed. `node` narrows it to one key and adds that
    /// node's long lists. Every statement is as seen from this daemon.
    public func deployment(node: String? = nil) async throws -> Deployment {
        Deployment(try await request("deployment.status", body: node.map { ["node": .string($0)] } ?? .object([:])))
    }

    /// Lists the sessions this daemon's other orchestrators hold. A `silent`
    /// group is never the same as a group with no sessions.
    public func sessionsElsewhere() async throws -> [ElsewhereGroup] {
        let body = try await request("sessions.elsewhere", body: .object([:]))
        return (body["orchestrators"]?.array ?? []).map(ElsewhereGroup.init)
    }

    /// Lists the projects this daemon runs, for the folder picker. A daemon that
    /// predates project mode refuses the command, which reads as no projects.
    public func listProjects() async throws -> [ProjectRef] {
        let body = try await request("projects.list", body: .object([:]))
        return (body["projects"]?.array ?? []).compactMap(ProjectRef.init)
    }

    /// One command with its body and reply left undecoded, for `loom-probe raw`.
    /// It is how a decoder is checked against what the daemon really sends.
    public func raw(_ cmd: String, body: JSONValue) async throws -> JSONValue {
        try await request(cmd, body: body)
    }

    func currentEpoch() throws -> String {
        guard let epoch = hello?.epoch else {
            throw LoomError.protocolViolation("a command preceded hello")
        }
        return epoch
    }

    /// One command, one correlated reply. The control socket pushes nothing after
    /// `hello`, so a frame here can only be this command's answer.
    ///
    /// The caller's cancellation never reaches the socket: the lane consumes the reply in
    /// order whether or not the caller is still waiting. A cancelled exchange would
    /// otherwise close the shared connection, which fails every other read in flight.
    func request(_ cmd: String, body: JSONValue, priority: ControlLane.Priority = .owner) async throws -> JSONValue {
        startIfNeeded()
        return try await withCheckedThrowingContinuation { resume in
            let admitted = core.submit(ControlLane.Command(cmd, body: body, priority: priority), now: now())
            waiters[admitted.ticket] = resume
            handle(admitted.updates)
        }
    }

    // MARK: The bridge to the lane

    private func apply(_ transition: (inout ControlLane) -> [ControlLane.Update]) {
        handle(transition(&core))
    }

    private func handle(_ updates: [ControlLane.Update]) {
        for output in core.takeOutputs() {
            switch output {
            case .transmit(let text): writes.yield(text)
            case .shut: writes.finish()
            }
        }
        for update in updates { route(update) }
        arm()
    }

    private func route(_ update: ControlLane.Update) {
        switch update {
        case .hello(let epoch, let body):
            let greeting = DaemonHello(
                epoch: epoch,
                principal: body["principal"]?.string ?? "",
                buildVersion: body["build_version"]?.string ?? "",
                buildCommit: body["build_commit"]?.string ?? ""
            )
            hello = greeting
            helloWaiter?.resume(returning: greeting)
            helloWaiter = nil
        case .replied(let ticket, let body):
            waiters.removeValue(forKey: ticket)?.resume(returning: body)
        case .refused(let ticket, let code, let message, let details):
            waiters.removeValue(forKey: ticket)?.resume(throwing: LoomError.server(code: code, message: message, details: details))
        case .lost(let ticket, let command):
            waiters.removeValue(forKey: ticket)?.resume(throwing: LoomError.outcomeUnknown(command: command))
        case .failed(let ticket, let error):
            waiters.removeValue(forKey: ticket)?.resume(throwing: error)
        case .closed(let error):
            ended = error ?? .closed("the control connection has ended")
            readerTask?.cancel()
            timer?.cancel()
            transport.close()
            helloWaiter?.resume(throwing: ended ?? .closed("the control connection has ended"))
            helloWaiter = nil
        }
    }

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

    private func now() -> Int {
        let elapsed = ContinuousClock.now - origin
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
