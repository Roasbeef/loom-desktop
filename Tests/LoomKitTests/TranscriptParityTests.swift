import Foundation
import XCTest
@testable import LoomKit

private let session = "01a19a3a-0000-7000-8000-000000000002"

private func cut(entries: [JSONValue], leaf: String) -> Cut {
    let cells: [JSONValue] = [
        ["namespace": "strand.config", "key": "main", "seq": 1, "value": ["model": ["modelId": "fake"]]],
        ["namespace": "strand.leaf", "key": "main", "seq": 2, "value": .string(leaf)],
    ]
    return Cut(
        window: "catch_up", nextSeq: 99, oldestSeq: 1, moreAfter: nil,
        identity: .init(sessionID: session, epoch: "e", incarnation: "i", connectionID: "c", role: "owner"),
        metadata: ["cells": .array(cells), "peers": [], "usage": .null], entries: entries
    )
}

private func entry(_ id: String, parent: String?, seq: Int, at: Int, _ body: JSONValue) -> JSONValue {
    [
        "id": .string(id), "parentId": parent.map { .string($0) } ?? .null, "seq": .int(Int64(seq)),
        "timestamp": .int(Int64(at)), "type": "message", "message": body,
    ]
}

private func reply(_ text: String, input: Int, cacheRead: Int) -> JSONValue {
    [
        "role": "assistant", "content": [["type": "text", "text": .string(text)]],
        "usage": [
            "input": .int(Int64(input)), "output": 10, "cacheRead": .int(Int64(cacheRead)), "cacheWrite": 0,
            "cost": ["input": .double(0.003), "output": .double(0), "cacheRead": .double(0.0003), "cacheWrite": .double(0), "total": .double(0.0033)],
        ],
    ]
}

private func person(_ text: String) -> JSONValue {
    ["role": "user", "content": [["type": "text", "text": .string(text)]], "origin": ["name": "Owner"]]
}

final class CacheWatchTests: XCTestCase {
    private let held = CacheUse(input: 500, cacheRead: 12_000, cacheWrite: 0, costInput: 0.0015, costCacheRead: 0.0036)
    private let reread = CacheUse(input: 12_500, cacheRead: 0, cacheWrite: 0, costInput: 0.0375)

    func testAPauseThatReReadsTheCachedPrefixIsAMiss() throws {
        let miss = try XCTUnwrap(CacheWatch.detect(previous: held, previousAt: 0, current: reread, currentAt: 90_000))
        XCTAssertEqual(miss.idleMs, 90_000)
        XCTAssertEqual(miss.tokens, 12_000)
        XCTAssertTrue(miss.words.hasPrefix("Cache missed after 1m idle."), miss.words)
        XCTAssertNotNil(miss.estimate)
    }

    func testAQuickFollowUpIsNotAMissEvenIfTheReadCollapsed() {
        XCTAssertNil(CacheWatch.detect(previous: held, previousAt: 0, current: reread, currentAt: 30_000))
    }

    func testASmallPrefixOrAPartialHitIsNotAMiss() {
        let small = CacheUse(input: 100, cacheRead: 2_000, cacheWrite: 0)
        XCTAssertNil(CacheWatch.detect(previous: small, previousAt: 0, current: reread, currentAt: 90_000))
        let partial = CacheUse(input: 500, cacheRead: 11_000, cacheWrite: 0)
        XCTAssertNil(CacheWatch.detect(previous: held, previousAt: 0, current: partial, currentAt: 90_000))
    }

    func testAnUnpricedMissStillSpeaksWithoutMoney() throws {
        let free = CacheUse(input: 500, cacheRead: 12_000, cacheWrite: 0)
        let miss = try XCTUnwrap(CacheWatch.detect(previous: free, previousAt: 0, current: CacheUse(input: 12_500, cacheRead: 0, cacheWrite: 0), currentAt: 120_000))
        XCTAssertNil(miss.estimate)
        XCTAssertFalse(miss.words.contains("$"))
    }

    func testTheOutlookOnlyReportsIdleTimeAndNeverAnExpiry() {
        XCTAssertNil(CacheWatch.outlook(last: held, lastAt: 0, now: 30_000))
        XCTAssertEqual(CacheWatch.outlook(last: held, lastAt: 0, now: 61_000), "cache idle 1m")
        XCTAssertEqual(CacheWatch.outlook(last: held, lastAt: 0, now: 4_320_000), "cache idle 1h 12m")
        XCTAssertNil(CacheWatch.outlook(last: CacheUse(input: 10, cacheRead: 100, cacheWrite: 0), lastAt: 0, now: 600_000))
        XCTAssertNil(CacheWatch.outlook(last: nil, lastAt: nil, now: 600_000))
    }

    func testTheIdleLabelReadsLikeAClock() {
        XCTAssertEqual(CacheWatch.idleLabel(45_000), "45s")
        XCTAssertEqual(CacheWatch.idleLabel(7 * 60_000), "7m")
        XCTAssertEqual(CacheWatch.idleLabel(3_600_000), "1h")
    }
}

final class ProjectionParityTests: XCTestCase {
    func testAMissRowStandsBeforeTheReplyThatPaidForIt() {
        var state = Conversation(sessionID: session)
        let entries = [
            entry("u1", parent: nil, seq: 1, at: 1_000, person("one")),
            entry("a1", parent: "u1", seq: 2, at: 2_000, reply("first", input: 500, cacheRead: 12_000)),
            entry("u2", parent: "a1", seq: 3, at: 100_000, person("two")),
            entry("a2", parent: "u2", seq: 4, at: 101_000, reply("second", input: 12_500, cacheRead: 0)),
        ]
        state.apply(cut: cut(entries: entries, leaf: "a2"))
        let rows = state.rows(strand: "main")
        let kinds = rows.map { row -> String in
            switch row.kind {
            case .user: return "user"
            case .assistant: return "assistant"
            case .notice(let text): return text.hasPrefix("Cache missed") ? "miss" : "notice"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["user", "assistant", "user", "miss", "assistant"])
        XCTAssertNotNil(CacheStamp.newest(rows))
        XCTAssertEqual(CacheStamp.newest(rows)?.at, 101_000)
    }

    func testClearHidesWhatWasDrawnAndKeepsWhatComesAfter() {
        var state = Conversation(sessionID: session)
        let before = [
            entry("u1", parent: nil, seq: 1, at: 1_000, person("one")),
            entry("a1", parent: "u1", seq: 2, at: 2_000, reply("first", input: 1, cacheRead: 0)),
        ]
        state.apply(cut: cut(entries: before, leaf: "a1"))
        let through = state.newestSeq(strand: "main")
        XCTAssertEqual(through, 2)
        XCTAssertTrue(state.rows(strand: "main", clearedThrough: through).isEmpty)

        let after = before + [entry("u2", parent: "a1", seq: 3, at: 3_000, person("two"))]
        state.apply(cut: cut(entries: after, leaf: "u2"))
        XCTAssertEqual(state.rows(strand: "main", clearedThrough: through).count, 1)
        XCTAssertEqual(state.rows(strand: "main").count, 3, "the session still holds everything")
    }

    func testAToolRowThatSettledAfterTheClearStaysHiddenWithItsCall() {
        var state = Conversation(sessionID: session)
        let call: JSONValue = ["role": "assistant", "content": [["type": "toolCall", "toolCall": ["id": "c1", "name": "bash", "arguments": ["command": "ls"]]]]]
        let result: JSONValue = ["role": "toolResult", "toolCallId": "c1", "toolName": "bash", "content": [["type": "text", "text": "ok"]], "isError": .bool(false)]
        state.apply(cut: cut(entries: [
            entry("u", parent: nil, seq: 1, at: 1, person("go")),
            entry("a", parent: "u", seq: 2, at: 2, call),
            entry("r", parent: "a", seq: 3, at: 3, result),
        ], leaf: "r"))
        XCTAssertTrue(state.rows(strand: "main", clearedThrough: 3).isEmpty)
        XCTAssertEqual(state.rows(strand: "main", clearedThrough: 1).count, 1, "the settled call keeps its own sequence")
    }

    func testCompactionBranchAndOversizedRecordsDrawAsNotices() {
        var state = Conversation(sessionID: session)
        func record(_ id: String, parent: String?, seq: Int, _ type: String, extra: [String: JSONValue] = [:]) -> JSONValue {
            var fields: [String: JSONValue] = [
                "id": .string(id), "parentId": parent.map { .string($0) } ?? .null,
                "seq": .int(Int64(seq)), "timestamp": .int(Int64(seq)), "type": .string(type),
            ]
            for (key, value) in extra { fields[key] = value }
            return .object(fields)
        }
        state.apply(cut: cut(entries: [
            record("c", parent: nil, seq: 1, "compaction"),
            record("b", parent: "c", seq: 2, "branch_summary"),
            record("o", parent: "b", seq: 3, "oversized", extra: ["size": 70_000]),
        ], leaf: "o"))
        let words = state.rows(strand: "main").compactMap { row -> String? in
            if case .notice(let text) = row.kind { return text }
            return nil
        }
        XCTAssertEqual(words, ["Earlier conversation compacted.", "Returned from another branch.", "A record of 70000 bytes was left out."])
    }

    func testAHeldPromptTheDaemonReturnsIsHandedOverOnce() {
        var state = Conversation(sessionID: session)
        state.apply(push: EventEnvelope(
            replyTo: nil, event: "held_input_returned", seq: nil,
            body: ["strand": "main", "id": "h1", "kind": "queue", "text": "finish the report", "attachment_count": 2]
        ))
        let first = state.takeReturnedDrafts()
        XCTAssertEqual(first, [ReturnedDraft(strand: "main", text: "finish the report", attachmentCount: 2)])
        XCTAssertTrue(state.takeReturnedDrafts().isEmpty)
    }
}

final class ApprovalLedgerTests: XCTestCase {
    private func decision(_ id: String, seq: Int, outcome: String) -> Decision {
        Decision(id: id, seq: seq, strand: "main", tool: "fs_write", summary: "Write to /tmp/x", outcome: outcome)
    }

    func testTheLedgerListsAnswersInTheOrderTheyWereGiven() {
        let words = Decision.ledgerWords([decision("b", seq: 9, outcome: "rejected"), decision("a", seq: 3, outcome: "consumed")], matching: nil)
        let lines = words.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("Allowed once: Write to /tmp/x"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("Denied:"), lines[1])
    }

    func testAnIdNamesOneAnswerAndAMissIsSaidPlainly() {
        let all = [decision("policy-abc", seq: 1, outcome: "approved")]
        XCTAssertTrue(Decision.ledgerWords(all, matching: "policy-a").hasPrefix("Allowed:"))
        XCTAssertEqual(Decision.ledgerWords(all, matching: "zzz"), "No answered request starts with zzz.")
        XCTAssertEqual(Decision.ledgerWords([], matching: nil), "No request has been answered in this session.")
    }
}
