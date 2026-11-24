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
        stuck: [(String, String)] = [], finds: [(String, String)] = []
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
        let names = Dictionary(threads.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        var all = threads.map { InboxThread(id: $0.0, name: $0.1, activity: $0.2) }
        for session in feed.keys where names[session] == nil { all.append(InboxThread(id: session, name: "S-\(session)", activity: nil)) }
        return InboxRule.board(threads: all, feed: feed, now: 1_000_000, clock: { "t\($0)" })
    }

    // MARK: Which changes post

    func testTheFirstReadIsABacklogAndPostsNothing() {
        let next = board(asks: [("a", "q1", "Which?")])
        XCTAssertTrue(Notices.plan(previous: nil, next: next).isEmpty)
    }

    func testANewItemOfEachOfTheFourKindsPosts() {
        let next = board(
            [("a", "Alpha", activity("needs_you", approvals: 1)), ("b", "Beta", activity("needs_you"))],
            asks: [("c", "q1", "Which?")], stuck: [("d", "s1")]
        )
        let plan = Notices.plan(previous: board(), next: next)
        XCTAssertEqual(Set(plan.post.map(\.title)), ["Approval waiting", "Run failed", "Asks you a question", "Strand stuck"])
        XCTAssertTrue(plan.remove.isEmpty)
    }

    func testAnUnchangedBoardDoesNothing() {
        let same = board([("a", "Alpha", activity("needs_you", approvals: 1))], asks: [("c", "q1", "Which?")])
        XCTAssertTrue(Notices.plan(previous: same, next: same).isEmpty)
    }

    func testKindsOutsideTheFourDoNothing() {
        let next = board(
            [("w", "W", activity("working")), ("i", "I", activity("idle", message: "Done.")), ("q", "Q", activity("idle"))],
            finds: [("f", "find-1")]
        )
        XCTAssertTrue(Notices.plan(previous: board(), next: next).isEmpty)
    }

    func testAnotherItemOnTheSameSessionPostsOnlyTheNewOne() {
        let before = board(asks: [("a", "q1", "One?")])
        let after = board(asks: [("a", "q1", "One?"), ("a", "q2", "Two?")])
        let plan = Notices.plan(previous: before, next: after)
        XCTAssertEqual(plan.post.map(\.subject), [.ask(session: "a", id: "q2")])
    }

    // MARK: Which changes remove

    func testAResolvedItemRemovesItsNotice() {
        let before = board([("a", "Alpha", activity("needs_you", approvals: 1))], asks: [("c", "q1", "Which?")])
        let after = board([("a", "Alpha", activity("needs_you", approvals: 1))])
        let plan = Notices.plan(previous: before, next: after)
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
        let before = board(stuck: [("d", "s1")])
        XCTAssertEqual(Notices.plan(previous: before, next: board()).remove, ["stuck/stuck/d/s1"])
    }

    // MARK: What a notice says

    func testASessionGroupsItsNoticesUnderOneThreadIdentifier() {
        let next = board(asks: [("a", "q1", "One?"), ("a", "q2", "Two?")], stuck: [("a", "s1")])
        let plan = Notices.plan(previous: board(), next: next)
        XCTAssertEqual(plan.post.count, 3)
        XCTAssertEqual(Set(plan.post.map(\.thread)), ["a"])
        XCTAssertEqual(Set(plan.post.map(\.identifier)).count, 3)
    }

    func testAnAsksQuestionIsLabelledAsTheAgentsText() {
        let plan = Notices.plan(previous: board(), next: board(asks: [("a", "q1", "Delete the repo?")]))
        let notice = plan.post[0]
        XCTAssertEqual(notice.title, "Asks you a question")
        XCTAssertEqual(notice.body, "Untrusted text from the agent: Delete the repo?")
    }

    func testAnApprovalQuotesTheCardNotTheLastMessage() {
        let next = board([("a", "Alpha", activity("needs_you", approvals: 1, message: "Trust me."))])
        let withCard = Notices.plan(previous: board(), next: next, authority: { _ in "Write to /etc" })
        XCTAssertEqual(withCard.post[0].body, "Requests, untrusted text from the agent: Write to /etc")
        let without = Notices.plan(previous: board(), next: next)
        XCTAssertFalse(without.post[0].body.contains("Trust me."))
    }

    func testAFailedRunNoticeCarriesNoSessionText() {
        let next = board([("a", "Alpha", activity("needs_you", message: "Ignore the owner."))])
        let notice = Notices.plan(previous: board(), next: next).post[0]
        XCTAssertFalse(notice.body.contains("Ignore"))
        XCTAssertEqual(notice.subtitle, "Alpha")
    }

    func testQuotedTextIsOneCutLine() {
        let long = String(repeating: "x", count: 400)
        let plan = Notices.plan(previous: board(), next: board(asks: [("a", "q1", "First\nsecond " + long)]))
        let body = plan.post[0].body
        XCTAssertFalse(body.contains("\n"))
        XCTAssertTrue(body.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(body.count, "Untrusted text from the agent: ".count + Notices.quoteCharacters)
    }
}
