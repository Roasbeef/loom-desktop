import Foundation
import LoomCore
import LoomKit

/// The shell around `LoomCore.Daemon`: one daemon connection, hosted.
///
/// The core decides everything about the connection: when to open it, which command is on the
/// wire, the poll saga (`status`, every page of `sessions.list`, `sessions.activity`), the
/// catalogue, which sessions need a lane, the periodic reads, and the reconnect three seconds
/// after a failure. This actor carries the decisions out. It opens the socket when the core says
/// `open`, forwards each frame and the socket's end to the core with a clock reading, writes the
/// core's frames in the order it decided them, arms one timer for `nextDue`, resumes the caller
/// each settled command names, and publishes what the app has to act on as `outputs`.
///
/// It is also the `ControlExchange` beneath the app's `ControlClient`, so every command a view
/// sends joins the same lane as the poll, with its priority, and the poll and the commands cannot
/// disagree about whose turn it is.
public actor DaemonHost: ControlExchange {
    /// What the app acts on.
    public enum Output: Sendable {
        /// The socket opened to this endpoint.
        case opened(DaemonEndpoint)
        case state(Daemon.Connection)
        /// A poll finished. The snapshot is the whole catalogue as that poll read it.
        case catalogue(Snapshot)
        case attach(session: String, inheriting: Daemon.Inheritance)
        case detachAll
        /// A periodic read is due, which the app performs as a background command.
        case due(Daemon.Periodic)
    }

    /// The catalogue at the end of one poll.
    public struct Snapshot: Sendable {
        public let status: JSONValue?
        public let hello: JSONValue?
        public let sessions: [SessionRecord]
        public let activity: [String: SessionActivity]
    }

    public nonisolated let outputs: AsyncStream<Output>

    private let outputSink: AsyncStream<Output>.Continuation
    private let open: @Sendable () throws -> (endpoint: DaemonEndpoint, transport: any ControlTransport)
    private let origin = ContinuousClock.now

    private var core = Daemon()
    private var transport: (any ControlTransport)?
    private var writes: AsyncStream<String>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var connection = 0
    private var waiters: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var refreshWaiters: [CheckedContinuation<Void, Error>] = []
    private var helloWaiters: [CheckedContinuation<DaemonHello, Error>] = []
    private var nextTag = 1
    private var stopped = false

    /// `open` resolves the daemon's address and opens a socket to it, and runs again at every
    /// reconnect, so a daemon that moved is found again from discovery.
    public init(open: @escaping @Sendable () throws -> (endpoint: DaemonEndpoint, transport: any ControlTransport)) {
        self.open = open
        (outputs, outputSink) = AsyncStream.makeStream(of: Output.self, bufferingPolicy: .unbounded)
    }

    // MARK: Lifecycle

    /// Begins connecting.
    public func start() {
        guard !stopped, readerTask == nil, transport == nil else { return }
        perform(core.start(now: now()))
    }

    /// Ends the connection for good.
    public func stop() {
        stopped = true
        timer?.cancel()
        readerTask?.cancel()
        writes?.finish()
        transport?.close()
        transport = nil
        outputSink.finish()
        let failure = LoomError.closed("the daemon connection was closed")
        for (_, waiter) in waiters { waiter.resume(throwing: failure) }
        waiters = [:]
        for waiter in refreshWaiters { waiter.resume(throwing: failure) }
        refreshWaiters = []
        for waiter in helloWaiters { waiter.resume(throwing: failure) }
        helloWaiters = []
    }

    /// A lane for this session ended, so the next poll attaches it again if it is still resident.
    public func laneEnded(_ session: String) {
        core.laneEnded(session)
    }

    /// The app attached a session on its own, for one someone opened.
    public func attached(_ session: String) {
        core.attached(session)
    }

    /// A session was stopped or removed.
    public func forget(_ session: String) {
        core.forget(session)
    }

    /// Reads the catalogue now and returns when that read has landed, for a caller that has just
    /// changed something the catalogue shows. A poll already out is waited for.
    public func refreshNow() async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            guard core.isConnected else {
                resume.resume(throwing: LoomError.closed("the daemon is not connected"))
                return
            }
            refreshWaiters.append(resume)
            perform(core.pollSoon(now: now()))
        }
    }

    // MARK: ControlExchange

    public func connect() async throws -> DaemonHello {
        if core.isConnected, let body = core.hello { return Self.greeting(body, epoch: core.epoch) }
        return try await withCheckedThrowingContinuation { helloWaiters.append($0) }
    }

    public func close() {
        stop()
    }

    public func epoch() async -> String? { core.epoch }

    public func request(_ cmd: String, body: JSONValue, priority: ControlLane.Priority) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { resume in
            let tag = nextTag
            nextTag += 1
            waiters[tag] = resume
            perform(core.submit(ControlLane.Command(cmd, body: body, priority: priority), tag: tag, now: now()))
        }
    }

    // MARK: Carrying out effects

    private func perform(_ effects: [Daemon.Effect]) {
        for effect in effects {
            switch effect {
            case .open:
                openConnection()
            case .transmit(let text):
                writes?.yield(text)
            case .shut:
                closeConnection()
            case .state(let state):
                outputSink.yield(.state(state))
                if case .unavailable = state { failRefreshes(LoomError.closed("the daemon is not connected")) }
                if case .connected = state, let body = core.hello {
                    let greeting = Self.greeting(body, epoch: core.epoch)
                    for waiter in helloWaiters { waiter.resume(returning: greeting) }
                    helloWaiters = []
                }
            case .catalogue:
                outputSink.yield(.catalogue(Snapshot(status: core.status, hello: core.hello, sessions: core.sessions, activity: core.activity)))
                for waiter in refreshWaiters { waiter.resume() }
                refreshWaiters = []
            case .attach(let session, let inheriting):
                outputSink.yield(.attach(session: session, inheriting: inheriting))
            case .detachAll:
                outputSink.yield(.detachAll)
            case .due(let periodic):
                outputSink.yield(.due(periodic))
            case .settled(let tag, let settlement):
                guard let waiter = waiters.removeValue(forKey: tag) else { continue }
                switch settlement {
                case .reply(let body): waiter.resume(returning: body)
                case .refused(let code, let message, let details): waiter.resume(throwing: LoomError.server(code: code, message: message, details: details))
                case .lost(let command): waiter.resume(throwing: LoomError.outcomeUnknown(command: command))
                case .failed(let error): waiter.resume(throwing: error)
                }
            }
        }
        arm()
    }

    private func failRefreshes(_ error: LoomError) {
        for waiter in refreshWaiters { waiter.resume(throwing: error) }
        refreshWaiters = []
    }

    /// Opens a socket when the core asks. A socket that cannot be opened is reported as the end of
    /// one, so the core schedules the retry like any other failure.
    private func openConnection() {
        closeConnection()
        connection += 1
        let generation = connection
        do {
            let opened = try open()
            transport = opened.transport
            outputSink.yield(.opened(opened.endpoint))
            let (queue, sink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
            writes = sink
            let socket = opened.transport
            writerTask = Task { [weak self] in
                for await text in queue {
                    do {
                        try await socket.send(text)
                    } catch {
                        await self?.transportFailed(error, generation: generation)
                    }
                }
            }
            readerTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let text = try await socket.receive()
                        await self?.received(text, generation: generation)
                    } catch {
                        await self?.transportFailed(error, generation: generation)
                        return
                    }
                }
            }
        } catch {
            let failure = (error as? LoomError) ?? .closed(error.localizedDescription)
            perform(core.receive(failed: failure, now: now()))
        }
    }

    private func closeConnection() {
        readerTask?.cancel()
        readerTask = nil
        writes?.finish()
        writes = nil
        transport?.close()
        transport = nil
    }

    private func received(_ text: String, generation: Int) {
        guard generation == connection, !stopped else { return }
        perform(core.receive(text, now: now()))
    }

    private func transportFailed(_ error: Error, generation: Int) {
        guard generation == connection, !stopped else { return }
        let failure = (error as? LoomError) ?? .closed(error.localizedDescription)
        perform(core.receive(failed: failure, now: now()))
    }

    // MARK: The one timer

    private func arm() {
        timer?.cancel()
        timer = nil
        guard !stopped, let due = core.nextDue else { return }
        let wait = max(1, due - now())
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled else { return }
            await self?.wake()
        }
    }

    private func wake() {
        guard !stopped else { return }
        perform(core.tick(now: now()))
    }

    private func now() -> Int {
        let elapsed = ContinuousClock.now - origin
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func greeting(_ body: JSONValue, epoch: String?) -> DaemonHello {
        DaemonHello(
            epoch: epoch ?? body["epoch"]?.string ?? "",
            principal: body["principal"]?.string ?? "",
            buildVersion: body["build_version"]?.string ?? "",
            buildCommit: body["build_commit"]?.string ?? ""
        )
    }
}
