import XCTest
@testable import LoomKit
import LoomShell

/// The shell around the pure lane: it must carry out what the lane decides and no
/// more. The rules themselves are checked in `LoomCoreTests`; these tests prove the
/// wiring (writes in order, callers resumed with the right outcome).
final class SessionLaneShellTests: XCTestCase {
    /// A daemon that answers each command through `script` and can drop the connection.
    private final class ScriptedDaemon: ControlTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var inbound: [String] = []
        private var waiting: CheckedContinuation<String, Error>?
        private var isClosed = false
        private(set) var commands: [String] = []
        /// What to write back for one command: nil answers nothing, which loses the reply.
        var script: @Sendable (Int, String, JSONValue) -> [String]? = { _, _, _ in nil }
        var dropAfterPrompt = false

        func send(_ text: String) async throws {
            guard let command = ScriptedDaemon.decode(text) else { return }
            lock.withLock { commands.append(command.1) }
            if command.1 == "prompt", dropAfterPrompt {
                deliverClose()
                return
            }
            for frame in script(command.0, command.1, command.2) ?? [] { deliver(frame) }
        }

        func receive() async throws -> String {
            try await withCheckedThrowingContinuation { resume in
                lock.lock()
                if !inbound.isEmpty {
                    let next = inbound.removeFirst()
                    lock.unlock()
                    resume.resume(returning: next)
                } else if isClosed {
                    lock.unlock()
                    resume.resume(throwing: LoomError.closed("the daemon went away"))
                } else {
                    waiting = resume
                    lock.unlock()
                }
            }
        }

        func close() { deliverClose() }

        private func deliver(_ frame: String) {
            lock.lock()
            if let resume = waiting {
                waiting = nil
                lock.unlock()
                resume.resume(returning: frame)
            } else {
                inbound.append(frame)
                lock.unlock()
            }
        }

        private func deliverClose() {
            lock.lock()
            isClosed = true
            let resume = waiting
            waiting = nil
            lock.unlock()
            resume?.resume(throwing: LoomError.closed("the daemon went away"))
        }

        static func decode(_ text: String) -> (Int, String, JSONValue)? {
            guard let value = try? JSONValue.parse(Data(text.utf8)), let id = value["id"]?.int, let cmd = value["cmd"]?.string else { return nil }
            return (id, cmd, value["body"] ?? .object([:]))
        }
    }

    private static func frame(_ replyTo: Int?, _ event: String, _ body: JSONValue) -> String {
        var fields: [String: JSONValue] = ["v": 2, "event": .string(event), "body": body]
        if let replyTo { fields["reply_to"] = .int(Int64(replyTo)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(JSONValue.object(fields))) ?? Data(), as: UTF8.self)
    }

    /// Answers a subscribe with an empty cut, one frame per credit, and a prompt with `admitted`.
    private static func honest(_ daemon: ScriptedDaemon) {
        daemon.script = { id, cmd, body in
            switch cmd {
            case "subscribe", "catch_up":
                return [frame(id, "snapshot_begin", [
                    "snapshot_id": .string("t\(id)"), "next_seq": 1, "window": "recent", "session_id": "s1", "epoch": "e1",
                    "incarnation": "i1", "connection_id": "c1", "role": "owner", "complete_history": .bool(false),
                    "fragment_bytes_limit": 24576, "record_bytes_limit": 33_554_432,
                ])]
            case "snapshot_next":
                let snapshot = body["snapshot_id"]?.string ?? ""
                if body["index"]?.int == 0 {
                    let data = Data(#"{"cells":[]}"#.utf8)
                    return [frame(id, "snapshot_chunk", [
                        "snapshot_id": .string(snapshot), "index": 0, "record_id": "m", "kind": "metadata",
                        "total_bytes": .int(Int64(data.count)), "offset": 0, "data": .string(data.base64EncodedString()),
                    ])]
                }
                return [frame(id, "snapshot_end", ["snapshot_id": .string(snapshot), "next_seq": 1])]
            case "prompt":
                return [frame(id, "ack", ["status": "admitted"])]
            default:
                return nil
            }
        }
    }

    func testStartCompletesTheFirstTransferAndACommandReturnsItsStatus() async throws {
        let daemon = ScriptedDaemon()
        Self.honest(daemon)
        let lane = SessionLane(sessionID: "s1", transport: daemon)
        try await lane.start()
        let status = try await lane.prompt(strand: "main", text: "hello")
        XCTAssertEqual(status, "admitted")
        XCTAssertEqual(Array(daemon.commands.prefix(4)), ["subscribe", "snapshot_next", "snapshot_next", "prompt"], "writes keep the order the lane decided")
        await lane.close()
    }

    func testALostConnectionAfterAPromptIsAnUnknownOutcomeNotARefusal() async throws {
        let daemon = ScriptedDaemon()
        Self.honest(daemon)
        daemon.dropAfterPrompt = true
        let lane = SessionLane(sessionID: "s1", transport: daemon)
        try await lane.start()
        do {
            _ = try await lane.prompt(strand: "main", text: "hello")
            XCTFail("the prompt had no reply")
        } catch LoomError.outcomeUnknown(let command) {
            XCTAssertEqual(command, "prompt")
        } catch {
            XCTFail("a lost reply must be reported as unknown, got \(error)")
        }
        XCTAssertEqual(daemon.commands.filter { $0 == "prompt" }.count, 1, "never resent")
    }

    func testAFailedSubscribeEndsStartWithTheReason() async {
        let daemon = ScriptedDaemon()
        daemon.script = { id, _, _ in [Self.frame(id, "error", ["code": "unauthorized", "message": "no"])] }
        let lane = SessionLane(sessionID: "s1", transport: daemon)
        do {
            try await lane.start()
            XCTFail("the subscribe was refused")
        } catch LoomError.server(let code, _, _) {
            XCTAssertEqual(code, "unauthorized")
        } catch {
            XCTFail("\(error)")
        }
    }
}
