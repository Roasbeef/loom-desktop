import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// The session page's ask cards and the transcript's mark on the asking turn
/// (`MissionKit/AskCard.swift`).
final class AskCardTests: XCTestCase {
    private func ask(_ id: String, at: Int, strand: String = "main", head: String = "Which layout?") -> AttentionAsk {
        AttentionAsk(id: id, strand: strand, createdAt: at, head: head, questions: 2)
    }

    private func feed(_ asks: [AttentionAsk]) -> AttentionRow {
        AttentionRow(sessionID: "s", asks: .init(count: asks.count, items: asks))
    }

    // MARK: Which asks show

    func testAFeedThatWasNotReadHasNoCard() {
        XCTAssertTrue(AskCardRule.cards(feed: nil).isEmpty)
    }

    func testASessionWithNoOpenAskHasNoCard() {
        XCTAssertTrue(AskCardRule.cards(feed: feed([])).isEmpty)
    }

    func testAnAnsweredAskLeavesTheCards() {
        let before = AskCardRule.cards(feed: feed([ask("ask-1", at: 10), ask("ask-2", at: 20)]))
        XCTAssertEqual(before.map(\.id), ["ask-1", "ask-2"])

        // The daemon drops an answered ask from the feed, so the next read shows one card.
        let after = AskCardRule.cards(feed: feed([ask("ask-2", at: 20)]))
        XCTAssertEqual(after.map(\.id), ["ask-2"])
        XCTAssertTrue(AskCardRule.cards(feed: feed([])).isEmpty)
    }

    // MARK: The shelf

    func testTheShelfDrawsAtMostTwoCardsAndCountsTheRest() {
        func shelf(_ count: Int) -> AskShelf {
            AskCardRule.shelf(feed: feed((1...max(count, 1)).prefix(count).map { ask("ask-\($0)", at: $0) }))
        }
        XCTAssertEqual(shelf(0).cards.count, 0)
        XCTAssertNil(shelf(0).moreWords)
        XCTAssertEqual(shelf(1).cards.map(\.id), ["ask-1"])
        XCTAssertNil(shelf(1).moreWords)
        XCTAssertEqual(shelf(2).cards.map(\.id), ["ask-1", "ask-2"])
        XCTAssertNil(shelf(2).moreWords)
        XCTAssertEqual(shelf(3).cards.map(\.id), ["ask-1", "ask-2"], "the oldest two are drawn")
        XCTAssertEqual(shelf(3).moreWords, "1 more in the Inbox")
    }

    func testAnAskTheDaemonShedFromTheRowStillCounts() {
        // The row holds two items of the five the session has open.
        let row = AttentionRow(sessionID: "s", asks: .init(count: 5, items: [ask("ask-1", at: 1), ask("ask-2", at: 2)]))
        let shelf = AskCardRule.shelf(feed: row)
        XCTAssertEqual(shelf.cards.count, 2)
        XCTAssertEqual(shelf.moreWords, "3 more in the Inbox")
    }

    func testAFeedThatWasNotReadHasAnEmptyShelf() {
        XCTAssertEqual(AskCardRule.shelf(feed: nil), AskShelf(cards: [], more: 0))
    }

    // MARK: Order

    func testTheLongestWaitingAskIsFirstWhateverOrderTheFeedHasThem() {
        let asks = [ask("ask-c", at: 30), ask("ask-a", at: 10), ask("ask-b", at: 20)]
        XCTAssertEqual(AskCardRule.cards(feed: feed(asks)).map(\.id), ["ask-a", "ask-b", "ask-c"])
        XCTAssertEqual(AskCardRule.cards(feed: feed(asks.reversed())).map(\.id), ["ask-a", "ask-b", "ask-c"])
    }

    func testAsksRaisedTogetherAreOrderedByIdentity() {
        let asks = [ask("ask-b", at: 10), ask("ask-a", at: 10)]
        XCTAssertEqual(AskCardRule.cards(feed: feed(asks)).map(\.id), ["ask-a", "ask-b"])
    }

    // MARK: The head

    func testTheHeadSaysWhenTheAskWasRaisedAndWhoAsked() {
        let card = AskCardRule.cards(feed: feed([ask("ask-1", at: 1_795_178_430_000)]))[0]
        let utc = { (ms: Int) in ClockTime.words(ms, in: TimeZone(secondsFromGMT: 0)!) }
        XCTAssertEqual(AskCardRule.header(card, strand: "main", clock: utc), "Ask \u{00B7} waiting since 12:40 \u{00B7} main")
    }

    // MARK: Observers

    func testAnObserverIsOfferedTheQuestionsAndNoForm() throws {
        let record = try XCTUnwrap(AttentionRecord(JSONValue.parse(Data("""
        {"id":"ask-1","revision":1,"kind":"ask","status":"open","may_answer":false,
         "questions":[{"key":"q1","prompt":"Retry?","kind":"confirm"}]}
        """.utf8))))
        guard case .ask(let detail) = record.detail else { return XCTFail("not an ask") }
        XCTAssertEqual(
            AnswerRule.offer(ask: detail, status: record.status, isObserver: true, unsupported: false),
            .words("Only the owner or an operator can answer an ask.")
        )
        XCTAssertEqual(detail.questions.map { $0.prompt }, ["Retry?"], "the questions are still there to read")
    }

    // MARK: The mark on the asking turn

    private func user(_ id: String) -> TranscriptBlock {
        .row(TranscriptRow(id: id, kind: .user(text: "go", author: nil)))
    }

    private func said(_ id: String) -> TranscriptRow {
        TranscriptRow(id: id, kind: .assistant(text: "Which layout?"))
    }

    private func call(_ id: String, _ name: String) -> TranscriptRow {
        TranscriptRow(id: id, kind: .tool(name: name, arguments: .object([:]), result: "ok", isError: false))
    }

    func testAFoldedAskTurnMarksItsFold() {
        let blocks = TranscriptBlock.group([
            TranscriptRow(id: "u1", kind: .user(text: "go", author: nil)),
            said("a/0"), call("a/1", "ask"),
        ])
        let marked = AskCardRule.askingBlocks(in: blocks)
        XCTAssertEqual(marked, ["fold/a/0"])
    }

    func testAMessageAfterTheAskIsTheOneMarked() {
        let blocks = TranscriptBlock.group([
            TranscriptRow(id: "u1", kind: .user(text: "go", author: nil)),
            call("a/0", "ask"), said("a/1"),
        ])
        XCTAssertEqual(AskCardRule.askingBlocks(in: blocks), ["a/1"])
    }

    func testATurnWithoutAnAskIsNotMarked() {
        let blocks = TranscriptBlock.group([
            TranscriptRow(id: "u1", kind: .user(text: "go", author: nil)),
            call("a/0", "bash"), said("a/1"),
            TranscriptRow(id: "u2", kind: .user(text: "more", author: nil)),
            call("b/0", "ask"),
        ])
        XCTAssertEqual(AskCardRule.askingBlocks(in: blocks), ["fold/b/0"], "only the second turn asked")
    }
}
