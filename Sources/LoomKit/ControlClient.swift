import Foundation

/// A client of the daemon's `/v2/control` endpoint: the catalogue and lifecycle.
public actor ControlClient {
    /// `sessions.activity` accepts at most this many ids per request.
    static let activityBatch = 24

    private let socket: any ControlTransport
    private let lock = CreditLock()
    private var nextID = 1
    public private(set) var hello: DaemonHello?

    public init(endpoint: DaemonEndpoint) throws {
        socket = WebSocket(url: try endpoint.url(path: "/v2/control"), bearer: endpoint.token)
    }

    /// A client over any transport, for a test that stands in for the daemon.
    init(transport: any ControlTransport) {
        socket = transport
    }

    /// How long a reply may take before its outcome is called unknown. Most commands
    /// answer at once. `sessions.review` runs Git in the session's sandbox and the
    /// protocol lets it wait up to 14 seconds (section 3.35), so its deadline is longer
    /// than that, or a slow read would be reported lost and would close the socket.
    static func deadline(for command: String) -> Double {
        command == "sessions.review" ? 16 : 6
    }

    /// Reads the `hello` every other command depends on for the epoch.
    @discardableResult
    public func connect() async throws -> DaemonHello {
        let socket = self.socket
        let text = try await withDeadline(seconds: 6, command: "hello") { try await socket.receive() }
        let frame = try EventEnvelope.decode(text)
        guard frame.event == "hello", let epoch = frame.body["epoch"]?.string else {
            throw LoomError.protocolViolation("the control socket did not open with hello")
        }
        let hello = DaemonHello(
            epoch: epoch,
            principal: frame.body["principal"]?.string ?? "",
            buildVersion: frame.body["build_version"]?.string ?? "",
            buildCommit: frame.body["build_commit"]?.string ?? ""
        )
        self.hello = hello
        return hello
    }

    public func close() {
        socket.close()
    }

    public func status() async throws -> DaemonStatus {
        DaemonStatus(try await request("status", body: .object([:])))
    }

    /// Walks every page of the catalogue, dropping moved-away tombstones.
    public func listSessions() async throws -> [SessionRecord] {
        var after = ""
        var records: [SessionRecord] = []
        while true {
            let page = try await request("sessions.list", body: ["after": .string(after)])
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
            ])
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

    /// One command, one correlated reply. The control socket pushes nothing
    /// after `hello`, so a read here can only be this command's answer.
    ///
    /// The exchange runs in a task of its own, so cancelling the caller (a view whose
    /// task was restarted, a sheet that was dismissed) never reaches the socket. A
    /// cancelled exchange would otherwise close the shared connection, which fails every
    /// other read in flight and reconnects the daemon. The reply is still consumed in
    /// order, and the caller that was cancelled simply does not use it.
    func request(_ cmd: String, body: JSONValue) async throws -> JSONValue {
        let frame = try await Task { [self] in
            try await lock.withCredit { [self] in
                try await exchange(cmd, body: body)
            }
        }.value
        guard frame.event != "error" else {
            throw LoomError.server(
                code: frame.body["code"]?.string ?? "unknown",
                message: frame.body["message"]?.string ?? "",
                details: frame.body["details"]
            )
        }
        return frame.body
    }

    private func exchange(_ cmd: String, body: JSONValue) async throws -> EventEnvelope {
        let id = nextID
        nextID += 1
        let socket = self.socket
        do {
            try await socket.send(try encodeCommand(id: id, cmd: cmd, body: body))
            let text = try await withDeadline(seconds: Self.deadline(for: cmd), command: cmd) { try await socket.receive() }
            let frame = try EventEnvelope.decode(text)
            guard frame.replyTo == id else {
                throw LoomError.protocolViolation("reply_to \(frame.replyTo ?? -1) answers no outstanding command")
            }
            return frame
        } catch {
            // A late reply would otherwise be read as the answer to the next
            // command, so a socket whose order is in doubt is not used again.
            socket.close()
            throw error
        }
    }
}
