import Foundation
import LoomKit
import LoomShell

// A headless driver over LoomKit. It proves the protocol core against a real
// daemon without a window, and its raw dump is how decoders get checked against
// what the daemon actually sends rather than what a document says it sends.
//
//   loom-probe list  <state-root>
//   loom-probe deployment <state-root>
//   loom-probe raw <state-root> <command> [json body]
//   loom-probe drive <state-root> <workspace> <config> <prompt>...
//   loom-probe record <state-root> <workspace> <config> <trace.jsonl> <step>...
//
// `record` writes every frame the session lane sends and receives, one JSON object per line
// (`d` is `tx` or `rx`, `t` the milliseconds since the first frame, `f` the frame text), so a
// real session becomes a trace the simulation can replay. A step is a prompt, or
// `prompt|abort=SECONDS` to stop the turn that long after sending it.

func stderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Prints each lane event until `stop` says the run is finished.
func pump(_ lane: SessionLane, verbose: Bool, stop: @escaping @Sendable (EventEnvelope?, Cut?) -> Bool) async {
    for await event in lane.events {
        switch event {
        case .cut(let cut):
            if verbose || !cut.entries.isEmpty {
                print("CUT window=\(cut.window) next=\(cut.nextSeq) entries=\(cut.entries.count)")
                for entry in cut.entries { print("  ENTRY \(entry.compactText.prefix(600))") }
                for cell in cut.metadata["cells"]?.array ?? [] {
                    print("  CELL \(cell.compactText.prefix(500))")
                }
            }
            if stop(nil, cut) { return }
        case .push(let frame):
            print("PUSH \(frame.event) seq=\(frame.seq ?? -1) \(frame.body.compactText.prefix(frame.event == "snapshot" ? 20000 : 300))")
            if stop(frame, nil) { return }
        case .closed(let error):
            print("CLOSED \(error?.localizedDescription ?? "by request")")
            return
        }
    }
}

/// Writes each frame of a lane's transport to a trace file as it passes.
final class RecordingTransport: ControlTransport, @unchecked Sendable {
    private let inner: any ControlTransport
    private let lock = NSLock()
    private let handle: FileHandle
    private var started: ContinuousClock.Instant?

    init(_ inner: any ControlTransport, path: String) throws {
        self.inner = inner
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    private func record(_ direction: String, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        let origin = started ?? now
        started = origin
        let elapsed = origin.duration(to: now).components
        let millis = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        let line: JSONValue = ["d": .string(direction), "t": .int(Int64(millis)), "f": .string(text)]
        handle.write(Data((line.compactText + "\n").utf8))
    }

    func send(_ text: String) async throws {
        record("tx", text)
        try await inner.send(text)
    }

    func receive() async throws -> String {
        let text = try await inner.receive()
        record("rx", text)
        return text
    }

    func close() {
        inner.close()
        try? handle.close()
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard arguments.count >= 2 else {
    stderr("usage: loom-probe list|drive <state-root> ...")
    exit(2)
}
let root = URL(fileURLWithPath: arguments[1])

do {
    let endpoint = try DaemonDiscovery.discover(root: root)
    let control = try ControlClient(endpoint: endpoint)
    let hello = try await control.connect()
    print("HELLO epoch=\(hello.epoch) version=\(hello.buildVersion) commit=\(hello.buildCommit)")
    print("STATUS \(try await control.status())")

    switch arguments[0] {
    case "list":
        let sessions = try await control.listSessions()
        let resident = sessions.filter { $0.state.isResident }.map(\.id)
        let activity = try await control.activity(sessions: resident)
        print("SESSIONS total=\(sessions.count) resident=\(resident.count) answered=\(activity.count)")
        for session in sessions.prefix(10) {
            print("  \(session.id) [\(session.state.label)] \(session.title.prefix(40)) \(activity[session.id]?.state.rawValue ?? "-")")
        }

    case "raw":
        // `raw <state-root> <command> [json body]`: prints the reply as the daemon sent it.
        let text = arguments.count > 3 ? arguments[3] : "{}"
        let body = try JSONValue.parse(Data(text.utf8))
        print(try await control.raw(arguments[2], body: body).compactText)

    case "deployment":
        // Read-only, and safe against a live daemon.
        let deployment = try await control.deployment()
        print("DEPLOYMENT \(deployment.selfName) state=\(deployment.state) distributed=\(deployment.isDistributed) omitted=\(deployment.omitted)")
        for node in deployment.nodes {
            print("  NODE \(node.name) \(node.roles) \(node.state) \(node.reasons) build=\(node.buildVersion ?? "-") platform=\(node.platform ?? "-") enforcement=\(node.enforcement ?? "-") scopes=\(node.openScopes.map(String.init) ?? "-")/\(node.scopeLimit.map(String.init) ?? "-") resident=\(node.resident.map(String.init) ?? "-")/\(node.capacity.map(String.init) ?? "-")")
        }
        for option in deployment.executors + deployment.pools {
            print("  OPTION \(option.choice) \(option.state) free=\(option.freeScopes.map(String.init) ?? "-") platform=\(option.platform ?? "-")")
        }
        for group in try await control.sessionsElsewhere() {
            print("  ELSEWHERE \(group.name) answered=\(group.answered) address=\(group.address != nil) sessions=\(group.sessions.count) more=\(group.hasMore)")
        }
        let sessions = try await control.listSessions()
        let placed = sessions.filter { $0.executor != nil || $0.pool != nil }
        print("  PLACED \(placed.count) of \(sessions.count)")
        for session in placed.prefix(5) {
            print("    \(session.id) \(session.state.label) executor=\(session.executor ?? "-") pool=\(session.pool ?? "-")")
        }

    case "drive":
        let record = try await control.createSession(
            requestKey: UUID().uuidString,
            workspace: arguments[2],
            name: "probe",
            configuration: arguments[3]
        )
        print("CREATED \(record.id) \(record.state.label)")
        print("OPENED \(try await control.openUntilResident(sessionID: record.id))")
        let lane = try SessionLane(endpoint: endpoint, sessionID: record.id)
        try await lane.start()

        let prompts = Array(arguments[4...])
        let reader = Task { await pump(lane, verbose: true) { _, _ in false } }
        for text in prompts {
            print("PROMPT \(try await lane.prompt(strand: "main", text: text))")
            try await Task.sleep(for: .seconds(4))
            print("ACTIVITY \(String(describing: try await control.activity(sessions: [record.id])[record.id]))")
        }
        try await lane.requestWorktreeDiff()
        try await Task.sleep(for: .seconds(2))
        await lane.close()
        await reader.value

    case "record":
        let record = try await control.createSession(
            requestKey: UUID().uuidString,
            workspace: arguments[2],
            name: "trace",
            configuration: arguments[3]
        )
        print("CREATED \(record.id)")
        _ = try await control.openUntilResident(sessionID: record.id)
        let transport = try RecordingTransport(
            WebSocket(url: try endpoint.url(path: "/v2/sessions/\(record.id)/ws"), bearer: endpoint.token),
            path: arguments[4]
        )
        let lane = SessionLane(sessionID: record.id, transport: transport)
        try await lane.start()
        for step in arguments[5...] {
            let parts = step.components(separatedBy: "|abort=")
            print("PROMPT \(try await lane.prompt(strand: "main", text: parts[0]))")
            if parts.count > 1 {
                try await Task.sleep(for: .seconds(Double(parts[1]) ?? 2))
                print("ABORT \(try await lane.abort(strand: "main"))")
            }

            // The turn is over when the daemon reports the session idle again. The first second
            // is skipped, because the activity read can precede the prompt's effect.
            try await Task.sleep(for: .seconds(1))
            for _ in 0..<120 {
                let state = try await control.activity(sessions: [record.id])[record.id]?.state
                if state == .idle { break }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        try await Task.sleep(for: .seconds(1))
        await lane.close()

    case "shutdown":
        // Stops a throwaway daemon by asking it to, never against a real one.
        try await control.shutdown()
        print("SHUTDOWN asked")

    case "raw":
        // Sends one session command with a JSON body and prints the reply and every
        // push for a few seconds. This is how a new surface's real frames are read
        // before a decoder is written against them.
        //   loom-probe raw <state-root> <session-id> <command> [json-body] [seconds]
        let lane = try SessionLane(endpoint: endpoint, sessionID: arguments[2])
        try await lane.start()
        let reader = Task { await pump(lane, verbose: false) { _, _ in false } }
        let body = arguments.count > 4
            ? (try JSONValue.parse(Data(arguments[4].utf8)))
            : JSONValue.object([:])
        do {
            let reply = try await lane.request(arguments[3], body: body)
            print("REPLY \(reply.event) \(reply.body.compactText)")
        } catch {
            print("ERROR \(error.localizedDescription)")
        }
        try await Task.sleep(for: .seconds(arguments.count > 5 ? Double(arguments[5]) ?? 3 : 3))
        await lane.close()
        await reader.value

    default:
        stderr("unknown verb \(arguments[0])")
        exit(2)
    }
    await control.close()
} catch {
    stderr("FAILED: \(error.localizedDescription)")
    exit(1)
}
