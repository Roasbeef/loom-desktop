import XCTest
import LoomKit
@testable import LoomCore

/// Hand-scripted cases for the session core, one for each bug the audit named in the
/// composer and the stream's projection. The swarm in `SessionModelTests` finds the same
/// rules by search. These read as the story of each.
final class SessionTests: XCTestCase {
    /// A session, a daemon, a wire and a clock, with the shell's job done by hand.
    struct Rig {
        var session: Session
        var daemon = FakeDaemon()
        var wire: [String] = []
        var now = 0
        var effects: [Session.Effect] = []
        var dropNextTransmit = false

        init() {
            let started = Session.start(sessionID: "s1", now: 0)
            session = started.session
            absorb(started.effects)
            pump()
        }

        mutating func absorb(_ batch: [Session.Effect]) {
            effects += batch
            for case .transmit(let text) in batch {
                if dropNextTransmit, Frames.decode(command: text)?.cmd == "prompt" {
                    dropNextTransmit = false
                    continue
                }
                wire += daemon.receive(command: text)
            }
        }

        /// Delivers every frame on the wire, in order.
        mutating func pump() {
            while !wire.isEmpty {
                let frame = wire.removeFirst()
                if (try? EventEnvelope.decode(frame))?.replyTo != nil { daemon.replyConsumed() }
                absorb(session.receive(frame, now: now))
            }
        }

        mutating func send(_ text: String, strand: String = "main") {
            let command = Lane.Command("prompt", body: ["strand": .string(strand), "text": .string(text)], kind: .mutation)
            absorb(session.apply(.send(text: text, delivery: .send, command: command), now: now))
        }

        /// Drops the daemon's replies, as a lost reply does.
        mutating func dropReplies() {
            wire.removeAll { (try? EventEnvelope.decode($0))?.replyTo != nil }
        }

        mutating func advance(to reading: Int) {
            now = reading
            absorb(session.tick(now: now))
        }

        func has(_ matches: (Session.Effect) -> Bool) -> Bool { effects.contains(where: matches) }
    }

    /// H1: a prompt the daemon applied but whose reply was lost was restored to the editor,
    /// leaving the text both in the transcript and one Return from a second send.
    func testALostReplyKeepsTheTextOutOfTheEditorAndTheNextCutShowsItArrived() {
        var rig = Rig()
        rig.send("hello#")
        rig.dropReplies()
        rig.advance(to: Lane.commandDeadlineMs)
        XCTAssertTrue(rig.has { if case .notice(Session.maybeSentWords, _) = $0 { return true }; return false })
        XCTAssertFalse(rig.has { if case .restoreDraft = $0 { return true }; return false }, "an unknown outcome is not a refusal")
        XCTAssertEqual(rig.daemon.applied["prompt:hello#"], 1)
        XCTAssertEqual(rig.session.ledger.lines.map(\.isUnknown), [true])

        // The shell reattaches, and the new session's first cut settles the line.
        let next = Session.start(sessionID: "s1", inheriting: rig.session, now: 13_000)
        rig.session = next.session
        rig.daemon.attach()
        rig.wire = []
        rig.effects = []
        rig.now = 13_000
        rig.absorb(next.effects)
        rig.pump()
        XCTAssertTrue(rig.session.ledger.lines.isEmpty)
        XCTAssertFalse(rig.has { if case .restoreDraft = $0 { return true }; return false }, "the prompt is in the transcript, so no text comes back")
        XCTAssertEqual(Session.occurrences(of: "hello#", in: rig.session.conversation, strand: "main"), 1)
    }

    func testALostReplyForAPromptTheDaemonNeverSawOffersTheTextBack() {
        var rig = Rig()
        rig.dropNextTransmit = true
        rig.send("hello#")
        rig.advance(to: Lane.commandDeadlineMs)
        XCTAssertEqual(rig.daemon.applied["prompt:hello#"], nil)
        let next = Session.start(sessionID: "s1", inheriting: rig.session, now: 13_000)
        rig.session = next.session
        rig.daemon.attach()
        rig.wire = []
        rig.effects = []
        rig.absorb(next.effects)
        rig.pump()
        XCTAssertTrue(rig.has { $0 == .restoreDraft("hello#") }, "the prompt did not arrive, so its text is offered back")
        XCTAssertTrue(rig.session.ledger.lines.isEmpty)
    }

    func testARefusalIsDefiniteSoTheTextReturnsAtOnce() {
        var rig = Rig()
        rig.send("hello#", strand: "nowhere")
        rig.pump()
        XCTAssertTrue(rig.has { $0 == .restoreDraft("hello#") })
        XCTAssertTrue(rig.session.ledger.lines.isEmpty)
    }

    /// H4: pushes that are not tokens changed the observed stream once each. The core asks
    /// for the stream to be written once per flush window and never for another push.
    func testPushesThatAreNotTokensNeverWriteTheStreamAndTokensAreCoalescedToTheFlush() {
        var rig = Rig()
        rig.send("go#")
        rig.pump()
        rig.effects = []
        for _ in 0..<5 {
            rig.wire += rig.daemon.progress(choice: 1)
            rig.wire.append(Frames.envelope(replyTo: nil, event: "tool_output", body: ["call_id": "c", "tail": "x"]))
            rig.wire.append(Frames.envelope(replyTo: nil, event: "presence", body: ["peers": []]))
            rig.pump()
        }
        XCTAssertFalse(rig.has { $0 == .project(.stream) }, "no flush has come due yet")
        XCTAssertEqual(rig.session.flushAt, Session.flushMs(replyBytes: 0), "the first token set the window")
        rig.advance(to: 33)
        XCTAssertEqual(rig.effects.filter { $0 == .project(.stream) }.count, 1, "five tokens, one write")
        XCTAssertNil(rig.session.flushAt)
    }

    func testTheFlushWindowGrowsWithTheReply() {
        XCTAssertEqual(Session.flushMs(replyBytes: 100), 33)
        XCTAssertEqual(Session.flushMs(replyBytes: 4_001), 60)
        XCTAssertEqual(Session.flushMs(replyBytes: 16_001), 100)
    }
}
