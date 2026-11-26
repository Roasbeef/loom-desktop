import XCTest
import LoomKit
@testable import LoomCore

/// The control exchange as a value. The simulation (`DaemonModelTests`) checks the same
/// rules over generated schedules; these read as the story of audit finding H6.
final class ControlLaneTests: XCTestCase {
    private func hello(_ lane: inout ControlLane, now: Int = 0) {
        _ = lane.receive(Frames.envelope(replyTo: nil, event: "hello", body: ["epoch": "e1"]), now: now)
        _ = lane.takeOutputs()
    }

    private func names(_ outputs: [ControlLane.Out]) -> [String] {
        outputs.compactMap { out in
            if case .transmit(let text) = out { return Frames.decode(command: text)?.cmd }
            return nil
        }
    }

    /// H6: with one FIFO credit a created session waited behind every read that queued
    /// before it. The lane writes the oldest owner command before any background command.
    func testAnOwnerCommandIsWrittenBeforeBackgroundReadsThatQueuedBeforeIt() {
        var lane = ControlLane(now: 0)
        hello(&lane)
        _ = lane.submit(.init("sessions.review", priority: .background), now: 0)
        var written = names(lane.takeOutputs())
        _ = lane.submit(.init("status", priority: .background), now: 1)
        _ = lane.submit(.init("sessions.list", priority: .background), now: 2)
        _ = lane.submit(.init("sessions.create", priority: .owner), now: 3)
        written += names(lane.takeOutputs())
        XCTAssertEqual(written, ["sessions.review"], "the read on the wire is not preempted")

        // Its reply releases the credit, and the owner command goes next.
        _ = lane.receive(Frames.envelope(replyTo: 1, event: "review", body: .object([:])), now: 4)
        XCTAssertEqual(names(lane.takeOutputs()), ["sessions.create"])
        _ = lane.receive(Frames.envelope(replyTo: 2, event: "session", body: .object([:])), now: 5)
        XCTAssertEqual(names(lane.takeOutputs()), ["status"], "background reads keep their own order")
    }

    func testAReviewHasSixteenSecondsAndOtherCommandsSix() {
        var lane = ControlLane(now: 0)
        hello(&lane)
        _ = lane.submit(.init("sessions.review", priority: .background), now: 100)
        XCTAssertEqual(lane.nextDue, 100 + 16_000)
        _ = lane.receive(Frames.envelope(replyTo: 1, event: "review", body: .object([:])), now: 200)
        _ = lane.submit(.init("status", priority: .background), now: 300)
        XCTAssertEqual(lane.nextDue, 300 + 6_000)
    }

    func testALostReplyEndsTheLaneAndNamesThatCommandOnce() {
        var lane = ControlLane(now: 0)
        hello(&lane)
        let admitted = lane.submit(.init("sessions.create", priority: .owner), now: 0)
        let queued = lane.submit(.init("status", priority: .background), now: 0)
        _ = lane.takeOutputs()
        XCTAssertTrue(lane.tick(now: 5_999).isEmpty)
        let updates = lane.tick(now: 6_000)
        XCTAssertTrue(updates.contains(.lost(admitted.ticket, command: "sessions.create")))
        XCTAssertTrue(updates.contains { if case .failed(queued.ticket, _) = $0 { return true }; return false })
        XCTAssertEqual(lane.takeOutputs(), [.shut])
    }

    func testNothingIsWrittenBeforeHelloAndHelloHasADeadline() {
        var lane = ControlLane(now: 0)
        _ = lane.submit(.init("status", priority: .background), now: 0)
        XCTAssertTrue(lane.takeOutputs().isEmpty)
        XCTAssertEqual(lane.nextDue, ControlLane.helloDeadlineMs)
        _ = lane.receive(Frames.envelope(replyTo: nil, event: "hello", body: ["epoch": "e1"]), now: 10)
        XCTAssertEqual(names(lane.takeOutputs()), ["status"])
        var silent = ControlLane(now: 0)
        XCTAssertFalse(silent.tick(now: ControlLane.helloDeadlineMs).isEmpty)
    }
}

/// The attach decisions the app's two loops made by hand.
final class AttachPlanTests: XCTestCase {
    func testASessionAskingForAnApprovalGetsAFreshLaneAndAnEndedOneInheritsTheOld() {
        let plan = Daemon.attachPlan(
            resident: ["b", "a", "c", "d"],
            approvals: ["a": 1, "b": 0, "c": 2, "d": 1],
            lanes: ["c": .ended, "d": .up]
        )
        XCTAssertEqual(plan, [
            Daemon.Attach(session: "a", inheriting: .fresh),
            Daemon.Attach(session: "c", inheriting: .previous),
        ], "a session whose lane ended inherits even when it also asks for an approval, and an up lane needs nothing")
    }
}
