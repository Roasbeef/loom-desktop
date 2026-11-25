import XCTest
@testable import LoomKit

/// A streamed reply belongs to one reserved durable entry (Loom's stream_identity).
/// An unrelated entry landing must not remove it, which the old rule did.
final class StreamHandoffTests: XCTestCase {
    private let session = "s1"

    private func delta(_ generation: String, _ kind: String, _ text: String, strand: String = "main") -> EventEnvelope {
        EventEnvelope(replyTo: nil, event: "stream_delta", seq: nil, body: [
            "strand": .string(strand), "generation": .string(generation), "kind": .string(kind), "text": .string(text),
        ])
    }

    private func cut(_ entries: [JSONValue], leaf: String?) -> Cut {
        Cut(
            window: "catch_up", nextSeq: 99, oldestSeq: 1, moreAfter: nil,
            identity: .init(sessionID: session, epoch: "e", incarnation: "i", connectionID: "c", role: "owner"),
            metadata: ["cells": [
                ["namespace": "strand.config", "key": "main", "seq": 1, "value": ["model": ["modelId": "fake"]]],
                ["namespace": "strand.leaf", "key": "main", "seq": 2, "value": leaf.map { .string($0) } ?? .null],
            ], "peers": [], "usage": .null],
            entries: entries
        )
    }

    private func assistant(_ id: String, parent: String?, _ text: String) -> JSONValue {
        ["id": .string(id), "parentId": parent.map { .string($0) } ?? .null, "seq": 1, "timestamp": 1, "type": "message",
         "message": ["role": "assistant", "content": [["type": "text", "text": .string(text)]]]]
    }

    private let identity = #"["generation","step-1",0,"reply-1"]"#

    func testTheIdentityNamesItsReservedEntryAndOtherShapesNameNone() {
        XCTAssertEqual(StreamIdentity.responseEntry(identity), "reply-1")
        XCTAssertEqual(StreamIdentity.responseEntry(#"["poll","s",3,"e"]"#), "e")
        XCTAssertNil(StreamIdentity.responseEntry("legacy-request"))
        XCTAssertNil(StreamIdentity.responseEntry(#"["generation","s",-1,"e"]"#))
        XCTAssertNil(StreamIdentity.responseEntry(#"["other","s",0,"e"]"#))
        XCTAssertNil(StreamIdentity.responseEntry(#"["generation","s",0]"#))
        XCTAssertNil(StreamIdentity.responseEntry(nil))
    }

    /// H3: an unrelated entry landing between a stream's end and its reply's entry
    /// removed the reply from the screen until its own entry arrived.
    func testAnUnrelatedEntryDoesNotRemoveAnEndedStream() {
        var state = Conversation(sessionID: session)
        state.apply(push: delta(identity, "text", "the answer"))
        state.apply(push: delta(identity, "end", ""))
        state.apply(cut: cut([assistant("other", parent: nil, "something else")], leaf: "other"))
        XCTAssertEqual(state.streams["main"]?.text, "the answer", "the reply's own entry has not landed")
        state.apply(cut: cut([assistant("reply-1", parent: "other", "the answer")], leaf: "reply-1"))
        XCTAssertNil(state.streams["main"], "its own entry hands the text to the transcript")
    }

    func testAnEntryThatArrivesBeforeTheEndRemovesTheStreamAtTheEnd() {
        var state = Conversation(sessionID: session)
        state.apply(push: delta(identity, "text", "the answer"))
        state.apply(cut: cut([assistant("reply-1", parent: nil, "the answer")], leaf: "reply-1"))
        XCTAssertNotNil(state.streams["main"], "a stream that has not ended is still being drawn")
        state.apply(push: delta(identity, "end", ""))
        XCTAssertNil(state.streams["main"])
    }

    func testAStreamWithNoReservationKeepsTheOldRule() {
        var state = Conversation(sessionID: session)
        state.apply(push: delta("legacy", "text", "x"))
        state.apply(push: delta("legacy", "end", ""))
        state.apply(cut: cut([assistant("other", parent: nil, "y")], leaf: "other"))
        XCTAssertNil(state.streams["main"])
    }
}
