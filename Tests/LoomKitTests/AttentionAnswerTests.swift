import Foundation
import XCTest
@testable import LoomKit

/// The wire shapes of `attention.answer` and `sessions.saved_attention` (loom
/// protocol-change/128 and docs/client-protocol.md section 3.34). Each fixture
/// names the document it is taken from.
final class AttentionAnswerTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONValue.parse(Data(text.utf8))
    }

    // MARK: attention.answer

    /// Fixture: the request example of loom docs/client-protocol.md section 3.34
    /// (line 2151), whose answer has a confirm and a choice.
    func testTheDocumentedAnswerRequestIsWhatIsSent() throws {
        let body = AttentionWire.answerBody(
            session: "0198c0de-0000-7000-8000-000000000001", ask: "ask-3f9c01a2b4", revision: 41,
            answer: AttentionAnswerBody(entries: [("q1", .confirm(true)), ("q2", .choice("Retry"))]),
            epoch: "ep-7f3a"
        )
        let expected = try json("""
        {"session":"0198c0de-0000-7000-8000-000000000001","ask":"ask-3f9c01a2b4","revision":41,
         "answer":{"answers":{"q1":true,"q2":"Retry"}},"epoch":"ep-7f3a"}
        """)
        XCTAssertEqual(body, expected)
    }

    /// Fixture: the answer object of loom protocol-change/119, "The answer": a
    /// confirm, a choice, a list and a question answered by Other, whose value is
    /// null and whose text sits in `other` under the same key.
    func testAnOtherAnswerIsNullBesideItsText() throws {
        let answer = AttentionAnswerBody(entries: [
            ("q1", .confirm(true)), ("q2", .choice("Retry")), ("q3", .labels(["a.gleam", "b.gleam"])),
            ("q4", .other("Do it in a branch instead.")),
        ])
        let expected = try json("""
        {"answers":{"q1":true,"q2":"Retry","q3":["a.gleam","b.gleam"],"q4":null},
         "other":{"q4":"Do it in a branch instead."}}
        """)
        XCTAssertEqual(answer.json, expected)
    }

    func testAnAnswerWithNoOtherCarriesNoOtherMember() {
        let answer = AttentionAnswerBody(entries: [("q1", .text("12.5")), ("q2", .labels([]))])
        XCTAssertNil(answer.json["other"])
        XCTAssertEqual(answer.json["answers"]?["q1"], "12.5")
        XCTAssertEqual(answer.json["answers"]?["q2"], .array([]))
    }

    /// Fixture: the reply example of loom docs/client-protocol.md section 3.34
    /// (line 2152).
    func testTheDocumentedReceiptDecodes() throws {
        let receipt = try XCTUnwrap(AnswerReceipt(json(#"{"ask":"ask-3f9c01a2b4","delivery":"admitted","revision":42}"#)))
        XCTAssertEqual(receipt.ask, "ask-3f9c01a2b4")
        XCTAssertEqual(receipt.delivery, .admitted)
        XCTAssertEqual(receipt.revision, 42)

        let queued = try XCTUnwrap(AnswerReceipt(json(#"{"ask":"ask-3f9c01a2b4","delivery":"queued","revision":42}"#)))
        XCTAssertEqual(queued.delivery, .queued)
    }

    func testAReceiptWithADamagedMemberIsNoReceipt() throws {
        XCTAssertNil(AnswerReceipt(try json(#"{"ask":"a","delivery":"sent","revision":1}"#)))
        XCTAssertNil(AnswerReceipt(try json(#"{"ask":"a","delivery":"queued","revision":-1}"#)))
        XCTAssertNil(AnswerReceipt(try json(#"{"delivery":"queued","revision":1}"#)))
    }

    // MARK: sessions.saved_attention

    /// Fixture: the request example of section 3.34 (line 2112).
    func testTheDocumentedSavedRequestIsWhatIsSent() throws {
        let body = AttentionWire.savedBody(
            sessions: ["0198c0de-0000-7000-8000-000000000001", "0198c0de-0000-7000-8000-000000000002"], epoch: "ep-7f3a"
        )
        let expected = try json("""
        {"sessions":["0198c0de-0000-7000-8000-000000000001","0198c0de-0000-7000-8000-000000000002"],"epoch":"ep-7f3a"}
        """)
        XCTAssertEqual(body, expected)
    }

    /// Fixture: the reply example of section 3.34 (line 2113).
    func testTheDocumentedSavedReplyDecodes() throws {
        let rows = AttentionWire.savedRows(try json("""
        {"saved":[{"session_id":"0198c0de-0000-7000-8000-000000000002","pending_approvals":1,"open_asks":0,"open_finds":2,
        "oldest_open_at":1763400000000,"updated_at":1763400100000}]}
        """))
        XCTAssertEqual(rows, ["0198c0de-0000-7000-8000-000000000002": SavedAttention(
            sessionID: "0198c0de-0000-7000-8000-000000000002", pendingApprovals: 1, openAsks: 0, openFinds: 2,
            oldestOpenAt: 1_763_400_000_000, updatedAt: 1_763_400_100_000
        )])
    }

    /// `oldest_open_at` is absent when no ask or find is open (protocol-change/128).
    /// A row with a negative count or a missing member is dropped alone.
    func testASavedRowWithNoOpenRecordHasNoTimeAndADamagedRowIsDropped() throws {
        let rows = AttentionWire.savedRows(try json("""
        {"saved":[
          {"session_id":"a","pending_approvals":2,"open_asks":0,"open_finds":0,"updated_at":5},
          {"session_id":"b","pending_approvals":-1,"open_asks":0,"open_finds":0,"updated_at":5},
          {"session_id":"c","pending_approvals":0,"open_asks":0,"open_finds":0},
          {"session_id":"d","pending_approvals":0,"open_asks":1,"open_finds":0,"oldest_open_at":-3,"updated_at":6}
        ]}
        """))
        XCTAssertEqual(Set(rows.keys), ["a", "d"])
        XCTAssertNil(rows["a"]?.oldestOpenAt)
        XCTAssertEqual(rows["a"]?.pendingApprovals, 2)

        // A damaged time reads as absent, and the counts still stand.
        XCTAssertNil(rows["d"]?.oldestOpenAt)
        XCTAssertEqual(rows["d"]?.openAsks, 1)
    }

    func testAReplyWithNoRowsIsNoRows() throws {
        XCTAssertEqual(AttentionWire.savedRows(try json(#"{"saved":[]}"#)), [:])
        XCTAssertEqual(AttentionWire.savedRows(try json("{}")), [:])
    }

    // MARK: Unknown command

    /// Fixture: client protocol section 1.5 (an unknown command is `unsupported`) and
    /// sections 3.29 and 3.31 (a daemon built before a command answers `bad_request` with
    /// `unsupported control command`).
    func testBothWaysAnOlderDaemonRefusesAnUnknownCommand() {
        XCTAssertTrue(LoomError.server(code: "unsupported", message: "", details: nil).isUnknownCommand)
        XCTAssertTrue(LoomError.server(code: "bad_request", message: "unsupported control command", details: nil).isUnknownCommand)
    }

    func testOtherRefusalsAreNotAnUnknownCommand() {
        XCTAssertFalse(LoomError.server(code: "bad_request", message: "q2: not one of the options", details: nil).isUnknownCommand)
        XCTAssertFalse(LoomError.server(code: "conflict", message: "delivered; the record changed", details: nil).isUnknownCommand)
        XCTAssertFalse(LoomError.closed("gone").isUnknownCommand)
    }
}
