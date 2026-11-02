import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit
@testable import SubstrateKit

private let session = "01a19a3a-0000-7000-8000-000000000001"

private func begin(_ next: Int64 = 10, window: String = "recent") -> JSONValue {
    [
        "snapshot_id": "3:0", "next_seq": .int(next), "window": .string(window),
        "complete_history": .bool(false), "record_bytes_limit": 33554432,
        "fragment_bytes_limit": 24576, "oldest_seq": .null,
        "session_id": .string(session), "epoch": "e", "incarnation": "i",
        "connection_id": "c", "role": "owner",
    ]
}

private func chunk(index: Int64, kind: String, id: String, total: Int, offset: Int, data: String) -> JSONValue {
    [
        "snapshot_id": "3:0", "index": .int(index), "kind": .string(kind),
        "record_id": .string(id), "record_seq": .null, "total_bytes": .int(Int64(total)),
        "offset": .int(Int64(offset)), "data": .string(Data(data.utf8).base64EncodedString()),
    ]
}

/// Builds a one-strand cut whose leaf is `leaf`.
private func cut(entries: [JSONValue], leaf: String?, extraCells: [JSONValue] = [], window: String = "catch_up") -> Cut {
    let leafValue: JSONValue = leaf.map { .string($0) } ?? .null
    let cells: [JSONValue] = [
        ["namespace": "strand.config", "key": "main", "seq": 1, "value": ["model": ["modelId": "fake"]]],
        ["namespace": "strand.leaf", "key": "main", "seq": 2, "value": leafValue],
    ] + extraCells
    return Cut(
        window: window, nextSeq: 99, oldestSeq: 1, moreAfter: nil,
        identity: .init(sessionID: session, epoch: "e", incarnation: "i", connectionID: "c", role: "owner"),
        metadata: ["cells": .array(cells), "peers": [], "usage": .null], entries: entries
    )
}

private func message(_ id: String, parent: String?, _ body: JSONValue) -> JSONValue {
    ["id": .string(id), "parentId": parent.map { .string($0) } ?? .null, "seq": 1, "timestamp": 1, "type": "message", "message": body]
}

final class TransferTests: XCTestCase {
    func testAssemblesFragmentedRecords() throws {
        var assembler = try TransferAssembler(begin: begin(), expectedSession: session, expectedIdentity: nil)
        let metadata = #"{"cells":[]}"#
        try assembler.absorb(chunk: chunk(index: 0, kind: "metadata", id: "metadata", total: metadata.utf8.count, offset: 0, data: String(metadata.prefix(5))))
        try assembler.absorb(chunk: chunk(index: 1, kind: "metadata", id: "metadata", total: metadata.utf8.count, offset: 5, data: String(metadata.dropFirst(5))))
        let entry = #"{"id":"a"}"#
        try assembler.absorb(chunk: chunk(index: 2, kind: "entry", id: "a", total: entry.utf8.count, offset: 0, data: entry))
        let result = try assembler.finish(end: ["snapshot_id": "3:0", "next_seq": 10, "more_after": .null])
        XCTAssertEqual(result.entries.first?["id"]?.string, "a")
        XCTAssertEqual(result.nextSeq, 10)
    }

    func testRejectsAnEntryBeforeMetadata() throws {
        var assembler = try TransferAssembler(begin: begin(), expectedSession: session, expectedIdentity: nil)
        XCTAssertThrowsError(try assembler.absorb(chunk: chunk(index: 0, kind: "entry", id: "a", total: 2, offset: 0, data: "{}")))
    }

    func testRejectsInterleavedRecordsAndWrongOffsets() throws {
        var assembler = try TransferAssembler(begin: begin(), expectedSession: session, expectedIdentity: nil)
        try assembler.absorb(chunk: chunk(index: 0, kind: "metadata", id: "metadata", total: 10, offset: 0, data: "{}"))
        XCTAssertThrowsError(try assembler.absorb(chunk: chunk(index: 1, kind: "entry", id: "a", total: 2, offset: 0, data: "{}")))
        XCTAssertThrowsError(try assembler.absorb(chunk: chunk(index: 1, kind: "metadata", id: "metadata", total: 10, offset: 7, data: "{}")))
    }

    func testRejectsAnEndInsideARecord() throws {
        var assembler = try TransferAssembler(begin: begin(), expectedSession: session, expectedIdentity: nil)
        try assembler.absorb(chunk: chunk(index: 0, kind: "metadata", id: "metadata", total: 10, offset: 0, data: "{}"))
        XCTAssertThrowsError(try assembler.finish(end: ["snapshot_id": "3:0", "next_seq": 10]))
    }

    func testRefusesAnotherSessionAndAChangedIdentity() throws {
        XCTAssertThrowsError(try TransferAssembler(begin: begin(), expectedSession: "other", expectedIdentity: nil))
        let other = Cut.Identity(sessionID: session, epoch: "x", incarnation: "i", connectionID: "c", role: "owner")
        XCTAssertThrowsError(try TransferAssembler(begin: begin(), expectedSession: session, expectedIdentity: other))
    }
}

final class ConversationTests: XCTestCase {
    func testPairsAToolResultWithItsCallAndFollowsTheChain() {
        var state = Conversation(sessionID: session)
        let user = message("u", parent: nil, ["role": "user", "content": [["type": "text", "text": "hi"]], "origin": ["name": "Owner"]])
        let call = message("a", parent: "u", ["role": "assistant", "content": [
            ["type": "toolCall", "toolCall": ["id": "c1", "name": "bash", "arguments": ["command": "ls"]]],
        ]])
        let result = message("r", parent: "a", ["role": "toolResult", "toolCallId": "c1", "toolName": "bash", "content": [["type": "text", "text": "ok"]], "isError": .bool(false)])
        let abandoned = message("x", parent: "u", ["role": "assistant", "content": [["type": "text", "text": "abandoned"]]])
        state.apply(cut: cut(entries: [user, call, result, abandoned], leaf: "r"))

        let rows = state.rows(strand: "main")
        XCTAssertEqual(rows.count, 2)
        guard case .tool(let name, _, let output, _) = rows[1].kind else { return XCTFail("expected a tool row") }
        XCTAssertEqual(name, "bash")
        XCTAssertEqual(output, "ok")
    }

    func testATransferredToolCallIsInlined() {
        var state = Conversation(sessionID: session)
        let call = message("a", parent: nil, ["role": "assistant", "content": [
            ["type": "toolCall", "id": "c1", "name": "fs_write", "arguments": ["path": "/x"]],
        ]])
        state.apply(cut: cut(entries: [call], leaf: "a"))
        guard case .tool(let name, _, _, _) = state.rows(strand: "main").first?.kind else { return XCTFail("expected a tool row") }
        XCTAssertEqual(name, "fs_write")
    }

    func testAHarnessNoteIsNotDrawnAsAPersonsMessage() {
        var state = Conversation(sessionID: session)
        let note = message("n", parent: nil, ["role": "user", "content": [["type": "text", "text": "[loom] approval approved"]], "origin": .null])
        state.apply(cut: cut(entries: [note], leaf: "n"))
        XCTAssertEqual(state.rows(strand: "main").first?.kind, .notice(text: "approval approved"))
    }

    func testHasOlderFollowsTheChainAndClearsWhenTheRootLands() {
        var state = Conversation(sessionID: session)
        let tip = message("b", parent: "a", ["role": "assistant", "content": []])
        state.apply(cut: cut(entries: [tip], leaf: "b"))
        XCTAssertTrue(state.hasOlder(strand: "main"))
        let root = message("a", parent: nil, ["role": "user", "content": [], "origin": .null])
        state.apply(cut: cut(entries: [root], leaf: "b", window: "history"))
        XCTAssertFalse(state.hasOlder(strand: "main"))
    }

    func testAnUnknownEntryTypeIsShownAsCorruption() {
        var state = Conversation(sessionID: session)
        state.apply(cut: cut(entries: [["id": "z", "parentId": .null, "type": "mystery"]], leaf: "z"))
        guard case .failure = state.rows(strand: "main").first?.kind else { return XCTFail("expected a failure row") }
    }

    func testAHistoryCutKeepsNewerMetadata() {
        var state = Conversation(sessionID: session)
        state.apply(cut: cut(entries: [], leaf: "b"))
        state.apply(cut: cut(entries: [], leaf: "old", window: "history"))
        XCTAssertEqual(state.strands.first?.leaf, "b")
    }

    func testANewGenerationReplacesTheStreamAndAnEndedOneSurvivesUntilItsEntryLands() {
        var state = Conversation(sessionID: session)
        func delta(_ generation: String, _ kind: String, _ text: String) -> EventEnvelope {
            EventEnvelope(replyTo: nil, event: "stream_delta", seq: nil, body: [
                "strand": "main", "generation": .string(generation), "kind": .string(kind), "text": .string(text),
            ])
        }
        state.apply(push: delta("g1", "text", "one "))
        state.apply(push: delta("g2", "text", "two"))
        XCTAssertEqual(state.streams["main"]?.text, "two")

        state.apply(push: delta("g2", "end", ""))
        state.apply(cut: cut(entries: [], leaf: nil))
        XCTAssertEqual(state.streams["main"]?.text, "two")

        let entry = message("a", parent: nil, ["role": "assistant", "content": [["type": "text", "text": "two"]]])
        state.apply(cut: cut(entries: [entry], leaf: "a"))
        XCTAssertNil(state.streams["main"])
    }

    func testEscalationEchoesKeepTheCellSequenceAndGrants() {
        var state = Conversation(sessionID: session)
        let durable: JSONValue = ["grant": "writable_root", "path": "/Users/Shared"]
        let unknown: JSONValue = ["grant": "future_kind"]
        let wire: JSONValue = ["type": "writable_root", "path": "/Users/Shared"]
        let escalation: JSONValue = [
            "namespace": "fact.custom", "key": "escalation/e1", "seq": 41,
            "value": [
                "id": "e1", "scope": ["strand": "main"], "status": "pending", "tool": "fs_write", "action": "digest", "preview": "{}",
                "denial": ["reason": "outside", "source": "policy", "wanted": [durable, unknown]],
            ],
        ]
        state.apply(cut: cut(entries: [], leaf: nil, extraCells: [escalation]))
        let record = state.escalations.first
        XCTAssertEqual(record?.id, "e1")
        XCTAssertEqual(record?.seq, 41)
        XCTAssertEqual(record?.grants, [wire])
        XCTAssertEqual(record?.strand, "main")
        XCTAssertEqual(record?.canApprove, false)
        XCTAssertEqual(record?.authorityLines, ["Write to /Users/Shared"])
    }
}

final class EscapeTests: XCTestCase {
    func testControlAndBidiCharactersAreEscapedNotDeleted() {
        let escaped = Escalation.escapeForDisplay("npm\u{08}\u{1B}[2J\u{202E}x\ny")
        XCTAssertEqual(escaped, "npm\\u{8}\\u{1B}[2J\\u{202E}x\ny")
    }
}

final class DiscoveryTests: XCTestCase {
    func testABearerNeverGoesToARoutableHost() {
        let endpoint = DaemonEndpoint(host: "10.0.0.1", port: 1, token: "secret")
        XCTAssertThrowsError(try endpoint.url(path: "/v2/control"))
        XCTAssertFalse(endpoint.description.contains("secret"))
    }

    func testOwnerTokenShape() {
        XCTAssertTrue(DaemonDiscovery.isOwnerToken(String(repeating: "a", count: 64)))
        XCTAssertFalse(DaemonDiscovery.isOwnerToken("loomclaim_" + String(repeating: "a", count: 64)))
    }
}

final class MissionTests: XCTestCase {
    private func record(_ id: String, state: JSONValue) -> SessionRecord {
        SessionRecord(["session_id": .string(id), "workspace": "/src/loom", "name": "work", "created_at": 1, "status": state])!
    }

    private func activity(_ id: String, _ state: String, approvals: Int64 = 0) -> SessionActivity {
        SessionActivity(["session_id": .string(id), "state": .string(state), "approvals": .int(approvals), "last_message": "broke"])!
    }

    func testAnApprovalCountWithoutARecordStillSurfaces() {
        let items = Mission.attention(
            sessions: [record("a", state: ["state": "resident", "incarnation": "i"])],
            activity: ["a": activity("a", "needs_you", approvals: 1)],
            escalations: [:], feed: nil
        )
        XCTAssertEqual(items.map(\.kind), [.approval])
    }

    func testAFailedRunIsDistinctFromAnApprovalAndIdleIsAbsent() {
        let items = Mission.attention(
            sessions: [
                record("a", state: ["state": "resident", "incarnation": "i"]),
                record("b", state: ["state": "resident", "incarnation": "i"]),
            ],
            activity: ["a": activity("a", "needs_you"), "b": activity("b", "idle")],
            escalations: [:], feed: nil
        )
        XCTAssertEqual(items.map(\.kind), [.failed])
    }

    func testAnUnrecognizedActivityStateReadsAsUnknown() {
        XCTAssertEqual(activity("a", "brand_new_state").state, .unknown)
    }

    func testTheSubstrateFeedMergesAndHidesTheOperatorsOwnAgent() throws {
        let json = #"""
        {"generated_at":"t","lanes":[
          {"agent":{"id":3,"name":"AmberForge","status":"active","project_key":"substrate.git","git_branch":"cc"},
           "events":[{"message_id":9,"kind":"question","subject":"SSE?","needs_action":true,"has_diff":false}],
           "unread_count":2,"needs_action_count":1,"waiting_for":"Decision"},
          {"agent":{"id":1,"name":"User","status":"offline"},"events":null,"unread_count":0,"needs_action_count":0}
        ],"attention":[{"kind":"plan","agent_id":4,"agent_name":"QuietRiver","title":"Fix RFQ","plan_review_id":"p1","created_at":"t"}]}
        """#
        let feed = try JSONDecoder().decode(CommandFeed.self, from: Data(json.utf8))
        let cards = Mission.cards(sessions: [], activity: [:], feed: feed)
        XCTAssertEqual(cards.map(\.name), ["AmberForge"])
        XCTAssertEqual(cards.first?.liveness, .needsYou)
        let items = Mission.attention(sessions: [], activity: [:], escalations: [:], feed: feed)
        XCTAssertEqual(items.first?.kind, .plan)
    }

    func testAnEmptyGoFeedDecodes() throws {
        let feed = try JSONDecoder().decode(CommandFeed.self, from: Data(#"{"lanes":null,"attention":null}"#.utf8))
        XCTAssertTrue(feed.lanes.isEmpty)
    }
}
