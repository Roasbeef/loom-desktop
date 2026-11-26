import XCTest
import LoomKit
import LoomShell

/// A control socket whose far end is a `FakeControl`, with its replies held until a test releases them.
///
/// The host reads and writes it as it would a WebSocket. `send` hands a command to the simulated daemon,
/// and the daemon's replies are delivered at once, or held, so a test can stop a poll between two of
/// its commands and change the world there.
final class FakeControlSocket: ControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var daemon: FakeControl
    private var inbound: [String] = []
    private var held: [String] = []
    private var waiting: CheckedContinuation<String, Error>?
    private var closed = false
    private(set) var commands: [String] = []
    var holding = false

    init(daemon: FakeControl) {
        self.daemon = daemon
        self.daemon.socketOpen = false
    }

    /// Runs `change` on the simulated daemon's state.
    func mutate(_ change: (inout FakeControl) -> Void) { lock.withLock { change(&daemon) } }

    func greet() {
        let hello = lock.withLock { daemon.open() }
        hello.forEach(deliver)
    }

    func send(_ text: String) async throws {
        let replies: [String] = lock.withLock {
            commands.append(Frames.decode(command: text)?.cmd ?? "?")
            return daemon.receive(command: text)
        }
        for reply in replies {
            let parked: Bool = lock.withLock {
                guard holding else { return false }
                held.append(reply)
                return true
            }
            if !parked { deliver(reply) }
        }
        lock.withLock { daemon.owed = 0 }
    }

    /// Delivers the oldest held reply.
    @discardableResult
    func releaseOne() -> Bool {
        let reply: String? = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        guard let reply else { return false }
        deliver(reply)
        return true
    }

    var heldCount: Int { lock.withLock { held.count } }

    private func deliver(_ text: String) {
        lock.lock()
        if let resume = waiting {
            waiting = nil
            lock.unlock()
            resume.resume(returning: text)
        } else {
            inbound.append(text)
            lock.unlock()
        }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { resume in
            lock.lock()
            if !inbound.isEmpty {
                let next = inbound.removeFirst()
                lock.unlock()
                resume.resume(returning: next)
            } else if closed {
                lock.unlock()
                resume.resume(throwing: LoomError.closed("closed"))
            } else {
                waiting = resume
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let resume = waiting
        waiting = nil
        lock.unlock()
        resume?.resume(throwing: LoomError.closed("closed"))
    }
}

/// The app's real `DaemonHost`, run over a fake control socket and a virtual clock. The simulation
/// drives `Daemon` itself; these tests drive the host that opens the socket, forwards frames, parks
/// callers and arms the timer, which is where the review found hangs and stale reads.
final class DaemonHostTests: XCTestCase {
    private var endpoint: DaemonEndpoint { DaemonEndpoint(host: "127.0.0.1", port: 1, token: "t") }

    private func seeded() -> FakeControl {
        var fake = FakeControl()
        for index in 1...3 { fake.sessions.append(.init(id: "s\(index)", resident: true, approvals: 0, createdAt: index)) }
        return fake
    }

    /// Collects what the host publishes.
    actor Log {
        var outputs: [DaemonHost.Output] = []
        func add(_ output: DaemonHost.Output) { outputs.append(output) }
        var sessionIDs: [String] {
            for case .catalogue(let snapshot) in outputs.reversed() { return snapshot.sessions.map(\.id).sorted() }
            return []
        }
        var catalogues: Int { outputs.filter { if case .catalogue = $0 { return true }; return false }.count }
        var connected: Bool { outputs.contains { if case .state(.connected) = $0 { return true }; return false } }
    }

    private func start(_ socket: FakeControlSocket, clock: VirtualClock) async -> (DaemonHost, Log) {
        let host = DaemonHost(clock: clock.clock) { [endpoint] in
            socket.greet()
            return (endpoint, socket)
        }
        let log = Log()
        Task { for await output in host.outputs { await log.add(output) } }
        await host.start()
        await clock.settle()
        return (host, log)
    }

    func testTheHostConnectsPollsAndPublishesTheCatalogue() async {
        let clock = VirtualClock()
        let socket = FakeControlSocket(daemon: seeded())
        let (host, log) = await start(socket, clock: clock)
        let connected = await log.connected
        let sessions = await log.sessionIDs
        XCTAssertTrue(connected)
        XCTAssertEqual(sessions, ["s1", "s2", "s3"])
        let first = await log.catalogues
        await clock.advance(by: 2_000)
        let second = await log.catalogues
        XCTAssertGreaterThan(second, first, "the next poll is two seconds later, on the virtual clock")
        await host.stop()
    }

    /// Review finding: after `stop`, a call queued on a lane nobody would ever tick, and never returned.
    func testCallsAfterStopReturnInsteadOfHanging() async {
        let clock = VirtualClock()
        let socket = FakeControlSocket(daemon: seeded())
        let (host, _) = await start(socket, clock: clock)
        await host.stop()
        let outcome = await Self.withinTwoSeconds {
            do {
                _ = try await host.request("sessions.create", body: .object([:]), priority: .owner)
                return "returned a reply"
            } catch { return "threw" }
        }
        XCTAssertEqual(outcome, "threw")
        let refresh = await Self.withinTwoSeconds {
            do { try await host.refreshNow(); return "returned" } catch { return "threw" }
        }
        XCTAssertEqual(refresh, "threw")
    }

    /// Review finding: a poll already out had read the list before the caller's change, and refreshNow
    /// returned on it, so the caller saw a catalogue that lacked what it had just made.
    func testRefreshNowDuringAPollWaitsForAPollThatStartsAfterTheChange() async {
        let clock = VirtualClock()
        let socket = FakeControlSocket(daemon: seeded())
        let (host, log) = await start(socket, clock: clock)
        socket.holding = true

        // A poll starts, and is held after its list reply.
        await clock.advance(by: 2_000)
        for _ in 0..<2 { socket.releaseOne(); await clock.settle() }
        XCTAssertGreaterThan(socket.heldCount, 0, "the poll is between its list and its activity")

        // The caller makes a change and asks for the catalogue.
        socket.mutate { $0.sessions.append(.init(id: "s4", resident: true, approvals: 0, createdAt: 4)) }
        let done = Task { () -> Bool in
            do { try await host.refreshNow(); return true } catch { return false }
        }
        await clock.settle()

        // The poll that was out finishes, and its catalogue does not hold the change.
        socket.releaseOne()
        await clock.settle()
        let stale = await log.sessionIDs
        XCTAssertEqual(stale, ["s1", "s2", "s3"], "that poll listed the sessions before s4 existed")
        socket.holding = false
        while socket.releaseOne() { await clock.settle() }
        await clock.advance(by: 10)
        let landed = await done.value
        XCTAssertTrue(landed)
        let fresh = await log.sessionIDs
        XCTAssertEqual(fresh, ["s1", "s2", "s3", "s4"], "refreshNow returned on a poll that started after the change")
        await host.stop()
    }

    /// Review finding: a refused poll command ended the connection and left an owner command behind it
    /// waiting for ever.
    func testAnOwnerCommandBehindARefusedPollIsSettled() async {
        let clock = VirtualClock()
        let socket = FakeControlSocket(daemon: seeded())
        let (host, _) = await start(socket, clock: clock)
        socket.mutate { $0.refusePolls = true }
        await clock.advance(by: 2_000)
        let outcome = await Self.withinTwoSeconds {
            do {
                _ = try await host.request("sessions.create", body: ["request_key": "k"], priority: .owner)
                return "reply"
            } catch { return "settled" }
        }
        XCTAssertEqual(outcome, "settled")
        await host.stop()
    }

    /// Runs `work` and gives up after two real seconds, so a hang is a failure and not a stuck test.
    static func withinTwoSeconds(_ work: @escaping @Sendable () async -> String) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return "HUNG"
            }
            let first = await group.next() ?? "HUNG"
            group.cancelAll()
            return first
        }
    }
}
