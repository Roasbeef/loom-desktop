import Foundation

/// A client of the daemon's `/v2/control` endpoint: the catalogue and lifecycle.
public actor ControlClient {
    /// `sessions.activity` accepts at most this many ids per request.
    static let activityBatch = 24

    private let socket: WebSocket
    private let lock = CreditLock()
    private var nextID = 1
    public private(set) var hello: DaemonHello?

    public init(endpoint: DaemonEndpoint) throws {
        socket = WebSocket(url: try endpoint.url(path: "/v2/control"), bearer: endpoint.token)
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
        configuration: String
    ) async throws -> SessionRecord {
        let body = try await request("sessions.create", body: [
            "request_key": .string(requestKey),
            "workspace": .string(workspace),
            "name": .string(name),
            "configuration": .string(configuration),
        ])
        guard let record = SessionRecord(body) else {
            throw LoomError.protocolViolation("sessions.create returned no record")
        }
        return record
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

    private func currentEpoch() throws -> String {
        guard let epoch = hello?.epoch else {
            throw LoomError.protocolViolation("a command preceded hello")
        }
        return epoch
    }

    /// One command, one correlated reply. The control socket pushes nothing
    /// after `hello`, so a read here can only be this command's answer.
    private func request(_ cmd: String, body: JSONValue) async throws -> JSONValue {
        await lock.acquire()
        do {
            let id = nextID
            nextID += 1
            let socket = self.socket
            try await socket.send(try encodeCommand(id: id, cmd: cmd, body: body))
            let text = try await withDeadline(seconds: 6, command: cmd) { try await socket.receive() }
            await lock.release()

            let frame = try EventEnvelope.decode(text)
            guard frame.replyTo == id else {
                throw LoomError.protocolViolation("reply_to \(frame.replyTo ?? -1) answers no outstanding command")
            }
            if frame.event == "error" {
                throw LoomError.server(
                    code: frame.body["code"]?.string ?? "unknown",
                    message: frame.body["message"]?.string ?? "",
                    details: frame.body["details"]
                )
            }
            return frame.body
        } catch let error as LoomError {
            if case .server = error { throw error }
            if case .protocolViolation = error { socket.close(); throw error }
            await lock.release()
            throw error
        }
    }
}
