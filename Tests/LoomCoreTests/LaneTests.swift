import XCTest
import LoomKit
@testable import LoomCore

/// Hand-scripted cases for the pure lane. The model test in `LaneModelTests` checks
/// the same rules over generated schedules. These pin the specific transitions a
/// reader looks for first, with the constants spelled out.
final class LaneTests: XCTestCase {
    /// A lane, a clock the test moves, and a log of everything the lane wrote.
    struct Rig {
        var lane: Lane
        var now = 0
        var frames: [(id: Int, cmd: String, body: JSONValue)] = []
        var updates: [Lane.Update] = []
        var outputs: [Lane.Out] = []

        init(admission: Lane.Admission = .roleGated) {
            lane = Lane.start(sessionID: "s1", admission: admission, now: 0)
            collect()
        }

        mutating func collect() {
            for out in lane.takeOutputs() {
                outputs.append(out)
                if case .transmit(let text) = out, let frame = Frames.decode(command: text) { frames.append(frame) }
            }
        }

        mutating func feed(_ text: String) {
            updates += lane.receive(text, now: now)
            collect()
        }

        mutating func tick(at reading: Int) {
            now = reading
            updates += lane.tick(now: now)
            collect()
        }

        mutating func submit(_ command: Lane.Command) -> (Lane.Ticket, Lane.Disposition) {
            let admitted = lane.submit(command, now: now)
            updates += admitted.updates
            collect()
            return (admitted.ticket, admitted.disposition)
        }

        /// Answers the transfer the lane just began, whatever it asked for, with one metadata record.
        mutating func answerTransfer(window: String, nextSeq: Int, role: String = "owner") {
            let begin = frames.last!
            feed(Frames.begin(replyTo: begin.id, snapshot: "t\(begin.id)", window: window, nextSeq: nextSeq, session: "s1", role: role))
            feed(Frames.chunk(replyTo: frames.last!.id, snapshot: "t\(begin.id)", index: 0, kind: "metadata", record: "m", seq: nil, payload: ["cells": []]))
            feed(Frames.end(replyTo: frames.last!.id, snapshot: "t\(begin.id)", nextSeq: nextSeq))
        }
    }

    func testStartWritesTheSubscribeAndNamesTheCaptureDeadline() {
        let rig = Rig()
        XCTAssertEqual(rig.frames.map(\.cmd), ["subscribe"])
        XCTAssertEqual(rig.frames[0].id, 1)
        XCTAssertEqual(rig.lane.phase, .awaitingBegin)
        XCTAssertEqual(rig.lane.nextDue, Lane.captureDeadlineMs, "a capture has the transfer lifetime, 30 s")
    }

    func testTheFirstCutIsTheLanesOwnAndSchedulesTheFastRefresh() {
        var rig = Rig()
        rig.now = 40
        rig.answerTransfer(window: "recent", nextSeq: 7)
        XCTAssertEqual(rig.lane.phase, .ready)
        XCTAssertEqual(rig.lane.cursor, 7)
        XCTAssertEqual(rig.lane.nextDue, 40 + 250, "a lane the daemon has not pushed to refreshes every 250 ms")
        guard case .cut(nil, let cut, .requested)? = rig.updates.last else { return XCTFail("\(rig.updates)") }
        XCTAssertEqual(cut.nextSeq, 7)
    }

    func testAPushMovesTheRefreshToFiveSecondsForTheNextCapture() {
        var rig = Rig()
        rig.answerTransfer(window: "recent", nextSeq: 1)
        rig.feed(Frames.envelope(replyTo: nil, event: "stream_delta", body: ["strand": "main"]))
        rig.tick(at: 250)
        XCTAssertEqual(rig.frames.last?.cmd, "catch_up", "the idle refresh asks from the cursor")
        XCTAssertEqual(rig.frames.last?.body["from_seq"]?.int, 1)
        rig.answerTransfer(window: "catch_up", nextSeq: 1)
        XCTAssertEqual(rig.lane.nextDue, 250 + 5_000, "after a pushed frame the refresh relaxes to 5 s")
    }

    func testACommandHasTenSecondsAndALostMutationReplyIsUnknownOnce() {
        var rig = Rig()
        rig.answerTransfer(window: "recent", nextSeq: 1)
        rig.now = 100
        let (ticket, disposition) = rig.submit(.init("prompt", body: ["text": "hi"], kind: .mutation))
        XCTAssertEqual(disposition, .sent(id: rig.frames.last!.id))
        XCTAssertEqual(rig.lane.nextDue, 100 + Lane.commandDeadlineMs)
        rig.tick(at: 100 + Lane.commandDeadlineMs - 1)
        XCTAssertEqual(rig.lane.phase, .awaitingReply, "a tick before the deadline changes nothing")
        let before = rig.updates.count
        rig.tick(at: 100 + Lane.commandDeadlineMs)
        let unknown = rig.updates[before...].filter { if case .unknown = $0 { return true }; return false }
        XCTAssertEqual(unknown, [.unknown(ticket, command: "prompt", id: rig.frames.last!.id)])
        XCTAssertEqual(rig.lane.phase, .closed)
        XCTAssertEqual(rig.outputs.filter { $0 == .shut }.count, 1)
        XCTAssertEqual(rig.frames.filter { $0.cmd == "prompt" }.count, 1, "a mutation is never resent")
    }

    func testAMutationAckAsksForAnEarlyRefresh() {
        var rig = Rig()
        rig.answerTransfer(window: "recent", nextSeq: 1)
        rig.now = 900
        _ = rig.submit(.init("prompt", kind: .mutation))
        rig.feed(Frames.envelope(replyTo: rig.frames.last!.id, event: "ack", body: ["status": "admitted"]))
        XCTAssertEqual(rig.lane.nextDue, 900, "the committed write is worth seeing now")
    }

    func testCommandsWaitInOrderAndTheSecondIsWrittenOnTheFirstsReply() {
        var rig = Rig()
        rig.answerTransfer(window: "recent", nextSeq: 1)
        let (first, d1) = rig.submit(.init("notes", kind: .read))
        let (second, d2) = rig.submit(.init("models", kind: .read))
        XCTAssertEqual(rig.frames.suffix(1).map(\.cmd), ["notes"])
        guard case .sent = d1, d2 == .waiting else { return XCTFail("\(d1) \(d2)") }
        rig.feed(Frames.envelope(replyTo: rig.frames.last!.id, event: "snapshot", body: ["mode": "notes"]))
        XCTAssertEqual(rig.frames.suffix(1).map(\.cmd), ["models"])
        XCTAssertTrue(rig.updates.contains(.sent(second, id: rig.frames.last!.id)))
        XCTAssertNotEqual(first, second)
    }

    func testAStaleReplyClosesTheLaneWithoutAnUpdateForIt() {
        var rig = Rig()
        rig.answerTransfer(window: "recent", nextSeq: 1)
        _ = rig.submit(.init("notes", kind: .read))
        let before = rig.updates.count
        rig.feed(Frames.envelope(replyTo: 99, event: "snapshot", body: [:]))
        XCTAssertEqual(rig.lane.phase, .closed)
        let after = rig.updates[before...]
        XCTAssertFalse(after.contains { if case .replied = $0 { return true }; return false })
    }

    func testAWaitingMutationIsReportedNotSentWhenTheLaneFails() {
        var rig = Rig()
        let (ticket, disposition) = rig.submit(.init("prompt", kind: .mutation))
        XCTAssertEqual(disposition, .waiting, "the subscribe owns the wire")
        rig.updates += rig.lane.receive(failed: .closed("gone"))
        XCTAssertEqual(rig.updates.filter { if case .notSent(ticket, _) = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(rig.frames.filter { $0.cmd == "prompt" }.count, 0)
    }

    func testAnObserverMutationIsRefusedLocallyWhenRoleGated() {
        var rig = Rig()
        rig.answerTransfer(window: "recent", nextSeq: 1, role: "observer")
        let (_, disposition) = rig.submit(.init("prompt", kind: .mutation))
        guard case .notSent = disposition else { return XCTFail("\(disposition)") }
        var open = Rig(admission: .daemonDecides)
        open.answerTransfer(window: "recent", nextSeq: 1, role: "observer")
        guard case .sent = open.submit(.init("prompt", kind: .mutation)).1 else { return XCTFail("the daemon decides") }
    }

    func testARefusedCatchUpIsRetriedAtTheNextRefreshAndDoesNotCloseTheLane() {
        var rig = Rig()
        rig.answerTransfer(window: "recent", nextSeq: 1)
        rig.tick(at: 250)
        rig.now = 260
        rig.feed(Frames.error(replyTo: rig.frames.last!.id, code: "busy"))
        XCTAssertEqual(rig.lane.phase, .ready)
        XCTAssertEqual(rig.lane.nextDue, 260 + 250)
    }

    func testAHistoryPageDoesNotMoveTheCursor() {
        var rig = Rig()
        rig.answerTransfer(window: "recent", nextSeq: 50)
        let (ticket, _) = rig.submit(.init("history", kind: .transfer))
        rig.answerTransfer(window: "history", nextSeq: 10)
        XCTAssertEqual(rig.lane.cursor, 50)
        XCTAssertTrue(rig.updates.contains { if case .cut(ticket, _, _) = $0 { return true }; return false })
    }

    /// A socket reports its end more than once, and a close this client asked for is followed by the
    /// transport's own. A closed lane tells nobody twice.
    func testASecondReportOfTheSocketEndingChangesNothing() {
        var rig = Rig()
        rig.answerTransfer(window: "recent", nextSeq: 1)
        _ = rig.lane.close()
        rig.collect()
        let outputs = rig.outputs.count
        XCTAssertTrue(rig.lane.receive(failed: .closed("the socket ended")).isEmpty)
        rig.collect()
        XCTAssertEqual(rig.outputs.count, outputs, "no second shut")
    }
}
