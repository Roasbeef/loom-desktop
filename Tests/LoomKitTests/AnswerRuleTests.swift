import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// What an ask offers and when an answer may be sent (`MissionKit/AnswerRule.swift`),
/// which mirrors the daemon's `core/attention_answer.gleam` check. Each case that
/// ports one says which.
final class AnswerRuleTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONValue.parse(Data(text.utf8))
    }

    private func question(_ text: String) throws -> AttentionQuestion {
        try XCTUnwrap(AttentionQuestion(json(text)))
    }

    private func confirm() throws -> AttentionQuestion {
        try question(#"{"key":"q1","prompt":"Go on?","kind":"confirm"}"#)
    }

    private func choice() throws -> AttentionQuestion {
        try question(#"{"key":"q2","prompt":"How?","kind":"choice","options":[{"label":"Retry"},{"label":"Skip","recommended":true}]}"#)
    }

    private func multiple(min: Int? = nil, max: Int? = nil) throws -> AttentionQuestion {
        let bounds = [min.map { "\"min\":\($0)" }, max.map { "\"max\":\($0)" }].compactMap { $0 }.joined(separator: ",")
        return try question("""
        {"key":"q3","prompt":"Which?","kind":"multiple","options":[{"label":"a.gleam"},{"label":"b.gleam"},{"label":"c.gleam"}]\(bounds.isEmpty ? "" : "," + bounds)}
        """)
    }

    private func fill(_ format: String? = nil) throws -> AttentionQuestion {
        try question(#"{"key":"q4","prompt":"Say.","kind":"fill"\#(format.map { ",\"format\":\"\($0)\"" } ?? "")}"#)
    }

    private func ask(routing: String? = "owner", mayAnswer: Bool = true, questions: [String] = []) throws -> AttentionRecord.Ask {
        let record = try XCTUnwrap(AttentionRecord(json("""
        {"kind":"ask","id":"ask-1","revision":3,"status":"open","strand":"main","created_at":1,"routing":"\(routing ?? "")",
         "may_answer":\(mayAnswer),"questions":[\(questions.joined(separator: ","))]}
        """)))
        guard case .ask(let ask) = record.detail else { throw XCTSkip("not an ask") }
        return ask
    }

    private func refusal(_ check: AnswerCheck) -> AnswerRefusal? {
        if case .refused(let refusal) = check { return refusal }
        return nil
    }

    // MARK: The body

    /// Ports the answer of loom protocol-change/119, "The answer": one value for each
    /// question, in the question's kind, and a null with its text for Other.
    func testEveryKindMakesItsOwnValue() throws {
        let questions = [try confirm(), try choice(), try multiple(), try fill("number")]
        let check = AnswerRule.check(questions: questions, entries: [
            "q1": .confirm(true), "q2": .picked("Retry"), "q3": .ticked(["c.gleam", "a.gleam"]), "q4": .typed("-3.5"),
        ])
        XCTAssertEqual(check, .ready(AttentionAnswerBody(entries: [
            ("q1", .confirm(true)), ("q2", .choice("Retry")),
            // The labels keep the question's order, not the order they were ticked in.
            ("q3", .labels(["a.gleam", "c.gleam"])), ("q4", .text("-3.5")),
        ])))
    }

    func testOtherReplacesAnyKindWithTheText() throws {
        let questions = [try confirm(), try multiple()]
        let check = AnswerRule.check(questions: questions, entries: ["q1": .other("Not yet."), "q3": .ticked(["a.gleam"])])
        XCTAssertEqual(check, .ready(AttentionAnswerBody(entries: [("q1", .other("Not yet.")), ("q3", .labels(["a.gleam"]))])))
    }

    /// The first question in the ask's order that fails is the one named, as
    /// `core/attention_answer.check` names the first failing key.
    func testTheFirstQuestionWithoutAnAnswerIsNamed() throws {
        let questions = [try confirm(), try choice(), try fill()]
        let check = AnswerRule.check(questions: questions, entries: ["q1": .confirm(false), "q3": .typed("x")])
        XCTAssertEqual(refusal(check)?.key, "q2")
    }

    func testAChoiceMustBeOneOfTheOptions() throws {
        XCTAssertEqual(refusal(AnswerRule.check(questions: [try choice()], entries: ["q2": .picked("Burn it")]))?.key, "q2")
    }

    /// Ports the `multiple` bounds: `min` and `max`, defaulting to one and the option
    /// count. A checklist takes any subset, none included.
    func testMultipleHoldsItsBoundsAndAChecklistDoesNot() throws {
        XCTAssertNotNil(refusal(AnswerRule.check(questions: [try multiple()], entries: ["q3": .ticked([])])))
        XCTAssertNotNil(refusal(AnswerRule.check(questions: [try multiple(min: 2, max: 2)], entries: ["q3": .ticked(["a.gleam"])])))
        XCTAssertNotNil(refusal(AnswerRule.check(questions: [try multiple(max: 1)], entries: ["q3": .ticked(["a.gleam", "b.gleam"])])))
        XCTAssertNil(refusal(AnswerRule.check(questions: [try multiple(min: 0, max: 3)], entries: ["q3": .ticked([])])))

        let checklist = try question(#"{"key":"q5","prompt":"?","kind":"checklist","options":[{"label":"x"},{"label":"y"}]}"#)
        XCTAssertEqual(AnswerRule.check(questions: [checklist], entries: ["q5": .ticked([])]), .ready(AttentionAnswerBody(entries: [("q5", .labels([]))])))
    }

    /// Ports `fill_text` and `shaped`: not empty, no NUL, within the format's size, of
    /// the format's shape.
    func testFillIsHeldToItsFormat() throws {
        func result(_ format: String?, _ text: String) throws -> AnswerRefusal? {
            refusal(AnswerRule.check(questions: [try fill(format)], entries: ["q4": .typed(text)]))
        }
        XCTAssertNotNil(try result(nil, "   "))
        XCTAssertNotNil(try result(nil, "a\u{0000}b"))
        XCTAssertNil(try result(nil, "anything\nat all"))
        XCTAssertNotNil(try result("path", "a\nb"))
        XCTAssertNil(try result("path", "src/a.gleam"))
        for bad in ["", "1.", ".5", "1.2.3", "+4", "1e3", "12a", "--1"] where !bad.isEmpty { XCTAssertNotNil(try result("number", bad), bad) }
        for good in ["0", "12", "-3", "-3.50", "007"] { XCTAssertNil(try result("number", good), good) }
        XCTAssertNil(try result("url", "https://example.com/a b".replacingOccurrences(of: " ", with: "%20")))
        for bad in ["example.com", "ftp://x", "http://", "https://a b", "https://a\nb"] { XCTAssertNotNil(try result("url", bad), bad) }
    }

    func testTextIsBoundedInBytes() throws {
        let tooLong = String(repeating: "\u{00E9}", count: 501)
        XCTAssertNotNil(refusal(AnswerRule.check(questions: [try fill()], entries: ["q4": .typed(tooLong)])))
        XCTAssertNotNil(refusal(AnswerRule.check(questions: [try confirm()], entries: ["q1": .other(tooLong)])))
        XCTAssertNil(refusal(AnswerRule.check(questions: [try fill("long_text")], entries: ["q4": .typed(tooLong)])))
        XCTAssertNotNil(refusal(AnswerRule.check(questions: [try fill("long_text")], entries: ["q4": .typed(String(repeating: "a", count: 4001))])))
        XCTAssertNotNil(refusal(AnswerRule.check(questions: [try confirm()], entries: ["q1": .other(" \n ")])))
    }

    // MARK: What is offered

    func testAnOpenAskRoutedToTheOwnerOffersTheForm() throws {
        XCTAssertEqual(
            AnswerRule.offer(ask: try ask(questions: [#"{"key":"q1","prompt":"?","kind":"confirm"}"#]), status: "open", isObserver: false, unsupported: false),
            .form
        )
    }

    func testAnObserverIsOfferedNoControls() throws {
        let q = [#"{"key":"q1","prompt":"?","kind":"confirm"}"#]
        for (mayAnswer, isObserver) in [(false, false), (true, true), (false, true)] {
            let offer = AnswerRule.offer(ask: try ask(mayAnswer: mayAnswer, questions: q), status: "open", isObserver: isObserver, unsupported: false)
            XCTAssertEqual(offer, .words("Only the owner or an operator can answer an ask."))
        }
    }

    func testAnAnsweredAskAndAStrandsAskAreWordsOnly() throws {
        let q = [#"{"key":"q1","prompt":"?","kind":"confirm"}"#]
        XCTAssertEqual(AnswerRule.offer(ask: try ask(questions: q), status: "answered", isObserver: false, unsupported: false), .words("This ask has been answered."))
        XCTAssertEqual(
            AnswerRule.offer(ask: try ask(routing: "sub:main/audit", questions: q), status: "open", isObserver: false, unsupported: false),
            .words("This ask is routed to the strand sub:main/audit, which is not answered here.")
        )
    }

    /// A question kind a newer daemon added has no control, so the ask is read-only.
    func testAQuestionThisAppCannotDrawLeavesTheAskReadOnly() throws {
        let q = [#"{"key":"q1","prompt":"?","kind":"slider"}"#]
        guard case .words(let words) = AnswerRule.offer(ask: try ask(questions: q), status: "open", isObserver: false, unsupported: false) else {
            return XCTFail("expected words")
        }
        XCTAssertTrue(words.hasPrefix("This ask has a question this app cannot draw."))
        XCTAssertEqual(AnswerRule.offer(ask: try ask(), status: "open", isObserver: false, unsupported: false).isForm, false)
    }

    /// An unknown-command reply puts the ask back to what the app said before the
    /// command existed.
    func testAnOlderDaemonLeavesTheAskReadOnlyAsItWas() throws {
        let q = [#"{"key":"q1","prompt":"?","kind":"confirm"}"#]
        XCTAssertEqual(
            AnswerRule.offer(ask: try ask(questions: q), status: "open", isObserver: false, unsupported: true),
            .words("Answer on the session's page; this window shows an ask and does not answer it.")
        )
    }

    // MARK: The daemon's refusals

    /// Fixture: the refusal table of loom docs/client-protocol.md section 3.34: the
    /// message names the first failing key, and the daemon's words are shown as sent.
    func testTheDaemonsWordsAreShownAsTheyCame() {
        let named = AnswerRule.aftermath(code: "bad_request", message: "q2: not one of the options")
        XCTAssertEqual(named, AnswerAftermath(words: "q2: not one of the options", follow: .nothing))
        XCTAssertEqual(AnswerRule.aftermath(code: "forbidden", message: "").words, "Only the owner can do that.")
        XCTAssertEqual(
            AnswerRule.aftermath(code: "not_found", message: "the asking strand no longer exists; the ask is still open"),
            AnswerAftermath(words: "the asking strand no longer exists; the ask is still open", follow: .nothing)
        )
        XCTAssertEqual(AnswerRule.aftermath(code: "not_resident", message: "").words, "not_resident")
    }

    /// A conflict that says `delivered` means the prompt arrived and the record did
    /// not settle: the form holds until the record is read again. A stale revision
    /// is read again too. A refused gateway is not delivered and needs no read.
    func testADeliveredConflictHoldsTheFormUntilTheRecordIsReadAgain() {
        XCTAssertEqual(AnswerRule.aftermath(code: "conflict", message: "delivered; the record changed").follow, .holdThenReread)
        XCTAssertEqual(AnswerRule.aftermath(code: "unavailable", message: "delivered; the settling write failed").follow, .holdThenReread)
        XCTAssertEqual(AnswerRule.aftermath(code: "conflict", message: "the ask was changed").follow, .reread)
        XCTAssertEqual(AnswerRule.aftermath(code: "unavailable", message: "the gateway did not answer in time").follow, .nothing)
        XCTAssertEqual(AnswerRule.aftermath(code: "stale_epoch", message: "").follow, .nothing)
    }

    // MARK: The hold

    func testASendInFlightHoldsASecondOne() {
        var flow = AnswerFlow()
        XCTAssertTrue(flow.begin())
        XCTAssertFalse(flow.begin())
        XCTAssertFalse(flow.maySend)
    }

    /// The invariant of the whole form: after "delivered; the record changed", no
    /// second answer is sent until a read of the record has landed.
    func testNoSecondAnswerUntilARecordReadLandsAfterADeliveredRefusal() {
        var flow = AnswerFlow()
        XCTAssertTrue(flow.begin())
        flow.refused(AnswerRule.aftermath(code: "conflict", message: "delivered; the record changed"))
        XCTAssertEqual(flow.said, "delivered; the record changed")
        XCTAssertFalse(flow.maySend)
        XCTAssertFalse(flow.begin())
        XCTAssertNotNil(flow.holdWords)

        // A read that failed never calls this, so the form stays held until one lands.
        flow.readLanded()
        XCTAssertTrue(flow.maySend)
        XCTAssertNil(flow.holdWords)
    }

    func testARefusalThatChangedNothingLeavesTheFormOpen() {
        var flow = AnswerFlow()
        XCTAssertTrue(flow.begin())
        flow.refused(AnswerRule.aftermath(code: "bad_request", message: "q1: missing"))
        XCTAssertTrue(flow.maySend)
    }

    func testAStaleRevisionHoldsTheFormUntilTheReadToo() {
        var flow = AnswerFlow()
        XCTAssertTrue(flow.begin())
        flow.refused(AnswerRule.aftermath(code: "conflict", message: "the ask was changed"))
        XCTAssertFalse(flow.maySend)
        flow.readLanded()
        XCTAssertTrue(flow.maySend)
    }

    func testADeliveryHoldsTheFormUntilTheRecordIsRead() {
        var flow = AnswerFlow()
        XCTAssertTrue(flow.begin())
        flow.delivered(words: AnswerRule.deliveredWords(.queued, name: "build"))
        XCTAssertEqual(flow.said, "Answer delivered to build \u{00B7} queued")
        XCTAssertFalse(flow.maySend)
        flow.readLanded()
        XCTAssertTrue(flow.maySend)
    }
}

extension AnswerOffer {
    fileprivate var isForm: Bool { self == .form }
}
