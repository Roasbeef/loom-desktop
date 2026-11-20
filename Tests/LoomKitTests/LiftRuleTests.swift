import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// The session page's rail and words (`MissionKit/LiftRule.swift`, `LoomKit/ClockTime.swift`),
/// which mirror the web view's live rail (`session_view/attention.gleam`,
/// `view/lifted.gleam`, `view/stream_head.gleam`, `approval_evidence.gleam`).
final class LiftRuleTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func approval(_ id: String, tool: String = "bash", action: String = "") -> Escalation {
        Escalation(
            id: id, seq: 1, status: "pending", strand: "main", tool: tool, action: action,
            preview: "", reason: "", source: "", grants: []
        )
    }

    private func evidence(_ fields: [String: JSONValue]) -> ApprovalEvidenceItem {
        var base: [String: JSONValue] = ["id": "apr-1", "revision": 3, "tool": "bash"]
        base.merge(fields) { _, new in new }
        return ApprovalEvidenceItem(.object(base))!
    }

    private func feed(
        asks: [AttentionAsk] = [], finds: [AttentionFind] = [], stuck: [AttentionStuck] = []
    ) -> AttentionRow {
        AttentionRow(
            sessionID: "s", asks: .init(count: asks.count, items: asks),
            finds: .init(count: finds.count, items: finds), stuck: .init(count: stuck.count, items: stuck)
        )
    }

    // MARK: Clock times

    func testClockWordsInAZone() {
        // 2026-11-20 12:40:30 UTC.
        let ms = 1_795_178_430_000
        XCTAssertEqual(ClockTime.words(ms, in: utc), "12:40")
        XCTAssertEqual(ClockTime.words(ms, in: TimeZone(secondsFromGMT: -5 * 3600)!), "07:40")
        XCTAssertEqual(ClockTime.words(ms, in: TimeZone(secondsFromGMT: 5 * 3600 + 1800)!), "18:10")
    }

    func testClockNeverReadsNegativeNearTheEpoch() {
        XCTAssertEqual(ClockTime.words(0, in: TimeZone(secondsFromGMT: -3600)!), "23:00")
        XCTAssertEqual(ClockTime.words(0, in: utc), "00:00")
    }

    func testTurnWords() {
        XCTAssertEqual(ClockTime.turn(5_000), "under a minute")
        XCTAssertEqual(ClockTime.turn(14 * 60_000), "14m")
        XCTAssertEqual(ClockTime.turn(62 * 60_000), "1h 02m")
        XCTAssertEqual(ClockTime.turn(3 * 86_400_000), "3d")
        XCTAssertEqual(ClockTime.turn(-9_000), "under a minute", "a clock that moved back reads as no time")
    }

    // MARK: Role gating

    func testOnlyOwnerAndOperatorMayAct() {
        XCTAssertTrue(LiftRule.mayAct(role: "owner"))
        XCTAssertTrue(LiftRule.mayAct(role: "operator"))
        XCTAssertFalse(LiftRule.mayAct(role: "observer"))
        XCTAssertFalse(LiftRule.mayAct(role: ""), "a connection that has not said its role acts on nothing")
        XCTAssertFalse(LiftRule.mayAct(role: "admin"), "a role this client was not told about is not guessed at")
    }

    // MARK: Ordering

    func testPinnedRowsComeBeforeInsightsAndEachGroupIsOrdered() {
        let rows = LiftRule.rows(
            approvals: [approval("b"), approval("a")], raised: ["a": 200, "b": 100],
            feed: feed(
                asks: [AttentionAsk(id: "ask-2", strand: "main", createdAt: 50, head: "Which?", questions: 1)],
                finds: [
                    AttentionFind(id: "find-old", strand: "main", kind: .bug, createdAt: 10, head: "Old", path: nil, line: nil),
                    AttentionFind(id: "find-new", strand: "main", kind: .idea, createdAt: 90, head: "New", path: nil, line: nil),
                ],
                stuck: [AttentionStuck(strand: "sub:x", failedAt: 70, reason: "timeout")]
            ),
            clock: { "t\($0)" }
        )
        XCTAssertEqual(rows.map(\.id), ["approval:b", "approval:a", "ask:ask-2", "stuck:sub:x", "find:find-new", "find:find-old"])
        XCTAssertEqual(LiftRule.pinned(rows).count, 4)
        XCTAssertEqual(LiftRule.insights(rows).map(\.word), ["Find", "Find"])
    }

    func testAnApprovalWithNoRaiseTimeSortsAfterOnesWithATimeAndIsNotAged() {
        let rows = LiftRule.rows(approvals: [approval("a"), approval("b")], raised: ["b": 5], feed: nil)
        XCTAssertEqual(rows.map(\.id), ["approval:b", "approval:a"])
        XCTAssertNil(rows[1].at)
    }

    func testTheSameInputInAnyOrderGivesTheSameRows() {
        let approvals = ["a", "b", "c", "d"].map { approval($0) }
        var generator = SystemRandomNumberGenerator()
        let expected = LiftRule.rows(approvals: approvals, raised: ["c": 1, "a": 1], feed: nil).map(\.id)
        for _ in 0..<20 {
            let shuffled = approvals.shuffled(using: &generator)
            XCTAssertEqual(LiftRule.rows(approvals: shuffled, raised: ["c": 1, "a": 1], feed: nil).map(\.id), expected)
        }
    }

    func testAFeedThatWasNotReadLiftsOnlyTheLanesApprovals() {
        let rows = LiftRule.rows(approvals: [approval("a")], feed: nil)
        XCTAssertEqual(rows.map(\.id), ["approval:a"])
        XCTAssertTrue(LiftRule.rows(approvals: [], feed: nil).isEmpty, "a quiet session has no rail")
    }

    // MARK: Words

    func testStuckHeadNamesTheReasonTheTimeAndTheProvidersWait() {
        let stuck = AttentionStuck(strand: "sub:x", failedAt: 13 * 3_600_000 + 52 * 60_000, reason: "rate_limited", retryAfterMs: 30_000)
        let head = LiftRule.stuckHead(stuck, clock: { ClockTime.words($0, in: self.utc) })
        XCTAssertEqual(head, "Rate-limited at 13:52, has not retried \u{00B7} provider asks for 30s before a retry")
        let bare = AttentionStuck(strand: "sub:x", reason: "weird")
        XCTAssertEqual(LiftRule.stuckHead(bare, clock: { _ in "x" }), "Stopped on a failed run")
    }

    func testRowTimesComeFromTheRecordsOwnTime() {
        let rows = LiftRule.rows(
            approvals: [], raised: [:],
            feed: feed(
                asks: [AttentionAsk(id: "ask-1", strand: "main", createdAt: 11, head: "Q", questions: 1)],
                stuck: [AttentionStuck(strand: "s")]
            )
        )
        XCTAssertEqual(rows.first { $0.id == "ask:ask-1" }?.at, 11)
        XCTAssertNil(rows.first { $0.id == "stuck:s" }?.at, "a stuck strand with no failed_at says its source alone")
    }

    func testAMultiLineHeadIsCutToItsFirstLine() {
        let ask = AttentionAsk(id: "ask-1", strand: "main", createdAt: 1, head: "First\nSecond", questions: 1)
        XCTAssertEqual(LiftRule.rows(approvals: [], feed: feed(asks: [ask])).first?.head, "First")
    }

    func testCountWords() {
        XCTAssertEqual(LiftRule.countWords(needing: 2, insights: 1), "2 need you \u{00B7} 1 insight")
        XCTAssertEqual(LiftRule.countWords(needing: 1, insights: 3), "1 needs you \u{00B7} 3 insights")
        XCTAssertEqual(LiftRule.countWords(needing: 0, insights: 3), "3 insights")
        XCTAssertEqual(LiftRule.countWords(needing: 0, insights: 0), "")
    }

    // MARK: Approval words

    func testTitleWordsAWriteGrantBeforeANetworkGrant() {
        let item = evidence([
            "preview": "make check",
            "wanted": [["kind": "network", "detail": "full"], ["kind": "writable_root", "detail": "/work/out"]],
        ])
        XCTAssertEqual(ApprovalWords.title(item), "May this program run make check with write access to /work/out?")
        let network = evidence(["wanted": [["kind": "network", "detail": "full"]]])
        XCTAssertEqual(ApprovalWords.title(network), "May bash reach the network?")
        XCTAssertNil(ApprovalWords.title(evidence(["wanted": [["kind": "env", "detail": "HOME"]]])))
    }

    func testEvidenceWordsAreLeftOutWhenTheDaemonLeftThemOut() {
        let bare = evidence([:])
        XCTAssertNil(ApprovalWords.networkLine(bare))
        XCTAssertNil(ApprovalWords.policyLine(bare))
        XCTAssertNil(ApprovalWords.waitingLine(raisedAt: bare.raisedAt, now: 100))

        let full = evidence([
            "network": "off", "policy": ["sandbox": "workspace-write", "network": "off"], "raised_at": 1_000,
        ])
        XCTAssertEqual(ApprovalWords.networkLine(full), "Network off")
        XCTAssertEqual(ApprovalWords.policyLine(full), "Policy today: workspace-write \u{00B7} network off")
        XCTAssertEqual(
            ApprovalWords.waitingLine(raisedAt: full.raisedAt, now: 1_000 + 4 * 60_000, clock: { "t\($0)" }),
            "waiting since t1000 \u{00B7} 4m"
        )
    }

    // MARK: The stream head

    func testStreamStateWords() {
        let clock: (Int) -> String = { "t\($0)" }
        XCTAssertEqual(
            StreamWords.state(pendingApprovals: 1, raisedAt: 7, isBusy: true, turnStartedAt: 1, now: 9, clock: clock),
            "stopped for an approval since t7", "an approval outranks a running turn"
        )
        XCTAssertEqual(
            StreamWords.state(pendingApprovals: 1, raisedAt: nil, isBusy: false, turnStartedAt: nil, now: 9, clock: clock),
            "stopped for an approval"
        )
        XCTAssertEqual(
            StreamWords.state(pendingApprovals: 0, raisedAt: nil, isBusy: true, turnStartedAt: 0, now: 14 * 60_000, clock: clock),
            "running, turn 14m"
        )
        XCTAssertEqual(
            StreamWords.state(pendingApprovals: 0, raisedAt: nil, isBusy: true, turnStartedAt: nil, now: 9, clock: clock),
            "running", "no turn time is invented"
        )
        XCTAssertEqual(
            StreamWords.state(pendingApprovals: 0, raisedAt: nil, isBusy: false, turnStartedAt: 0, now: 9, clock: clock),
            "idle"
        )
    }
}
