import Foundation
@testable import LoomKit

/// A test double: an exchange over one control socket that runs the commands and nothing else.
///
/// The app and `loom-probe` use `DaemonHost`, which hosts the whole connection, poll included. A
/// test of how the client settles commands cannot have a poll interleave frames with its scripted
/// transport, so it uses this: the same shell around `ControlLane`, without the poll.
///
/// This actor is the shell around `ControlLane`. The lane decides: which command is on the
/// wire, which waits, when a reply is overdue. The actor forwards frames to it with a
/// clock reading, writes its outputs in order, arms one timer for its next deadline, and
/// resumes the caller a settled ticket names.
///
/// Commands carry a priority. A person's action (create, stop, answer) is `owner`, and the
/// poll and other background reads are `background`. The lane writes the oldest owner
/// command before any background one, so an action waits behind at most the read already on
/// the wire and never behind reads that queued after it began. Before, one FIFO credit made
/// a created session wait behind a `sessions.review` of up to 16 s and the polls queued
/// after it (audit finding H6).
actor ControlLaneExchange: ControlExchange {
    /// `sessions.activity` accepts at most this many ids per request.
    private let transport: any ControlTransport
    private var core: ControlLane
    private let writes: AsyncStream<String>.Continuation
    private let writeQueue: AsyncStream<String>
    private let origin = ContinuousClock.now
    private var waiters: [ControlLane.Ticket: CheckedContinuation<JSONValue, Error>] = [:]
    private var helloWaiter: CheckedContinuation<DaemonHello, Error>?
    private var ended: LoomError?
    private var readerTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var greeting: DaemonHello?

    /// A client over any transport, for a test that stands in for the daemon.
    init(transport: any ControlTransport) {
        self.transport = transport
        core = ControlLane(now: 0)
        (writeQueue, writes) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }

    /// Starts reading and writing, and waits for the `hello` every other command depends
    /// on for the epoch. The lane gives the daemon six seconds to send it.
    @discardableResult
    func connect() async throws -> DaemonHello {
        if let greeting { return greeting }
        startIfNeeded()
        return try await withCheckedThrowingContinuation { resume in
            if let ended {
                resume.resume(throwing: ended)
            } else if let greeting {
                resume.resume(returning: greeting)
            } else {
                helloWaiter = resume
            }
        }
    }

    func close() {
        apply { $0.close() }
    }

    /// Starts the reader and the writer once, so a command sent before `connect` still
    /// finds the `hello` it waits for.
    private func startIfNeeded() {
        guard readerTask == nil else { return }
        readerTask = Task { await self.readLoop() }
        writerTask = Task { await self.writeLoop() }
        arm()
    }

    func epoch() async -> String? { greeting?.epoch }

    /// One command, one correlated reply. The control socket pushes nothing after
    /// `hello`, so a frame here can only be this command's answer.
    ///
    /// The caller's cancellation never reaches the socket: the lane consumes the reply in
    /// order whether or not the caller is still waiting. A cancelled exchange would
    /// otherwise close the shared connection, which fails every other read in flight.
    func request(_ cmd: String, body: JSONValue, priority: ControlLane.Priority) async throws -> JSONValue {
        startIfNeeded()
        return try await withCheckedThrowingContinuation { resume in
            let admitted = core.submit(ControlLane.Command(cmd, body: body, priority: priority), now: now())
            waiters[admitted.ticket] = resume
            handle(admitted.updates)
        }
    }

    // MARK: The bridge to the lane

    private func apply(_ transition: (inout ControlLane) -> [ControlLane.Update]) {
        handle(transition(&core))
    }

    private func handle(_ updates: [ControlLane.Update]) {
        for output in core.takeOutputs() {
            switch output {
            case .transmit(let text): writes.yield(text)
            case .shut: writes.finish()
            }
        }
        for update in updates { route(update) }
        arm()
    }

    private func route(_ update: ControlLane.Update) {
        switch update {
        case .hello(let epoch, let body):
            let greeting = DaemonHello(
                epoch: epoch,
                principal: body["principal"]?.string ?? "",
                buildVersion: body["build_version"]?.string ?? "",
                buildCommit: body["build_commit"]?.string ?? ""
            )
            self.greeting = greeting
            helloWaiter?.resume(returning: greeting)
            helloWaiter = nil
        case .replied(let ticket, let body):
            waiters.removeValue(forKey: ticket)?.resume(returning: body)
        case .refused(let ticket, let code, let message, let details):
            waiters.removeValue(forKey: ticket)?.resume(throwing: LoomError.server(code: code, message: message, details: details))
        case .lost(let ticket, let command):
            waiters.removeValue(forKey: ticket)?.resume(throwing: LoomError.outcomeUnknown(command: command))
        case .failed(let ticket, let error):
            waiters.removeValue(forKey: ticket)?.resume(throwing: error)
        case .closed(let error):
            ended = error ?? .closed("the control connection has ended")
            readerTask?.cancel()
            timer?.cancel()
            transport.close()
            helloWaiter?.resume(throwing: ended ?? .closed("the control connection has ended"))
            helloWaiter = nil
        }
    }

    private func readLoop() async {
        while core.phase != .closed {
            do {
                let text = try await transport.receive()
                apply { $0.receive(text, now: now()) }
            } catch let error as LoomError {
                apply { $0.receive(failed: error) }
            } catch {
                apply { $0.receive(failed: .closed(error.localizedDescription)) }
            }
        }
    }

    private func writeLoop() async {
        for await text in writeQueue {
            do {
                try await transport.send(text)
            } catch let error as LoomError {
                apply { $0.receive(failed: error) }
            } catch {
                apply { $0.receive(failed: .closed(error.localizedDescription)) }
            }
        }
    }

    private func arm() {
        timer?.cancel()
        timer = nil
        guard let due = core.nextDue else { return }
        let wait = max(1, due - now())
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled else { return }
            await self?.wake()
        }
    }

    private func wake() {
        apply { $0.tick(now: now()) }
    }

    private func now() -> Int {
        let elapsed = ContinuousClock.now - origin
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

extension ControlClient {
    /// A client over a scripted transport, for a test that stands in for the daemon.
    convenience init(transport: any ControlTransport) {
        self.init(exchange: ControlLaneExchange(transport: transport))
    }
}
