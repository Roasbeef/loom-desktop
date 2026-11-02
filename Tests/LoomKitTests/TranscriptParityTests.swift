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

final class GenerationRateTests: XCTestCase {
    func testARequestSeenFromItsFirstFragmentIsTimedAtItsUsageReading() {
        var rate = GenerationRate()
        rate.fragment(strand: "main", generation: "g1", now: 10_000)
        rate.fragment(strand: "main", generation: "g1", now: 11_000)
        rate.settle(strand: "main", output: 300, now: 12_000)
        XCTAssertEqual(rate.rate(strand: "main"), 150)
    }

    func testAShortWindowLeavesTheLastRateStanding() {
        var rate = GenerationRate()
        rate.fragment(strand: "main", generation: "g1", now: 0)
        rate.settle(strand: "main", output: 300, now: 2_000)
        rate.fragment(strand: "main", generation: "g2", now: 2_200)
        rate.settle(strand: "main", output: 900, now: 2_700)
        XCTAssertEqual(rate.rate(strand: "main"), 150, "under a second says nothing")
        rate.settle(strand: "main", output: 900, now: 9_000)
        XCTAssertEqual(rate.rate(strand: "main"), 150, "one clock settles one reading")
    }

    func testARequestRunningWhenTheLaneAttachedIsNeverTimed() {
        var rate = GenerationRate()
        rate.attached(busy: ["main"])
        rate.fragment(strand: "main", generation: "mid", now: 5_000)
        rate.settle(strand: "main", output: 500, now: 9_000)
        XCTAssertNil(rate.rate(strand: "main"))
        rate.fragment(strand: "main", generation: "next", now: 10_000)
        rate.settle(strand: "main", output: 500, now: 12_000)
        XCTAssertEqual(rate.rate(strand: "main"), 250)
    }

    func testStrandsAreTimedIndependently() {
        var rate = GenerationRate()
        rate.fragment(strand: "main", generation: "g1", now: 0)
        rate.settle(strand: "advisor", output: 100, now: 5_000)
        XCTAssertNil(rate.rate(strand: "advisor"))
        XCTAssertNil(rate.rate(strand: "main"))
    }

    func testTheConversationFeedsItFromPushedFrames() {
        var state = Conversation(sessionID: session)
        func push(_ event: String, _ body: JSONValue, at now: Int) {
            state.apply(push: EventEnvelope(replyTo: nil, event: event, seq: nil, body: body), now: now)
        }
        push("stream_delta", ["strand": "main", "generation": "g1", "kind": "text", "text": "hi"], at: 0)
        push("stream_delta", ["strand": "main", "generation": "g1", "kind": "end"], at: 3_900)
        push("usage_observation", ["strand": "main", "usage": ["output": 400]], at: 4_000)
        XCTAssertEqual(state.generation.rate(strand: "main"), 100)
    }
}

final class FoldParityTests: XCTestCase {
    func testTheNotesIndexIsAMemoryContextAndAPromptIsNot() {
        let notes = "Notes saved in this repository by earlier sessions.\n\n```loom-notes\n- (fact) a\n- (fact) b\n```"
        XCTAssertEqual(MemoryContext.lines(in: notes), 2)
        XCTAssertEqual(MemoryContext.lines(in: "Distilled memory from this repository's earlier sessions.\n\n```loom-memory\n- a\n```"), 1)
        XCTAssertNil(MemoryContext.lines(in: "Notes saved in this repository by earlier sessions, but no fence"))
        XCTAssertNil(MemoryContext.lines(in: "please fix the retry budget"))
        XCTAssertEqual(MemoryContext.summary(lines: 1), "Memory context, 1 line")
        XCTAssertEqual(MemoryContext.summary(lines: 3), "Memory context, 3 lines")
    }

    func testAMemoryContextJoinsTheTurnItFollowsAndOpensNone() {
        let user = TranscriptRow(id: "u", kind: .user(text: "go", author: "Owner"), at: 1_000)
        let memory = TranscriptRow(id: "m", kind: .memory(lines: 2, text: "notes"))
        let step = TranscriptRow(id: "t", kind: .tool(name: "bash", arguments: ["command": "ls"], result: "ok", isError: false), at: 2_000)
        let answer = TranscriptRow(id: "a", kind: .assistant(text: "done"), at: 3_000)
        let blocks = TranscriptBlock.group([user, memory, step, answer])
        guard blocks.count == 3, case .fold(let fold) = blocks[1] else { return XCTFail("expected user, fold, answer: \(blocks)") }
        XCTAssertEqual(fold.rows.map(\.id), ["m", "t"])
        XCTAssertEqual(fold.steps, 1, "a memory row is not a step")
    }

    func testAMemoryContextWithNoWorkStandsAlone() {
        let user = TranscriptRow(id: "u", kind: .user(text: "go", author: "Owner"), at: 1_000)
        let memory = TranscriptRow(id: "m", kind: .memory(lines: 1, text: "notes"))
        let answer = TranscriptRow(id: "a", kind: .assistant(text: "done"), at: 3_000)
        XCTAssertEqual(TranscriptBlock.group([user, memory, answer]).count, 3)
    }

    func testAStoppedTurnOrACancelledCommandSaysInterrupted() {
        let user = TranscriptRow(id: "u", kind: .user(text: "go", author: "Owner"), at: 0)
        var stopped = TranscriptRow(id: "t", kind: .tool(name: "bash", arguments: ["command": "sleep 9"], result: "gone", isError: true), at: 1_000)
        stopped.settledAt = 3_000
        stopped.details = ["cancelled": .bool(true)]
        let blocks = TranscriptBlock.group([user, stopped])
        guard case .fold(let fold) = blocks[1] else { return XCTFail("expected a fold") }
        XCTAssertTrue(fold.isInterrupted)
        XCTAssertEqual(fold.title, "Worked 3s · 1 step · 1 failed · interrupted")
    }

    func testADeadlineIsNotAnInterruption() {
        var timedOut = TranscriptRow(id: "t", kind: .tool(name: "bash", arguments: [:], result: "late", isError: true), at: 0)
        timedOut.details = ["cancelled": .bool(true), "timed_out": .bool(true)]
        XCTAssertFalse(Fold.wasInterrupted([timedOut]))
        let notice = TranscriptRow(id: "x/stopped", kind: .notice(text: "Stopped before the turn finished."))
        XCTAssertTrue(Fold.wasInterrupted([notice]))
    }
}

final class SessionApprovalTests: XCTestCase {
    private func request(_ grants: [JSONValue]) -> Escalation {
        Escalation(id: "e", seq: 1, status: "pending", strand: "main", tool: "bash", action: "run", preview: "", reason: "", source: "", grants: grants)
    }

    func testOneUnlimitedWallGrantMayBeRememberedForTheExactAction() {
        let wall = request([["type": "limit", "field": "wall_seconds", "value": 0]])
        XCTAssertTrue(wall.canRemember)
        XCTAssertEqual(wall.rememberedAuthority, "Session approval permits only this exact action on this strand.")
    }

    func testAWallGrantWithOthersOrANonZeroValueStaysOnceOnly() {
        XCTAssertFalse(request([["type": "limit", "field": "wall_seconds", "value": 30]]).canRemember)
        XCTAssertFalse(request([["type": "limit", "field": "wall_seconds", "value": 0], ["type": "writable_root", "path": "/tmp"]]).canRemember)
        XCTAssertFalse(request([["type": "limit", "field": "pids", "value": 0]]).canRemember)
    }

    func testAFilesystemGrantKeepsTheRestartWords() {
        let write = request([["type": "writable_root", "path": "/tmp/x"]])
        XCTAssertTrue(write.canRemember)
        XCTAssertEqual(write.rememberedAuthority, "Session approval persists across restart.")
    }
}

final class ImageBlockTests: XCTestCase {
    private func png(width: UInt32, height: UInt32) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8)
        for value in [width, height] { bytes += [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        return Data(bytes + [8, 2, 0, 0, 0])
    }

    func testReadsThePixelSizeOfEachTypeFromItsOwnHeader() {
        XCTAssertEqual(ImageHeader.size(of: png(width: 640, height: 480))?.width, 640)
        XCTAssertEqual(ImageHeader.size(of: png(width: 640, height: 480))?.height, 480)
        let gif = Data(Array("GIF89a".utf8) + [0x20, 0x01, 0x10, 0x00, 0, 0, 0])
        XCTAssertEqual(ImageHeader.size(of: gif)?.width, 288)
        XCTAssertEqual(ImageHeader.size(of: gif)?.height, 16)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0, 0, 0xFF, 0xC0, 0x00, 0x0B, 8, 0x00, 0x20, 0x00, 0x30, 3, 0, 0, 0])
        XCTAssertEqual(ImageHeader.size(of: jpeg)?.width, 48)
        XCTAssertEqual(ImageHeader.size(of: jpeg)?.height, 32)
        var webp = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8) + Array("VP8X".utf8) + [10, 0, 0, 0, 0, 0, 0, 0]
        webp += [0x7F, 0x00, 0x00, 0x3F, 0x00, 0x00]
        XCTAssertEqual(ImageHeader.size(of: Data(webp))?.width, 128)
        XCTAssertEqual(ImageHeader.size(of: Data(webp))?.height, 64)
        XCTAssertNil(ImageHeader.size(of: Data("plain text, no image".utf8)))
    }

    func testTheCaptionGivesTypeSizeAndWeightOnlyWhenTheBytesAgree() {
        let good = ImageBlock(id: "a", mimeType: "image/png", data: png(width: 2, height: 2))
        XCTAssertTrue(good.isDrawable)
        XCTAssertTrue(good.caption.hasPrefix("image/png · 2 × 2 pixels · "), good.caption)
        let lying = ImageBlock(id: "b", mimeType: "image/jpeg", data: png(width: 2, height: 2))
        XCTAssertFalse(lying.isDrawable)
        XCTAssertEqual(lying.caption, "Not drawn: the bytes are not image/jpeg.")
        XCTAssertEqual(ImageBlock(id: "c", mimeType: "", data: Data("x".utf8)).caption, "Not drawn: the bytes are not a known image type.")
    }

    func testReadsImageBlocksInOrderAndSkipsWhatIsNotBase64() {
        let encoded = png(width: 1, height: 1).base64EncodedString()
        let blocks: [JSONValue] = [
            ["type": "text", "text": "look"],
            ["type": "image", "data": .string(encoded), "mimeType": "image/png"],
            ["type": "image", "data": "!!!", "mimeType": "image/png"],
        ]
        let found = ImageBlock.read(blocks: blocks, rowID: "r")
        XCTAssertEqual(found.map(\.id), ["r/image/1"])
    }

    func testAMessageCarriesFourImagesAndTwentyMebibytesInAll() {
        let tiny = png(width: 1, height: 1)
        guard case .failure(let fifth) = ImageAttachment.vet(tiny, name: "e.png", already: 4) else { return XCTFail("a fifth image is refused") }
        XCTAssertTrue(fifth.message.contains("4 of 4 images"), fifth.message)
        guard case .failure(let heavy) = ImageAttachment.vet(tiny, name: "big.png", already: 1, alreadyBytes: ImageAttachment.byteLimit) else {
            return XCTFail("the total weight is bounded")
        }
        XCTAssertTrue(heavy.message.contains("20 MiB"), heavy.message)
        guard case .success = ImageAttachment.vet(tiny, name: "ok.png", already: 3, alreadyBytes: 1_000) else { return XCTFail("a fourth is accepted") }
    }
}
