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

    func testAnAnsweredAskLeavesTheCardsAndAnOpenOneStays() {
        let first = ask("ask-1", at: 10, head: "Which layout?")
        let second = ask("ask-2", at: 20, head: "Retry?")
        XCTAssertEqual(AskCardRule.cards(feed: feed([first, second])).map(\.id), ["ask-1", "ask-2"])

        // The daemon drops an answered ask from the feed, so the next read shows only the open one.
        let after = AskCardRule.cards(feed: feed([second]))
        XCTAssertFalse(after.contains { $0.id == "ask-1" }, "the answered ask is gone")
        XCTAssertEqual(after, [AskCard(id: "ask-2", strand: "main", since: 20, head: "Retry?", questions: 2)], "the open ask stays whole")
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

    private func record(mayAnswer: Bool) throws -> AttentionRecord.Ask {
        let record = try XCTUnwrap(AttentionRecord(JSONValue.parse(Data("""
        {"id":"ask-1","revision":1,"kind":"ask","status":"open","may_answer":\(mayAnswer),
         "questions":[{"key":"q1","prompt":"Retry?","kind":"confirm"}]}
        """.utf8))))
        guard case .ask(let detail) = record.detail else { throw XCTSkip("not an ask") }
        return detail
    }

    func testTheConnectionsRoleAloneMakesAnObserverReadOnly() throws {
        // The daemon says the owner may answer, and the connection is still an observer.
        let detail = try record(mayAnswer: true)
        XCTAssertEqual(
            AnswerRule.offer(ask: detail, status: "open", isObserver: true, unsupported: false),
            .words("Only the owner or an operator can answer an ask.")
        )
        XCTAssertEqual(AnswerRule.offer(ask: detail, status: "open", isObserver: false, unsupported: false), .form)
        XCTAssertEqual(detail.questions.map { $0.prompt }, ["Retry?"], "the questions are still there to read")
    }

    func testTheDaemonsMayAnswerAloneMakesAnAskReadOnly() throws {
        let detail = try record(mayAnswer: false)
        XCTAssertEqual(
            AnswerRule.offer(ask: detail, status: "open", isObserver: false, unsupported: false),
            .words("Only the owner or an operator can answer an ask.")
        )
    }

    // MARK: The mark on the asking turn

    private func user(_ id: String) -> TranscriptBlock {
        .row(TranscriptRow(id: id, kind: .user(text: "go", author: nil)))
    }

    private func user0() -> TranscriptRow { TranscriptRow(id: "u0", kind: .user(text: "go", author: nil)) }

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

    func testAMessageAfterTheAskIsTheSummaryAndIsNotMarked() {
        let blocks = TranscriptBlock.group([
            TranscriptRow(id: "u1", kind: .user(text: "go", author: nil)),
            call("a/0", "ask"), said("a/1"),
        ])
        XCTAssertEqual(AskCardRule.askingBlocks(in: blocks), ["fold/a/0"])
    }

    func testTheMessageBeforeTheCallIsMarkedWhenItIsNotFolded() {
        // Prose followed by no work stays outside the fold, so a turn whose only work is
        // the call after it has the message before the fold.
        let blocks: [TranscriptBlock] = [
            user("u1"), .row(said("a/0")),
            .fold(Fold(id: "fold/a/1", rows: [call("a/1", "ask")], startedAt: nil, endedAt: nil, isLive: false)),
        ]
        XCTAssertEqual(AskCardRule.askingBlocks(in: blocks), ["a/0"])
    }

    func testAnAskToAStrandIsNotMarked() {
        let toStrand = TranscriptRow(id: "a/0", kind: .tool(name: "ask", arguments: ["to": "build"], result: "ok", isError: false))
        let blocks = TranscriptBlock.group([TranscriptRow(id: "u1", kind: .user(text: "go", author: nil)), toStrand])
        XCTAssertTrue(AskCardRule.askingBlocks(in: blocks).isEmpty)
    }

    func testAnAskFromACodeModeProgramIsMarked() {
        let program = TranscriptRow(
            id: "a/0", kind: .tool(name: "code_mode", arguments: ["program": "attention.ask([attention.confirm(\"Go?\")], to: None, why: None)"], result: "ok", isError: false)
        )
        let other = TranscriptRow(id: "b/0", kind: .tool(name: "code_mode", arguments: ["program": "fs.read(\"x\")"], result: "ok", isError: false))
        XCTAssertEqual(AskCardRule.askingBlocks(in: TranscriptBlock.group([user0(), program])), ["fold/a/0"])
        XCTAssertTrue(AskCardRule.askingBlocks(in: TranscriptBlock.group([user0(), other])).isEmpty)
    }

    func testEveryKindOfTurnOpenerEndsTheTurnBefore() {
        let kinds: [TranscriptRow.Kind] = [
            .peer(session: "s", strand: "main", text: "hi"),
            .sibling(strand: "build", text: "hi", trailer: nil),
            .advisor(frame: .advice, body: "hi"),
        ]
        for kind in kinds {
            let blocks = TranscriptBlock.group([
                TranscriptRow(id: "u1", kind: .user(text: "go", author: nil)), said("a/0"),
                TranscriptRow(id: "o", kind: kind), call("b/0", "ask"),
            ])
            XCTAssertEqual(AskCardRule.askingBlocks(in: blocks), ["fold/b/0"], "the message before \(kind) belongs to the turn before it")
        }
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
