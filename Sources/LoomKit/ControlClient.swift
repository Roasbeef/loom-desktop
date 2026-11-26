import Foundation

/// What a control client needs of the connection beneath it.
///
/// The connection is hosted by `DaemonHost`, which owns the poll as well as the commands, for
/// the app and for `loom-probe`. A test may stand in with an exchange of its own.
public protocol ControlExchange: Sendable {
    func close() async
    /// One command, one reply body. A lost reply is `outcomeUnknown`, and nothing is resent.
    func request(_ cmd: String, body: JSONValue, priority: ControlLane.Priority) async throws -> JSONValue
    /// The epoch the last `hello` named, or nil before one.
    func epoch() async -> String?
}

/// A client of the daemon's `/v2/control` endpoint: the catalogue and lifecycle.
///
/// Commands carry a priority. A person's action (create, stop, answer) is `owner`, and the
/// poll and other background reads are `background`. The lane writes the oldest owner
/// command before any background one, so an action waits behind at most the read already on
/// the wire and never behind reads that queued after it began (audit finding H6).
public final class ControlClient: Sendable {
    /// `sessions.activity` accepts at most this many ids per request.
    static let activityBatch = 24

    private let exchange: any ControlExchange

    /// A client over a connection someone else hosts.
    public init(exchange: any ControlExchange) {
        self.exchange = exchange
    }

    /// How long a reply may take before its outcome is called unknown. Most commands
    /// answer at once. `sessions.review` runs Git in the session's sandbox and the
    /// protocol lets it wait up to 14 seconds (section 3.35), so its deadline is longer
    /// than that, or a slow read would be reported lost and would close the socket.
    static func deadline(for command: String) -> Double {
        Double(ControlLane.deadlineMs(for: command)) / 1000
    }

    public func close() async {
        await exchange.close()
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
        let epoch = try await currentEpoch()
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
        let epoch = try await currentEpoch()
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
            "epoch": .string(try await currentEpoch()),
        ])
    }

    /// Asks the daemon to drain and exit. It is the owner's alone, and the harness
    /// uses it to stop throwaway daemons without signalling a process.
    public func shutdown() async throws {
        _ = try await request("daemon.shutdown", body: ["epoch": .string(try await currentEpoch())])
    }

    /// Reads the deployment: every machine this daemon is configured with, and
    /// where a session may be placed. `node` narrows it to one key and adds that
    /// node's long lists. Every statement is as seen from this daemon.
    public func deployment(node: String? = nil) async throws -> Deployment {
        Deployment(try await request("deployment.status", body: node.map { ["node": .string($0)] } ?? .object([:]), priority: .background))
    }

    /// Lists the sessions this daemon's other orchestrators hold. A `silent`
    /// group is never the same as a group with no sessions.
    public func sessionsElsewhere() async throws -> [ElsewhereGroup] {
        let body = try await request("sessions.elsewhere", body: .object([:]), priority: .background)
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

    func currentEpoch() async throws -> String {
        guard let epoch = await exchange.epoch() else {
            throw LoomError.protocolViolation("a command preceded hello")
        }
        return epoch
    }

    /// One command, one correlated reply. The control socket pushes nothing after `hello`, so a
    /// frame there can only be this command's answer. A caller's cancellation never reaches the
    /// socket: the lane consumes the reply in order whether or not the caller still waits.
    func request(_ cmd: String, body: JSONValue, priority: ControlLane.Priority = .owner) async throws -> JSONValue {
        try await exchange.request(cmd, body: body, priority: priority)
    }
}
