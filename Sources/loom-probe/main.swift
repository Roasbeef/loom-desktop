import Foundation
import LoomKit
import SubstrateKit

// A headless driver over LoomKit. It proves the protocol core against a real
// daemon without a window, and its raw dump is how decoders get checked against
// what the daemon actually sends rather than what a document says it sends.
//
//   loom-probe list  <state-root>
//   loom-probe drive <state-root> <workspace> <config> <prompt>...

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
            print("PUSH \(frame.event) seq=\(frame.seq ?? -1) \(frame.body.compactText.prefix(300))")
            if stop(frame, nil) { return }
        case .closed(let error):
            print("CLOSED \(error?.localizedDescription ?? "by request")")
            return
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

// `loom-probe substrate <url>` prints what the hub pushes, with no daemon.
if arguments.first == "substrate", arguments.count == 2, let url = URL(string: arguments[1]) {
    let client = SubstrateClient(baseURL: url)
    print("OPERATOR \(try await client.operatorID())")
    for try await type in client.events() {
        print("EVENT \(type)")
    }
    exit(0)
}
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

    default:
        stderr("unknown verb \(arguments[0])")
        exit(2)
    }
    await control.close()
} catch {
    stderr("FAILED: \(error.localizedDescription)")
    exit(1)
}
