import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// The reading pane's words and read plan (`MissionKit/ThreadRule.swift`), which mirror
/// the web view's `thread_words.gleam`, `brief_rule.gleam`, `thread_send.gleam` and the
/// approval title in `view/attention_thread.gleam`.
final class ThreadRuleTests: XCTestCase {
    private func clock(_ ms: Int) -> String { "t\(ms)" }

    private func activity(_ state: String, approvals: Int = 0, message: String? = nil) -> SessionActivity {
        var fields: [String: JSONValue] = ["session_id": "x", "state": .string(state), "approvals": .int(Int64(approvals))]
        if let message { fields["last_message"] = .string(message) }
        return SessionActivity(.object(fields))!
    }

    private func row(of activity: SessionActivity?, reviewing: Set<String> = []) -> InboxRow {
        InboxRule.rows(threads: [InboxThread(id: "x", name: "n", activity: activity)], feed: [:], reviewing: reviewing, now: 0)[0]
    }

    private func feedRow(ask: Bool = false, find: Bool = false, stuck: Bool = false) -> InboxRow {
        let body: JSONValue = .object([
            "session_id": "x", "state": "ok",
            "asks": ask ? ["count": 1, "items": [["id": "a1", "strand": "main", "created_at": 5, "head": "q", "questions": 1]]] : ["count": 0, "items": []],
            "finds": find ? ["count": 1, "items": [["id": "f1", "strand": "main", "kind": "risk", "created_at": 5, "head": "h"]]] : ["count": 0, "items": []],
            "stuck": stuck ? ["count": 1, "items": [["strand": "s1", "failed_at": 5, "reason": "rate_limited"]]] : ["count": 0, "items": []],
        ])
        let feed = AttentionRow(body)!
        let rows = InboxRule.rows(threads: [InboxThread(id: "x", name: "n", activity: nil)], feed: ["x": feed], now: 10)
        return rows[0]
    }

    // MARK: Which reads fire

    func testApprovalThreadReadsEvidenceAndBrief() {
        let reads = ThreadRule.reads(for: row(of: activity("needs_you", approvals: 1)))
        XCTAssertEqual(reads, ThreadReads(approval: true, brief: true, record: nil))
    }

    func testIdleAndWorkingThreadsReadOnlyTheBrief() {
        XCTAssertEqual(ThreadRule.reads(for: row(of: activity("idle", message: "done"))), ThreadReads(approval: false, brief: true, record: nil))
        XCTAssertEqual(ThreadRule.reads(for: row(of: activity("working"))), ThreadReads(approval: false, brief: true, record: nil))
        XCTAssertEqual(ThreadRule.reads(for: row(of: activity("idle", message: "done"), reviewing: ["x"])).brief, true)
    }

    func testOnlyAReviewThreadReadsTheWorktree() {
        let reviewing = ThreadRule.reads(for: row(of: activity("idle", message: "done"), reviewing: ["x"]))
        XCTAssertEqual(reviewing, ThreadReads(approval: false, brief: true, record: nil, review: true))
        XCTAssertFalse(ThreadRule.reads(for: row(of: activity("idle", message: "done"))).review)
        XCTAssertFalse(ThreadRule.reads(for: row(of: activity("working"))).review)
        XCTAssertFalse(ThreadRule.reads(for: row(of: activity("needs_you", approvals: 1))).review)
    }

    func testFailedAndQuietThreadsReadNothing() {
        XCTAssertEqual(ThreadRule.reads(for: row(of: activity("needs_you"))), .none)
        XCTAssertEqual(ThreadRule.reads(for: row(of: activity("idle"))), .none)
    }

    func testAskReadsRecordAndBriefFindReadsRecordStuckReadsNothing() {
        XCTAssertEqual(ThreadRule.reads(for: feedRow(ask: true)), ThreadReads(approval: false, brief: true, record: "a1"))
        XCTAssertEqual(ThreadRule.reads(for: feedRow(find: true)), ThreadReads(approval: false, brief: false, record: "f1"))
        XCTAssertEqual(ThreadRule.reads(for: feedRow(stuck: true)), .none)
    }

    // MARK: Brief pacing, ported from brief_rule_test

    func testBriefDue() {
        XCTAssertTrue(ThreadRule.briefDue(last: nil, now: 0, since: 0))
        XCTAssertFalse(ThreadRule.briefDue(last: BriefRead(started: 0, since: 0), now: 14_999, since: 0))
        XCTAssertTrue(ThreadRule.briefDue(last: BriefRead(started: 0, since: 0), now: 15_000, since: 0))
        XCTAssertTrue(ThreadRule.briefDue(last: BriefRead(started: 0, since: 0), now: 1, since: 7))
    }

    func testReviewWordsSayWhenTheWorktreeCouldNotBeRead() {
        let stat = ReviewStat(files: 1, added: 2, removed: 3)
        XCTAssertEqual(ThreadRule.reviewWords(stat: stat, isUnreadable: false, finds: 0), "+2 \u{2212}3, 1 file")
        XCTAssertEqual(ThreadRule.reviewWords(stat: nil, isUnreadable: false, finds: 0), "Checking the worktree\u{2026}")
        XCTAssertEqual(ThreadRule.reviewWords(stat: nil, isUnreadable: true, finds: 0), "The worktree could not be read.")
    }

    func testAReviewThreadWithNoReviewReadKeepsItsMessageBar() {
        XCTAssertFalse(ThreadRule.offersMessage(kind: .review, hasReview: true, isObserver: false))
        XCTAssertTrue(ThreadRule.offersMessage(kind: .review, hasReview: false, isObserver: false))
        XCTAssertTrue(ThreadRule.offersMessage(kind: .waiting, hasReview: false, isObserver: false))
        XCTAssertTrue(ThreadRule.offersMessage(kind: .approval, hasReview: true, isObserver: false))
    }

    func testAnObserverIsOfferedNeitherRetryNorTheMessageBar() {
        for kind in [InboxKind.waiting, .working, .approval, .review, .stuck] {
            XCTAssertFalse(ThreadRule.offersMessage(kind: kind, hasReview: false, isObserver: true))
        }
        XCTAssertEqual(ThreadRule.retryOffer(isObserver: true, stuckListed: true, sending: false), .hidden)
    }

    func testRetryStaysOffWhileARetryIsOutAndGoesWhenTheStrandIsNoLongerStuck() {
        XCTAssertEqual(ThreadRule.retryOffer(isObserver: false, stuckListed: true, sending: false), .enabled)
        XCTAssertEqual(ThreadRule.retryOffer(isObserver: false, stuckListed: true, sending: true), .disabled)
        XCTAssertEqual(ThreadRule.retryOffer(isObserver: false, stuckListed: false, sending: false), .hidden)
    }

    func testPeersShownOnlyWhenTheReadNamedTheRaiseTime() {
        XCTAssertTrue(ThreadRule.peersShown(readSince: 7, raised: 7))
        XCTAssertFalse(ThreadRule.peersShown(readSince: 0, raised: 7))
        XCTAssertFalse(ThreadRule.peersShown(readSince: 7, raised: nil))
        XCTAssertFalse(ThreadRule.peersShown(readSince: nil, raised: nil))
    }

    // MARK: Approval

    private func item(tool: String = "bash", preview: String? = nil, wanted: [(String, String)] = [], network: String? = nil, policy: Bool = false) -> ApprovalEvidenceItem {
        var fields: [String: JSONValue] = [
            "id": "e1", "revision": 1, "tool": .string(tool), "source": "policy", "reason": "needs more",
            "wanted": .array(wanted.map { ["kind": .string($0.0), "detail": .string($0.1)] }),
        ]
        if let preview { fields["preview"] = .string(preview) }
        if let network { fields["network"] = .string(network) }
        if policy { fields["policy"] = ["sandbox": "workspace-write", "network": "off"] }
        return ApprovalEvidenceItem(.object(fields))!
    }

    func testApprovalTitles() {
        XCTAssertEqual(
            ThreadRule.approvalTitle(item(preview: "sqlite3 x", wanted: [("writable_root", "~/.loom")])),
            [.words("May this program run "), .code("sqlite3 x"), .words(" with write access to "), .code("~/.loom"), .words("?")]
        )
        XCTAssertEqual(
            ThreadRule.approvalTitle(item(wanted: [("writable_root", "~/.loom")])),
            [.words("May this program have write access to "), .code("~/.loom"), .words("?")]
        )
        XCTAssertEqual(
            ThreadRule.approvalTitle(item(wanted: [("network", "full")])),
            [.words("May "), .code("bash"), .words(" reach the network?")]
        )
        XCTAssertEqual(
            ThreadRule.approvalTitle(item(tool: "", wanted: [("network", "full")])),
            [.words("May "), .code("this program"), .words(" reach the network?")]
        )
        XCTAssertNil(ThreadRule.approvalTitle(item(wanted: [("env", "X")])))
    }

    func testWriteGrantIsWordedBeforeNetwork() {
        let both = ThreadRule.approvalTitle(item(wanted: [("network", "full"), ("writable_root", "/w")]))
        XCTAssertEqual(both, [.words("May this program have write access to "), .code("/w"), .words("?")])
    }

    func testEvidenceRowsLeaveOutWhatTheDaemonDidNotSay() {
        let bare = ThreadRule.evidenceRows(item())
        XCTAssertEqual(bare.map(\.label), ["Tool", "Held by"])
        XCTAssertEqual(bare[1].value, "policy: needs more")

        let full = ThreadRule.evidenceRows(item(preview: "ls", wanted: [("network", "full"), ("writable_root", "/w")], network: "on", policy: true))
        XCTAssertEqual(full.map(\.label), ["Tool", "Command", "Held by", "Network", "Wants a network grant", "Wants", "Policy today"])
        XCTAssertEqual(full[3].value, "on")
        XCTAssertEqual(full[5].value, "writable_root /w")
        XCTAssertEqual(full[6].value, "workspace-write \u{00B7} network off")
    }

    func testAnUnnamedToolIsSaidAsNotRecorded() {
        XCTAssertEqual(ThreadRule.evidenceRows(item(tool: ""))[0].value, "not recorded")
    }

    // MARK: Stuck, ported from thread_words_test

    func testStuckTitles() {
        XCTAssertEqual(ThreadRule.stuckTitle(reason: "rate_limited"), "The last turn failed on a provider rate limit, and nothing has retried.")
        XCTAssertEqual(ThreadRule.stuckTitle(reason: "overloaded"), "The last turn failed because the provider was overloaded, and nothing has retried.")
        XCTAssertEqual(ThreadRule.stuckTitle(reason: "timeout"), "The last turn failed because the provider did not answer in time, and nothing has retried.")
        XCTAssertEqual(ThreadRule.stuckTitle(reason: "provider_error"), "The last turn failed, and nothing has retried.")
        XCTAssertEqual(ThreadRule.stuckTitle(reason: nil), "The last turn failed, and nothing has retried.")
    }

    func testStuckPhrase() {
        func words(_ stuck: AttentionStuck) -> String { ThreadRule.render(ThreadRule.stuckPhrase(stuck), clock: clock) }
        XCTAssertEqual(
            words(AttentionStuck(strand: "s", failedAt: 1000, reason: "rate_limited")),
            "Rate-limited at t1000; nothing has retried. The provider gave no reset time."
        )
        XCTAssertEqual(
            words(AttentionStuck(strand: "s", failedAt: 1000, reason: "rate_limited", retryAfterMs: 90_000)),
            "Rate-limited at t1000; nothing has retried. The provider asked for a wait of 1 min, until t91000."
        )
        XCTAssertEqual(
            words(AttentionStuck(strand: "s", reason: "overloaded", retryAfterMs: 30_000)),
            "The provider was overloaded; nothing has retried. The provider asked for a wait of 30 s."
        )
        XCTAssertEqual(words(AttentionStuck(strand: "s", failedAt: 5, reason: "timeout")), "The provider did not answer in time at t5; nothing has retried.")
        XCTAssertEqual(words(AttentionStuck(strand: "s", reason: "x", retryAfterMs: 5000)), "The last turn failed; nothing has retried.")
    }

    func testWaitWordsUseTheLargestWholeUnit() {
        XCTAssertEqual(ThreadRule.waitWords(0), "1 s")
        XCTAssertEqual(ThreadRule.waitWords(59_999), "59 s")
        XCTAssertEqual(ThreadRule.waitWords(60_000), "1 min")
        XCTAssertEqual(ThreadRule.waitWords(7_200_000), "2 h")
    }

    // MARK: The brief's cards

    func testTurnWords() {
        XCTAssertEqual(ThreadRule.turnWords(started: 0, now: 840_000), "14 min into a turn")
        XCTAssertEqual(ThreadRule.turnWords(started: 0, now: 10_000), "a turn that has just started")
        XCTAssertEqual(ThreadRule.turnWords(started: 5, now: 0), "a turn that has just started")
        XCTAssertEqual(ThreadRule.turnWords(started: 0, now: 7_200_000), "2 h into a turn")
        XCTAssertEqual(ThreadRule.turnWords(started: 0, now: 172_800_000), "2 d into a turn")
    }

    func testTokens() {
        XCTAssertEqual(ThreadRule.tokens(412_000), "412k")
        XCTAssertEqual(ThreadRule.tokens(1_200_000), "1.2M")
        XCTAssertEqual(ThreadRule.tokens(2_000_000), "2M")
        XCTAssertEqual(ThreadRule.tokens(999), "999")
    }

    func testGoalStatus() {
        XCTAssertEqual(ThreadRule.goalStatus("limited"), "stopped at its budget")
        XCTAssertNil(ThreadRule.goalStatus("x"))
    }

    func testStrandPhraseAndDelegates() {
        XCTAssertEqual(ThreadRule.render(ThreadRule.strandPhrase(state: .idle, since: nil), clock: clock), "idle")
        XCTAssertEqual(ThreadRule.render(ThreadRule.strandPhrase(state: .stopped, since: 9), clock: clock), "stopped since t9")
        let strands = ["working", "stopped", "idle", "idle"].enumerated().map { index, state in
            BriefStrand(name: "s\(index)", state: BriefStrand.State(rawValue: state)!, since: nil)
        }
        XCTAssertEqual(ThreadRule.delegates(strands), "1 working, 1 stopped, 2 idle")
        XCTAssertEqual(ThreadRule.delegates([]), "")
    }

    func testCommandIsStatedAsAFact() {
        let command = BriefCommand(command: UntrustedText("make check-core"), exit: 0, at: 1)
        XCTAssertEqual(ThreadRule.commandWords(command), "last command: make check-core, exit 0")
    }

    func testStatWords() {
        XCTAssertEqual(ThreadRule.statWords(ReviewStat(files: 7, added: 412, removed: 88), finds: 2), "+412 \u{2212}88, 7 files \u{00B7} 2 finds attached")
        XCTAssertEqual(ThreadRule.statWords(ReviewStat(files: 1, added: 3, removed: 0), finds: 0), "+3 \u{2212}0, 1 file")
        XCTAssertEqual(ThreadRule.statWords(ReviewStat(files: 2, added: 3, removed: 1), finds: 1), "+3 \u{2212}1, 2 files \u{00B7} 1 find attached")
    }

    // MARK: Eyebrow

    func testMomentByKind() {
        let ask = feedRow(ask: true)
        XCTAssertEqual(ThreadRule.moment(for: ask, raised: nil), ThreadMoment(label: "asked", at: 5))
        XCTAssertEqual(ThreadRule.moment(for: feedRow(stuck: true), raised: nil), ThreadMoment(label: "failed", at: 5))
        XCTAssertNil(ThreadRule.moment(for: feedRow(find: true), raised: nil))
        let approval = row(of: activity("needs_you", approvals: 1))
        XCTAssertNil(ThreadRule.moment(for: approval, raised: nil), "an approval with no raise time is never dated")
        XCTAssertEqual(ThreadRule.moment(for: approval, raised: 9), ThreadMoment(label: "waiting since", at: 9))
    }

    // MARK: Sending

    func testChoicesByKind() {
        XCTAssertEqual(ThreadSend.choices(for: .working), [.queue, .steer])
        XCTAssertEqual(ThreadSend.choices(for: .approval), [.send])
        XCTAssertEqual(ThreadSend.choices(for: .waiting), [.send])
        XCTAssertEqual(ThreadSend.choices(for: .failed), [.send])
        XCTAssertEqual(ThreadSend.Choice.queue.command, "prompt")
        XCTAssertEqual(ThreadSend.Choice.steer.command, "steer")
    }

    func testOnlyAnApprovalHasAHoldNoteAndItSaysAMessageStartsATurnNow() {
        XCTAssertNil(ThreadSend.holdNote(for: .waiting))
        XCTAssertTrue(ThreadSend.holdNote(for: .approval)!.contains("starts a new turn now"))
    }

    func testSendable() {
        XCTAssertFalse(ThreadSend.sendable("  \n"))
        XCTAssertTrue(ThreadSend.sendable("hi"))
        XCTAssertTrue(ThreadSend.sendable(String(repeating: "a", count: 16_384)))
        XCTAssertFalse(ThreadSend.sendable(String(repeating: "a", count: 16_385)))
    }

    func testDeliveredWords() {
        XCTAssertEqual(ThreadSend.deliveredWords(status: "admitted", choice: .send, name: "n"), "Delivered to n \u{00B7} admitted")
        XCTAssertEqual(ThreadSend.deliveredWords(status: "queued", choice: .queue, name: "n"), "Delivered to n \u{00B7} queued")
        XCTAssertEqual(
            ThreadSend.deliveredWords(status: "queued", choice: .steer, name: "n"),
            "Delivered to n \u{00B7} steering: it stops the current turn and runs next"
        )
        XCTAssertEqual(ThreadSend.refusedWords("its queue is full"), "Not sent: its queue is full")
    }
}
