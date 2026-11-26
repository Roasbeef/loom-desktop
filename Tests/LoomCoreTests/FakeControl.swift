import Foundation
import LoomKit

/// A simulated daemon's control half: the catalogue, the activity feed, an epoch, and the
/// control socket's rules.
///
/// It is strict where the real daemon is. The socket opens with `hello`. One command is in
/// flight at a time. A command that names a stale epoch is refused. `sessions.create`
/// recovers the original session from its `request_key` instead of making a second. A
/// `sessions.review` reply is held until the harness releases it, which is how the slow
/// read of audit finding H6 enters.
struct FakeControl: Equatable {
    struct Session: Equatable {
        let id: String
        var resident: Bool
        var approvals: Int
        let createdAt: Int
    }

    var epoch = "e1"
    var sessions: [Session] = []
    var keys: [String: String] = [:]
    var counter = 0
    var version = 0
    var isUp = true
    /// The daemon refuses the poll's commands, as a rate limit or a demoted credential would.
    var refusePolls = false
    var socketOpen = false
    var owed = 0
    var violations: [Sim.Violation] = []
    /// A review's reply, waiting for the harness to release it.
    var held: String?
    static let pageSize = 2

    mutating func open() -> [String] {
        guard isUp else { return [] }
        socketOpen = true
        owed = 0
        return [Frames.envelope(replyTo: nil, event: "hello", body: ["epoch": .string(epoch)])]
    }

    mutating func restart() {
        epoch = "e\(counter + 2)"
        counter += 1
        socketOpen = false
        held = nil
        version += 1
    }

    mutating func receive(command text: String) -> [String] {
        guard socketOpen, let command = Frames.decode(command: text) else { return [] }
        if owed > 0 { violations.append(Sim.Violation("I1", "\(command.cmd) arrived while a reply was owed")) }
        owed += 1
        let id = command.id
        let staleEpoch = command.body["epoch"]?.string.map { $0 != epoch } ?? false
        if staleEpoch { return [Frames.error(replyTo: id, code: "stale_epoch")] }
        if refusePolls, ["status", "sessions.list", "sessions.activity"].contains(command.cmd) {
            return [Frames.error(replyTo: id, code: "rate_limited", message: "too many reads")]
        }
        switch command.cmd {
        case "status":
            return [Frames.envelope(replyTo: id, event: "status", body: ["epoch": .string(epoch)])]
        case "sessions.list":
            let after = command.body["after"]?.string ?? ""
            let ordered = sessions.sorted { $0.id < $1.id }
            let rest = ordered.filter { after.isEmpty || $0.id > after }
            let page = Array(rest.prefix(Self.pageSize))
            var body: [String: JSONValue] = ["sessions": .array(page.map(record))]
            if rest.count > page.count, let last = page.last { body["after"] = .string(last.id) }
            return [Frames.envelope(replyTo: id, event: "sessions", body: .object(body))]
        case "sessions.activity":
            let wanted = Set((command.body["sessions"]?.array ?? []).compactMap(\.string))
            let rows = sessions.filter { wanted.contains($0.id) && $0.resident }.map { row -> JSONValue in
                ["session_id": .string(row.id), "state": row.approvals > 0 ? "needs_you" : "idle", "approvals": .int(Int64(row.approvals))]
            }
            return [Frames.envelope(replyTo: id, event: "activity", body: ["activity": .array(rows)])]
        case "sessions.create":
            let key = command.body["request_key"]?.string ?? ""
            let sessionID: String
            if let known = keys[key], sessions.contains(where: { $0.id == known }) {
                sessionID = known
            } else {
                counter += 1
                sessionID = "n\(counter)"
                keys[key] = sessionID
                sessions.append(Session(id: sessionID, resident: false, approvals: 0, createdAt: 1_000 + counter))
                version += 1
            }
            return [Frames.envelope(replyTo: id, event: "session", body: record(sessions.first { $0.id == sessionID }!))]
        case "sessions.review":
            held = Frames.envelope(replyTo: id, event: "review", body: ["files": []])
            return []
        default:
            return [Frames.envelope(replyTo: id, event: "ok", body: .object([:]))]
        }
    }

    /// The reply of a held review, now that the harness releases it.
    mutating func releaseReview() -> [String] {
        guard let reply = held else { return [] }
        held = nil
        return [reply]
    }

    private func record(_ session: Session) -> JSONValue {
        [
            "session_id": .string(session.id), "workspace": "/w", "name": .string(session.id),
            "created_at": .int(Int64(session.createdAt)),
            "status": session.resident ? ["state": "resident", "incarnation": "i1"] : ["state": "saved"],
        ]
    }
}
