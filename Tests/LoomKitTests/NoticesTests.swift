import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// The notifier's decision (`MissionKit/Notices.swift`): which board changes become
/// a notification, which remove one, and what a notice says.
final class NoticesTests: XCTestCase {
    // MARK: Builders

    private func activity(_ state: String, approvals: Int = 0, message: String? = nil) -> SessionActivity {
        var fields: [String: JSONValue] = ["session_id": "x", "state": .string(state), "approvals": .int(Int64(approvals))]
        if let message { fields["last_message"] = .string(message) }
        return SessionActivity(.object(fields))!
    }

    private func board(
        _ threads: [(String, String, SessionActivity)] = [], asks: [(String, String, String)] = [],
        stuck: [(String, String)] = [], finds: [(String, String)] = [], unchecked: Set<String> = []
    ) -> InboxBoard {
        var feed: [String: AttentionRow] = [:]
        for (session, _, _) in threads { feed[session] = AttentionRow(sessionID: session) }
        for session in Set(asks.map(\.0) + stuck.map(\.0) + finds.map(\.0)) {
            let own = asks.filter { $0.0 == session }.map {
                AttentionAsk(id: $0.1, strand: "main", createdAt: 1, head: $0.2, questions: 1)
            }
            let held = stuck.filter { $0.0 == session }.map {
                AttentionStuck(strand: $0.1, failedAt: nil, reason: "rate_limited", retryAfterMs: nil, parent: nil)
            }
            let noticed = finds.filter { $0.0 == session }.map {
                AttentionFind(id: $0.1, strand: "main", kind: .bug, createdAt: 1, head: "Noticed", path: nil, line: nil)
            }
            feed[session] = AttentionRow(
                sessionID: session, asks: .init(count: own.count, items: own),
                finds: .init(count: noticed.count, items: noticed), stuck: .init(count: held.count, items: held)
            )
        }
        for session in unchecked { feed[session] = nil }
        let all = threads.map { InboxThread(id: $0.0, name: $0.1, activity: $0.2) }
        return InboxRule.board(threads: all, feed: feed, now: 1_000_000, clock: { "t\($0)" })
    }

    /// The board of these sessions working with nothing asked, each feed read.
    private func calm(_ ids: String...) -> InboxBoard {
        board(ids.map { ($0, "N-\($0)", activity("working")) })
    }

    // MARK: Which changes post

    func testTheEmptyBoardPostsNothingForABacklog() {
        let next = board([("a", "Alpha", activity("needs_you", approvals: 1))], asks: [("a", "q1", "Which?")])
        XCTAssertTrue(Notices.plan(previous: .empty, next: next).isEmpty)
    }

    func testANewItemOfEachOfTheFourKindsPosts() {
        let before = board([
            ("a", "Alpha", activity("working")), ("b", "Beta", activity("working")),
            ("c", "Gamma", activity("working")), ("d", "Delta", activity("working")),
        ])
        let next = board(
            [("a", "Alpha", activity("needs_you", approvals: 1)), ("b", "Beta", activity("needs_you")),
             ("c", "Gamma", activity("working")), ("d", "Delta", activity("working"))],
            asks: [("c", "q1", "Which?")], stuck: [("d", "s1")]
        )
        let plan = Notices.plan(previous: before, next: next)
        XCTAssertEqual(Set(plan.post.map(\.title)), ["Approval waiting", "Run failed", "Asks you a question", "Strand stuck"])
        XCTAssertTrue(plan.remove.isEmpty)
    }

    func testAnUnchangedBoardDoesNothing() {
        let same = board([("a", "Alpha", activity("needs_you", approvals: 1))], asks: [("a", "q1", "Which?")])
        XCTAssertTrue(Notices.plan(previous: same, next: same).isEmpty)
    }

    func testKindsOutsideTheFourDoNothing() {
        let threads = [("w", "W", activity("working")), ("i", "I", activity("idle", message: "Done.")), ("q", "Q", activity("idle"))]
        let plan = Notices.plan(previous: board(threads), next: board(threads, finds: [("w", "find-1")]))
        XCTAssertTrue(plan.isEmpty)
    }

    func testASessionANewDaemonBringsPostsNoBacklog() {
        let before = calm("a")
        let next = board(
            [("a", "Alpha", activity("working")), ("z", "Zed", activity("needs_you", approvals: 1))],
            asks: [("z", "q1", "Which?")], stuck: [("z", "s1")]
        )
        XCTAssertTrue(Notices.plan(previous: before, next: next).isEmpty)
    }

    func testAnAskSeenBeforeTheSessionsFirstFeedReadIsBacklog() {
        let before = board([("a", "Alpha", activity("working"))], unchecked: ["a"])
        let next = board([("a", "Alpha", activity("working"))], asks: [("a", "q1", "Which?")], stuck: [("a", "s1")])
        XCTAssertTrue(Notices.plan(previous: before, next: next).post.isEmpty)
    }

    func testAnApprovalNeedsNoFeedReadToBeNews() {
        let before = board([("a", "Alpha", activity("working"))], unchecked: ["a"])
        let next = board([("a", "Alpha", activity("needs_you", approvals: 1))], unchecked: ["a"])
        XCTAssertEqual(Notices.plan(previous: before, next: next).post.map(\.title), ["Approval waiting"])
    }

    func testAnotherItemOnTheSameSessionPostsOnlyTheNewOne() {
        let t = [("a", "Alpha", activity("working"))]
        let before = board(t, asks: [("a", "q1", "One?")])
        let after = board(t, asks: [("a", "q1", "One?"), ("a", "q2", "Two?")])
        let plan = Notices.plan(previous: before, next: after)
        XCTAssertEqual(plan.post.map(\.subject), [.ask(session: "a", id: "q2")])
    }

    // MARK: Which changes remove

    func testAResolvedItemRemovesItsNotice() {
        let t = [("a", "Alpha", activity("needs_you", approvals: 1)), ("c", "Gamma", activity("working"))]
        let plan = Notices.plan(previous: board(t, asks: [("c", "q1", "Which?")]), next: board(t))
        XCTAssertEqual(plan.remove, ["ask/ask/c/q1"])
        XCTAssertTrue(plan.post.isEmpty)
    }

    func testAnApprovalThatBecomesWorkingIsRemoved() {
        let before = board([("a", "Alpha", activity("needs_you", approvals: 1))])
        let after = board([("a", "Alpha", activity("working"))])
        XCTAssertEqual(Notices.plan(previous: before, next: after).remove, ["approval/session/a"])
    }

    func testAnApprovalThatBecomesAFailedRunSwapsNotices() {
        let before = board([("a", "Alpha", activity("needs_you", approvals: 1))])
        let after = board([("a", "Alpha", activity("needs_you"))])
        let plan = Notices.plan(previous: before, next: after)
        XCTAssertEqual(plan.remove, ["approval/session/a"])
        XCTAssertEqual(plan.post.map(\.identifier), ["failed/session/a"])
    }

    func testAStuckStrandThatIsRetriedIsRemoved() {
        let t = [("d", "Delta", activity("working"))]
        XCTAssertEqual(Notices.plan(previous: board(t, stuck: [("d", "s1")]), next: board(t)).remove, ["stuck/stuck/d/s1"])
    }

    // MARK: What a notice says

    func testASessionGroupsItsNoticesUnderOneThreadIdentifier() {
        let t = [("a", "Alpha", activity("working"))]
        let next = board(t, asks: [("a", "q1", "One?"), ("a", "q2", "Two?")], stuck: [("a", "s1")])
        let plan = Notices.plan(previous: board(t), next: next)
        XCTAssertEqual(plan.post.count, 3)
        XCTAssertEqual(Set(plan.post.map(\.thread)), ["a"])
        XCTAssertEqual(Set(plan.post.map(\.identifier)).count, 3)
    }

    func testAnAsksQuestionIsLabelledAsTheAgentsText() {
        let t = [("a", "Alpha", activity("working"))]
        let notice = Notices.plan(previous: board(t), next: board(t, asks: [("a", "q1", "Delete the repo?")])).post[0]
        XCTAssertEqual(notice.title, "Asks you a question")
        XCTAssertEqual(notice.body, "Untrusted text from the agent: Delete the repo?")
    }

    func testAnApprovalBodyIsFixedAndQuotesNothing() {
        let before = board([("a", "Alpha", activity("working"))])
        let next = board([("a", "Alpha", activity("needs_you", approvals: 1, message: "Trust me."))])
        let body = Notices.plan(previous: before, next: next).post[0].body
        XCTAssertEqual(body, "Open the thread to read what it asks for.")
    }

    func testAFailedRunNoticeCarriesNoSessionText() {
        let before = board([("a", "Alpha", activity("working"))])
        let next = board([("a", "Alpha", activity("needs_you", message: "Ignore the owner."))])
        let notice = Notices.plan(previous: before, next: next).post[0]
        XCTAssertFalse(notice.body.contains("Ignore"))
        XCTAssertEqual(notice.subtitle, "Alpha")
    }

    func testQuotedTextIsOneCutLine() {
        let t = [("a", "Alpha", activity("working"))]
        let long = String(repeating: "x", count: 400)
        let plan = Notices.plan(previous: board(t), next: board(t, asks: [("a", "q1", "First\nsecond " + long)]))
        let body = plan.post[0].body
        XCTAssertFalse(body.contains("\n"))
        XCTAssertTrue(body.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(body.count, "Untrusted text from the agent: ".count + Notices.quoteCharacters)
    }

    func testQuotedTextShowsControlAndBidiScalars() {
        let quoted = Notices.quote("pay\u{202E}evil\u{8}\u{7F}")
        XCTAssertEqual(quoted, "pay\\u{202E}evil\\u{8}\\u{7F}")
    }

    // MARK: The feed a read keeps

    func testAResidentSessionTheReadOmittedKeepsItsRow() {
        let old = AttentionRow(sessionID: "a")
        let other = AttentionRow(sessionID: "b")
        let kept = InboxRule.keptFeed(previous: ["a": old, "gone": old], read: ["b": other], resident: ["a", "b"])
        XCTAssertEqual(Set(kept.keys), ["a", "b"])
    }
}
