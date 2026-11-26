import XCTest
import LoomKit
import LoomShell

/// The shell's real sockets against a real loomd, started with its own state directory and port.
///
/// It runs only when `LOOMD_BIN` names a daemon binary (a loom checkout's `bin/loomd`), so the gate
/// needs no daemon. It never uses port 7440 or `~/.loom`, uses no provider key (the configured model
/// is never called), and stops only the process it started. It checks what the simulation cannot:
/// that `DaemonHost` and `SessionLane` complete the real handshake and transfers, and that the
/// frames the real daemon sends decode as the fake's frames do.
final class ContractTests: XCTestCase {
    private let port = 17743

    func testTheShellConnectsToARealDaemon() async throws {
        guard let binary = ProcessInfo.processInfo.environment["LOOMD_BIN"] else { throw XCTSkip("set LOOMD_BIN=<loomd>") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-contract-\(UUID().uuidString)")
        let state = root.appendingPathComponent("state")
        let home = root.appendingPathComponent("home")
        let workspace = root.appendingPathComponent("ws")
        for directory in [state, home, workspace] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let config = root.appendingPathComponent("loom.toml")
        try """
        [models.fake]
        dialect = "openai"
        base_url = "http://127.0.0.1:1/v1"
        api_key_env = "FAKE_KEY"
        model_id = "fake"
        thinking = "unsupported"
        context_window = 200000
        max_output_tokens = 4096

        [roles]
        main = ["fake"]
        """.write(to: config, atomically: true, encoding: .utf8)

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: binary)
        daemon.arguments = ["--config", config.path, "--state-dir", state.path, "--bind", "127.0.0.1:\(port)"]

        // The daemon needs the toolchain on PATH, but nothing of the operator's own daemon: HOME moves
        // its user directory and every LOOM_ variable is dropped.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("LOOM_") }
        environment["HOME"] = home.path
        environment["FAKE_KEY"] = "placeholder"
        daemon.environment = environment
        let log = root.appendingPathComponent("loomd.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        daemon.standardOutput = logHandle
        daemon.standardError = logHandle
        try daemon.run()
        defer {
            if daemon.isRunning { daemon.terminate() }
            try? FileManager.default.removeItem(at: root)
        }

        // The daemon is ready when it has published its endpoint record.
        var endpoint: DaemonEndpoint?
        for _ in 0..<100 {
            endpoint = try? DaemonDiscovery.discover(root: state)
            if endpoint != nil { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        let found = try XCTUnwrap(endpoint, "loomd published no endpoint record")

        let host = DaemonHost(open: {
            let endpoint = try DaemonDiscovery.discover(root: state)
            return (endpoint, WebSocket(url: try endpoint.url(path: "/v2/control"), bearer: endpoint.token))
        })
        await host.start()
        defer { Task { await host.stop() } }
        var connected = false
        for await output in host.outputs {
            if case .state(.connected) = output { connected = true; break }
        }
        XCTAssertTrue(connected, "the host never reached the connected state")
        let control = ControlClient(exchange: host)

        // The record can precede the listener by a moment, and the host reconnects by its own rule.
        var status: DaemonStatus?
        for _ in 0..<40 where status == nil {
            status = try? await control.status()
            if status == nil { try await Task.sleep(for: .milliseconds(500)) }
        }
        XCTAssertNotNil(status, "the daemon never answered status")
        try await host.refreshNow()

        // A session opens and its lane completes the first transfer.
        let record = try await control.createSession(requestKey: UUID().uuidString, workspace: workspace.path, name: "contract", configuration: config.path)
        _ = try await control.openUntilResident(sessionID: record.id)
        let lane = try SessionLane(endpoint: found, sessionID: record.id)
        try await lane.start()
        let reply = try await lane.read("notes", body: ["strand": "main"])
        XCTAssertEqual(reply.event, "snapshot")
        await lane.close()
    }
}
