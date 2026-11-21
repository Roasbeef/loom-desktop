import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// The worktree scan (`MissionKit/ReviewScan.swift`), which mirrors the web view's
/// `review_scan_rule.gleam`.
final class ReviewScanTests: XCTestCase {
    private typealias Candidate = (session: String, message: String)

    private func review(files: Int, repository: String = "head") -> ReviewRead {
        let one: JSONValue = [
            "path": "a.go", "change": "modified", "section": "source", "content": "text", "added": 1, "removed": 0,
            "hunks_omitted": 0, "extent": "whole", "hunks": [],
        ]
        return ReviewRead([
            "observed_at_ms": 1, "repository": .string(repository),
            "stat": ["files": .int(Int64(files)), "added": 3, "removed": 1], "omitted": 0, "extent": "whole",
            "files": .array(Array(repeating: one, count: files)),
        ])!
    }

    private func ids(_ set: Set<String>) -> [String] { set.sorted() }

    func testASessionNeverReadIsDueAndIsListedUnderReview() {
        let scan = ReviewScan()
        let candidates: [Candidate] = [("a", "done")]
        XCTAssertEqual(scan.due(candidates, now: 0)?.session, "a")
        XCTAssertEqual(ids(scan.reviewing(candidates)), ["a"])
        XCTAssertTrue(scan.isChecking("a", message: "done"))
    }

    func testOneReadIsOutAtATimeUntilItGoesStale() {
        var scan = ReviewScan()
        let candidates: [Candidate] = [("a", "m"), ("b", "m")]
        scan.started("a", message: "m", now: 0)
        XCTAssertNil(scan.due(candidates, now: 29_999))
        XCTAssertEqual(scan.due(candidates, now: 30_000)?.session, "b")
    }

    func testAChangedTreeStaysUnderReviewAndCarriesItsSize() {
        var scan = ReviewScan()
        scan.started("a", message: "m", now: 0)
        scan.answered("a", message: "m", read: .success(review(files: 2)))
        XCTAssertEqual(scan.stat("a", message: "m"), ReviewStat(files: 2, added: 3, removed: 1))
        XCTAssertEqual(ids(scan.reviewing([("a", "m")])), ["a"])
        XCTAssertNil(scan.due([("a", "m")], now: 1), "a message already read is not read again")
    }

    func testACleanTreeMovesToWaitingOnlyForTheMessageItWasReadAt() {
        var scan = ReviewScan()
        scan.answered("a", message: "m", read: .success(review(files: 0)))
        XCTAssertEqual(ids(scan.reviewing([("a", "m")])), [])
        XCTAssertNil(scan.stat("a", message: "m"))

        // A new message is read afresh, and until then the session is listed.
        XCTAssertEqual(ids(scan.reviewing([("a", "m2")])), ["a"])
        XCTAssertEqual(scan.due([("a", "m2")], now: 1)?.session, "a")

        // A message that returns to the read one is clean again at once.
        XCTAssertEqual(ids(scan.reviewing([("a", "m")])), [])
    }

    func testANonRepositoryHoldsNothingToReview() {
        var scan = ReviewScan()
        scan.answered("a", message: "m", read: .success(review(files: 0, repository: "not_repository")))
        XCTAssertEqual(ids(scan.reviewing([("a", "m")])), [])
    }

    func testAFailedReadIsTriedThreeTimesAndLeavesTheVerdictAlone() {
        var scan = ReviewScan()
        scan.answered("a", message: "m", read: .success(review(files: 1)))
        var now = 0
        for _ in 0..<3 {
            XCTAssertEqual(scan.due([("a", "m2")], now: now)?.session, "a")
            scan.started("a", message: "m2", now: now)
            scan.answered("a", message: "m2", read: .failure(.failed))
            now += 1
        }
        XCTAssertNil(scan.due([("a", "m2")], now: now), "out of tries")
        XCTAssertEqual(ids(scan.reviewing([("a", "m")])), ["a"], "the old verdict still stands for its message")
    }

    func testABusyRefusalCountsAsNoAttempt() {
        var scan = ReviewScan()
        for _ in 0..<5 {
            scan.started("a", message: "m", now: 0)
            scan.answered("a", message: "m", read: .failure(.busy))
        }
        XCTAssertEqual(scan.due([("a", "m")], now: 1)?.session, "a")
    }

    func testAForbiddenReadStopsThatSessionAndListsNoRowForIt() {
        var scan = ReviewScan()
        scan.started("a", message: "m", now: 0)
        scan.answered("a", message: "m", read: .failure(.forbidden))
        XCTAssertEqual(scan.forbidden, ["a"])
        XCTAssertNil(scan.due([("a", "m")], now: 1))
        XCTAssertEqual(ids(scan.reviewing([("a", "m")])), [])
    }

    func testAForbiddenSessionDoesNotStopTheOnesTheMemberMayRead() {
        // An observer on "c" may be an operator on "a": the daemon refuses per session.
        var scan = ReviewScan()
        let candidates: [Candidate] = [("c", "m"), ("a", "m")]
        scan.started("c", message: "m", now: 0)
        scan.answered("c", message: "m", read: .failure(.forbidden))

        XCTAssertEqual(scan.due(candidates, now: 1)?.session, "a")
        scan.started("a", message: "m", now: 1)
        scan.answered("a", message: "m", read: .success(review(files: 2)))
        XCTAssertEqual(ids(scan.reviewing(candidates)), ["a"])
        XCTAssertEqual(scan.stat("a", message: "m"), ReviewStat(files: 2, added: 3, removed: 1))
    }

    func testASessionWhoseEveryTryFailedIsUnreadableButStillListed() {
        var scan = ReviewScan()
        for _ in 0..<ReviewScan.maxAttempts {
            XCTAssertFalse(scan.isUnreadable("a", message: "m"))
            scan.started("a", message: "m", now: 0)
            scan.answered("a", message: "m", read: .failure(.failed))
        }
        XCTAssertTrue(scan.isUnreadable("a", message: "m"))
        XCTAssertFalse(scan.isUnreadable("a", message: "m2"), "a new message is tried afresh")
        XCTAssertEqual(ids(scan.reviewing([("a", "m")])), ["a"])
    }

    func testTheSessionWithTheFewestAttemptsGoesFirst() {
        var scan = ReviewScan()
        scan.started("a", message: "m", now: 0)
        scan.answered("a", message: "m", read: .failure(.failed))
        XCTAssertEqual(scan.due([("a", "m"), ("b", "m")], now: 1)?.session, "b")
    }

    func testFailureClassification() {
        XCTAssertEqual(ReviewScan.Failure(code: "forbidden", message: "x"), .forbidden)
        XCTAssertEqual(ReviewScan.Failure(code: "unavailable", message: ReviewScan.busyWords), .busy)
        XCTAssertEqual(ReviewScan.Failure(code: "unavailable", message: "boom"), .failed)
    }

    func testCandidatesAreIdleSessionsWithAMessage() {
        func thread(_ id: String, _ state: String, _ message: String?) -> InboxThread {
            var fields: [String: JSONValue] = ["session_id": .string(id), "state": .string(state)]
            if let message { fields["last_message"] = .string(message) }
            return InboxThread(id: id, name: id, activity: SessionActivity(.object(fields)))
        }
        let found = ReviewScan.candidates(threads: [
            thread("idle", "idle", "done"), thread("silent", "idle", nil), thread("blank", "idle", "  "),
            thread("busy", "working", "x"), thread("stuck", "needs_you", "x"),
        ])
        XCTAssertEqual(found.map(\.session), ["idle"])
    }
}
