import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// What a review stages and sends (`MissionKit/Outbox.swift`), which mirrors the web
/// view's `review_stage_rule`, `review_outbox_rule` and `review_pane`.
final class OutboxTests: XCTestCase {
    private let files = ["src/a.go", "src/b.go", "docs/c.md"]

    private func composed(_ outbox: ReviewOutbox) -> String? {
        if case .success(let text) = outbox.compose(files: files) { return text }
        return nil
    }

    func testNothingStagedHasNothingToSend() {
        var outbox = ReviewOutbox()
        XCTAssertFalse(outbox.hasStaged)
        XCTAssertEqual(outbox.compose(files: files), .failure(.nothingStaged))
        XCTAssertEqual(outbox.send(files: files), .halted)
        XCTAssertEqual(outbox.progress, .resting, "an empty Send says nothing and leaves no receipt")
    }

    func testChoosingTheStagedVerdictAgainTakesItBack() {
        var outbox = ReviewOutbox()
        outbox.toggle(.approve)
        XCTAssertEqual(outbox.verdict, .approve)
        outbox.toggle(.requestChanges)
        XCTAssertEqual(outbox.verdict, .requestChanges)
        outbox.toggle(.requestChanges)
        XCTAssertNil(outbox.verdict)
    }

    func testACommentIsTrimmedReplacedWhereItStoodAndTakenBackByEmptyText() {
        var outbox = ReviewOutbox()
        outbox.comment(files: files, path: "src/b.go", text: " wait \n")
        outbox.comment(files: files, path: "src/a.go", text: "cap it")
        outbox.comment(files: files, path: "src/b.go", text: "no, stop")
        XCTAssertEqual(outbox.comments.map(\.path), ["src/b.go", "src/a.go"])
        XCTAssertEqual(outbox.comments.first?.text, "no, stop")
        outbox.comment(files: files, path: "src/b.go", text: "   ")
        XCTAssertEqual(outbox.comments.map(\.path), ["src/a.go"])
    }

    func testACommentOnAFileTheReviewDoesNotHoldIsRefusedAndKeptOutOfTheStaging() {
        var outbox = ReviewOutbox()
        outbox.comment(files: files, path: "nope.go", text: "x")
        XCTAssertEqual(outbox.problem, "That file is not in this review.")
        XCTAssertFalse(outbox.hasStaged)
        outbox.comment(files: files, path: "src/a.go", text: String(repeating: "x", count: 4097))
        XCTAssertEqual(outbox.problem, "That note is over 4096 bytes. Shorten it.")
        outbox.comment(files: files, path: "src/a.go", text: "fine")
        XCTAssertNil(outbox.problem)
    }

    func testThePromptReadsAsTheWebWordsIt() {
        var outbox = ReviewOutbox()
        outbox.toggle(.requestChanges)
        outbox.comment(files: files, path: "docs/c.md", text: "Say why.")
        outbox.comment(files: files, path: "src/a.go", text: "The wait should cap at 30 s.")
        outbox.close(find: "find-3f9c01a2b4", revision: 4, outcome: .fixed, note: "Thanks, this is done.")
        outbox.close(find: "find-0000000001", revision: 2, outcome: .dismissed, note: "")
        XCTAssertEqual(composed(outbox), """
        I reviewed your changes. Verdict: changes requested.

        File comments:

        src/a.go:
        The wait should cap at 30 s.

        docs/c.md:
        Say why.

        Finds I closed:

        find-3f9c01a2b4: fixed. Thanks, this is done.
        find-0000000001: dismissed.
        """)
    }

    func testSectionsAppearOnlyWhenSomethingWasStagedForThem() {
        var outbox = ReviewOutbox()
        outbox.comment(files: files, path: "src/a.go", text: "hm")
        XCTAssertEqual(composed(outbox), "I reviewed your changes.\n\nFile comments:\n\nsrc/a.go:\nhm")
        var approve = ReviewOutbox()
        approve.toggle(.approve)
        XCTAssertEqual(composed(approve), "I reviewed your changes. Verdict: approved.")
        var comment = ReviewOutbox()
        comment.toggle(.comment)
        XCTAssertEqual(composed(comment), "I reviewed your changes. Verdict: comments only, no decision.")
    }

    func testACommentOnAFileThatLeftTheReviewRefusesThePrompt() {
        var outbox = ReviewOutbox()
        outbox.comment(files: files, path: "src/a.go", text: "hm")
        XCTAssertEqual(outbox.compose(files: ["src/b.go"]), .failure(.fileMissing))
    }

    func testAPromptPastTheBoundIsRefusedBeforeAnyCloseIsAsked() {
        var outbox = ReviewOutbox()
        for path in files { outbox.comment(files: files, path: path, text: String(repeating: "x", count: 4096)) }
        outbox.comment(files: files, path: "src/a.go", text: String(repeating: "y", count: 4096))
        outbox.close(find: "find-1", revision: 1, outcome: .fixed, note: String(repeating: "z", count: 4096))
        outbox.close(find: "find-2", revision: 1, outcome: .fixed, note: String(repeating: "z", count: 4096))
        XCTAssertEqual(outbox.send(files: files), .halted)
        guard case .settled(let receipt) = outbox.progress, case .notSent(let words) = receipt.prompt else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(words.hasPrefix("This review is "), words)
        XCTAssertTrue(words.hasSuffix("over the 16384 byte limit. Shorten a comment or a note."), words)
        XCTAssertEqual(receipt.closes, [])
        XCTAssertEqual(outbox.finds.map(\.standing), [.pending, .pending], "nothing was applied")
    }

    func testAFindNotReadCannotBeStaged() {
        var outbox = ReviewOutbox()
        outbox.close(find: "find-1", revision: nil, outcome: .fixed, note: "")
        XCTAssertEqual(outbox.problem, "That find has not been read yet, so it cannot be closed.")
        XCTAssertTrue(outbox.finds.isEmpty)
    }

    func testSendClosesEachFindInTheOrderStagedThenDeliversOnePrompt() {
        var outbox = ReviewOutbox()
        outbox.toggle(.approve)
        outbox.close(find: "find-1", revision: 3, outcome: .fixed, note: "")
        outbox.close(find: "find-2", revision: 5, outcome: .filed, note: "")
        XCTAssertEqual(outbox.send(files: files), .close(find: "find-1", revision: 3, outcome: .fixed))
        XCTAssertTrue(outbox.isSending)
        XCTAssertEqual(
            outbox.closed(ReviewCloseResult(find: "find-1", outcome: .fixed, isDone: true, words: "Closed as fixed.")),
            .close(find: "find-2", revision: 5, outcome: .filed)
        )
        let step = outbox.closed(ReviewCloseResult(find: "find-2", outcome: .filed, isDone: true, words: "Closed as filed."))
        guard case .prompt(let text) = step else { return XCTFail("expected the prompt") }
        XCTAssertTrue(text.contains("find-1: fixed.\nfind-2: filed."))
        outbox.prompted(.delivered("Delivered to build \u{00B7} admitted"))
        XCTAssertFalse(outbox.hasStaged, "a delivery empties the staging")
        guard case .settled(let receipt) = outbox.progress else { return XCTFail("expected a receipt") }
        XCTAssertEqual(receipt.lines, [
            "find-1 (fixed): Closed as fixed.", "find-2 (filed): Closed as filed.", "Delivered to build \u{00B7} admitted",
        ])
    }

    func testARefusedCloseHaltsTheSendDropsItsActionAndSendsNothing() {
        var outbox = ReviewOutbox()
        outbox.close(find: "find-1", revision: 3, outcome: .fixed, note: "")
        outbox.close(find: "find-2", revision: 5, outcome: .fixed, note: "")
        _ = outbox.send(files: files)
        _ = outbox.closed(ReviewCloseResult(find: "find-1", outcome: .fixed, isDone: true, words: "Closed as fixed."))
        let step = outbox.closed(ReviewCloseResult(find: "find-2", outcome: .fixed, isDone: false, words: "The find moved."))
        XCTAssertEqual(step, .halted)
        XCTAssertEqual(outbox.finds.map(\.id), ["find-1"], "the refused action is dropped and the applied one stays")
        guard case .settled(let receipt) = outbox.progress else { return XCTFail("expected a receipt") }
        XCTAssertEqual(receipt.prompt, .notSent("Nothing was sent to the agent."))
        XCTAssertEqual(receipt.closes.count, 2)
    }

    func testARefusedPromptKeepsTheStagingAndTheNextSendDoesNotCloseAgain() {
        var outbox = ReviewOutbox()
        outbox.close(find: "find-1", revision: 3, outcome: .fixed, note: "")
        _ = outbox.send(files: files)
        _ = outbox.closed(ReviewCloseResult(find: "find-1", outcome: .fixed, isDone: true, words: "Closed as fixed."))
        outbox.prompted(.refused("Not sent: the session is not running."))
        XCTAssertEqual(outbox.finds.map(\.standing), [.applied])

        // The action stands applied: a second close of the same find is not staged, and
        // the next Send goes straight to the prompt, which still says it was closed.
        outbox.close(find: "find-1", revision: 3, outcome: .dismissed, note: "")
        XCTAssertEqual(outbox.finds.first?.outcome, .fixed)
        guard case .prompt(let text) = outbox.send(files: files) else { return XCTFail("expected the prompt") }
        XCTAssertTrue(text.contains("find-1: fixed."))
    }

    func testNothingChangesWhileASendIsOut() {
        var outbox = ReviewOutbox()
        outbox.toggle(.approve)
        _ = outbox.send(files: files)
        outbox.toggle(.requestChanges)
        outbox.comment(files: files, path: "src/a.go", text: "late")
        outbox.clear()
        XCTAssertEqual(outbox.verdict, .approve)
        XCTAssertTrue(outbox.comments.isEmpty)
        XCTAssertEqual(outbox.send(files: files), .halted, "a second Send begins nothing")
    }

    func testStagingAfterAReceiptStartsFresh() {
        var outbox = ReviewOutbox()
        outbox.toggle(.approve)
        _ = outbox.send(files: files)
        outbox.prompted(.refused("Not sent: gone."))
        outbox.toggle(.comment)
        XCTAssertEqual(outbox.progress, .resting)
    }

    func testAFindsOwnNoteIsBoundedAndTrimmed() {
        var outbox = ReviewOutbox()
        outbox.close(find: "find-1", revision: 1, outcome: .fixed, note: String(repeating: "n", count: 4097))
        XCTAssertEqual(outbox.problem, "That note is over 4096 bytes. Shorten it.")
        outbox.close(find: "find-1", revision: 1, outcome: .fixed, note: "  ok  ")
        XCTAssertEqual(outbox.finds.first?.note, "ok")
    }
}
