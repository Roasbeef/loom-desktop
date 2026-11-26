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
    private let clock: HostClock

    private var core = Daemon()
    private var transport: (any ControlTransport)?
    private var writes: AsyncStream<String>.Continuation?
    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var connection = 0
    private var waiters: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var refreshWaiters: [CheckedContinuation<Void, Error>] = []
    /// Callers who asked while a poll was already out: that poll may have read the catalogue before
    /// their change, so they wait for the next one.
    private var laterWaiters: [CheckedContinuation<Void, Error>] = []
    private var nextTag = 1
    private var stopped = false

    /// `open` resolves the daemon's address and opens a socket to it, and runs again at every
    /// reconnect, so a daemon that moved is found again from discovery.
    public init(clock: HostClock = .real(), open: @escaping @Sendable () throws -> (endpoint: DaemonEndpoint, transport: any ControlTransport)) {
        self.clock = clock
        self.open = open
        (notes, noteSink) = AsyncStream.makeStream(of: Note.self, bufferingPolicy: .unbounded)
        (outputs, outputSink) = AsyncStream.makeStream(of: Output.self, bufferingPolicy: .unbounded)
    }

    // MARK: Lifecycle

    /// Begins connecting.
    public func start() {
        guard !stopped, readerTask == nil, transport == nil else { return }
        noteTask = Task { [weak self, notes] in
            for await note in notes { await self?.apply(note) }
        }
        perform(core.start(now: now()))
    }

    /// Ends the connection for good.
    public func stop() {
        stopped = true
        noteTask?.cancel()
        timer?.cancel()
        readerTask?.cancel()
        writes?.finish()
        transport?.close()
        transport = nil
        outputSink.finish()
        let failure = LoomError.closed("the daemon connection was closed")
        for (_, waiter) in waiters { waiter.resume(throwing: failure) }
        waiters = [:]
        failRefreshes(failure)
    }

    /// What the app tells the host about its lanes. They go through one ordered channel, because two
    /// unstructured tasks race: a lane that ends at once could be reported before it was reported made.
    private enum Note: Sendable {
        case attached(String, Int)
        case ended(String, Int)
        case forgotten(String)
        case flush(CheckedContinuation<Void, Never>)
    }

    private nonisolated let noteSink: AsyncStream<Note>.Continuation
    private let notes: AsyncStream<Note>
    private var noteTask: Task<Void, Never>?

    /// A lane was made for this session, numbered `generation`.
    public nonisolated func laneAttached(_ session: String, generation: Int) {
        noteSink.yield(.attached(session, generation))
    }

    /// The lane numbered `generation` for this session ended, so the next poll attaches it again if the
    /// session is still resident. A report about an older lane is ignored.
    public nonisolated func laneEnded(_ session: String, generation: Int) {
        noteSink.yield(.ended(session, generation))
    }

    /// A session was stopped or removed.
    public nonisolated func forget(_ session: String) {
        noteSink.yield(.forgotten(session))
    }

    private func apply(_ note: Note) {
        switch note {
        case .attached(let session, let generation): core.laneAttached(session, generation: generation)
        case .ended(let session, let generation): core.laneEnded(session, generation: generation)
        case .forgotten(let session): core.forget(session)
        case .flush(let resume): resume.resume()
        }
    }

    /// Lets every note given so far reach the core. A test uses it; the app does not need to wait.
    public func flushNotes() async {
        await withCheckedContinuation { noteSink.yield(.flush($0)) }
    }

    /// Reads the catalogue now and returns when that read has landed, for a caller that has just
    /// changed something the catalogue shows. A poll already out is not counted: it may have read the
    /// catalogue before the change, so the caller waits for one that starts after.
    public func refreshNow() async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            guard !stopped, core.isConnected else {
                resume.resume(throwing: LoomError.closed("the daemon is not connected"))
                return
            }

            // A poll already out may have listed the sessions before the change this caller made, and
            // an owner command jumps the queue, so that is the usual order. It waits for the next one.
            if core.isPolling {
                laterWaiters.append(resume)
            } else {
                refreshWaiters.append(resume)
                perform(core.pollSoon(now: now()))
            }
        }
    }

    // MARK: ControlExchange

    public func close() {
        stop()
    }

    public func epoch() async -> String? { core.epoch }

    public func request(_ cmd: String, body: JSONValue, priority: ControlLane.Priority) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { resume in
            guard !stopped else {
                resume.resume(throwing: LoomError.closed("the daemon connection was closed"))
                return
            }
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
            case .catalogue:
                outputSink.yield(.catalogue(Snapshot(status: core.status, hello: core.hello, sessions: core.sessions, activity: core.activity)))
                for waiter in refreshWaiters { waiter.resume() }
                refreshWaiters = laterWaiters
                laterWaiters = []

                // Whoever asked during this poll reads again, so their change is in what they see.
                if !refreshWaiters.isEmpty { perform(core.pollSoon(now: now())) }
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
        for waiter in refreshWaiters + laterWaiters { waiter.resume(throwing: error) }
        refreshWaiters = []
        laterWaiters = []
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
        let clock = self.clock
        timer = Task { [weak self] in
            await clock.sleep(wait)
            guard !Task.isCancelled else { return }
            await self?.wake()
        }
    }

    private func wake() {
        guard !stopped else { return }
        perform(core.tick(now: now()))
    }

    private func now() -> Int { clock.now() }
}
