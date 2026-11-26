import Foundation
import XCTest
@testable import LoomKit

/// A control connection is shared by every view's reads, so one caller's cancellation
/// must not close it. These tests stand in for the daemon with a transport that
/// answers each command after a delay.
final class ControlCancellationTests: XCTestCase {
    /// Answers every command with an empty body, after `delay`, and records whether
    /// the connection was closed.
    private final class Echo: ControlTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int] = []
        private var isClosed = false
        let delay: Duration

        init(delay: Duration) { self.delay = delay }

        var closed: Bool { lock.withLock { isClosed } }

        func send(_ text: String) async throws {
            let id = (try JSONValue.parse(Data(text.utf8)))["id"]?.int ?? -1
            lock.withLock { ids.append(id) }
        }

        private var greeted = false

        func receive() async throws -> String {
            // A control socket opens with hello, and the client sends nothing before it.
            if lock.withLock({ defer { greeted = true }; return !greeted }) {
                return #"{"v":2,"event":"hello","body":{"epoch":"e1"}}"#
            }
            try await Task.sleep(for: delay)
            let id = lock.withLock { ids.isEmpty ? -1 : ids.removeFirst() }
            return #"{"v":2,"reply_to":\#(id),"event":"projects.list","body":{"projects":[]}}"#
        }

        func close() { lock.withLock { isClosed = true } }
    }

    func testACancelledCallerDoesNotCloseTheConnectionAndTheNextRequestSucceeds() async throws {
        let transport = Echo(delay: .milliseconds(150))
        let client = ControlClient(transport: transport)
        let slow = Task { try await client.projects() }
        try await Task.sleep(for: .milliseconds(30))
        slow.cancel()
        _ = try? await slow.value

        XCTAssertFalse(transport.closed, "a caller's cancellation must not reach the shared socket")
        let next = try await client.projects()
        XCTAssertEqual(next, [])
        XCTAssertFalse(transport.closed)
    }

    func testTheReplyOfACancelledCallerIsStillConsumedInOrder() async throws {
        let transport = Echo(delay: .milliseconds(80))
        let client = ControlClient(transport: transport)
        let first = Task { try await client.projects() }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()

        // The second request queues behind the first's exchange, and each reply names its own id.
        let second = try await client.projects()
        XCTAssertEqual(second, [])
        XCTAssertFalse(transport.closed)
    }

    func testAReviewMayWaitLongerThanAnOrdinaryCommand() {
        XCTAssertEqual(ControlClient.deadline(for: "projects.list"), 6)
        XCTAssertGreaterThan(ControlClient.deadline(for: "sessions.review"), 14, "the protocol lets a review wait up to 14 seconds")
    }
}
