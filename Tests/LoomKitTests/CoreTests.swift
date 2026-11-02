import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

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

final class PlacementTests: XCTestCase {
    private func record(_ extra: [String: JSONValue] = [:]) -> SessionRecord {
        var fields: [String: JSONValue] = ["session_id": "a", "workspace": "proj", "name": "work", "created_at": 1, "status": ["state": "saved"]]
        fields.merge(extra) { _, new in new }
        return SessionRecord(.object(fields))!
    }

    func testBrainAndHands() {
        XCTAssertEqual(Placement(record: record(), brain: "laptop").label, "laptop")
        XCTAssertEqual(Placement(record: record(["executor": "box"]), brain: "laptop").label, "laptop → box")
        XCTAssertEqual(Placement(record: record(["pool": "linux"]), brain: "laptop").label, "laptop → linux pool")
    }

    func testAPoolThatHasChosenNamesItsExecutor() {
        XCTAssertEqual(Placement(record: record(["pool": "linux", "executor": "box"]), brain: "laptop").hands, "box")
    }

    func testDecodesARealDeploymentShape() {
        let body: JSONValue = [
            "self": "orch@127.0.0.1", "state": "degraded", "distribution": "configured",
            "nodes": [
                ["node": "orch@127.0.0.1", "name": "orch@127.0.0.1", "roles": ["orchestrator"], "state": "ok", "self": .bool(true), "orchestrator": ["capacity": 8, "resident": 1]],
                ["node": "exec@127.0.0.1", "name": "box", "roles": ["executor"], "state": "degraded", "reasons": ["full"], "executor": ["platform": "macos/arm64", "scope_limit": 16, "scopes": ["open": 16]]],
                ["node": "b@x", "name": "gone", "roles": ["executor"], "state": "down", "reason": "timeout"],
            ],
            "placements": ["executors": [["name": "box", "node": "exec@127.0.0.1", "state": "full", "free_scopes": 0]], "pools": [["name": "linux", "state": "ready"]]],
        ]
        let deployment = Deployment(body)
        XCTAssertTrue(deployment.isDistributed)
        XCTAssertEqual(deployment.nodes[1].openScopes, 16)
        XCTAssertEqual(deployment.nodes[2].reasons, ["timeout"])
        XCTAssertEqual(deployment.executors.first?.freeScopes, 0)
        XCTAssertEqual(deployment.pools.first?.choice, .pool("linux"))
    }

    func testASingleMachineDeploymentHasNoPlacementVocabulary() {
        let deployment = Deployment(["self": "nonode@nohost", "host": "mac", "nodes": [["node": "nonode@nohost", "roles": [], "state": "ok", "self": .bool(true)]]])
        XCTAssertFalse(deployment.isDistributed)
        XCTAssertEqual(deployment.selfName, "mac")
    }

    func testBlastRadiusNamesSessionsOnASickNode() {
        let deployment = Deployment(["nodes": [
            ["node": "e@h", "name": "box", "roles": ["executor"], "state": "down", "reason": "timeout"],
            ["node": "o@h", "name": "orch", "roles": ["orchestrator"], "state": "ok"],
        ]])
        let hit = Mission.blastRadius(nodes: deployment.nodes, sessions: [record(["executor": "box"]), record()])
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit.first?.sessions.count, 1)
    }

    func testAnUnknownActivityIsNotDrawnAsIdle() {
        let row = SessionActivity(["session_id": "a", "state": "unknown"])!
        let card = Mission.cards(sessions: [record(["status": ["state": "resident", "incarnation": "i"]])], activity: ["a": row])
        XCTAssertEqual(card.first?.liveness, .unknown)
    }

    func testARemoteEscalationEchoesItsOwnSeqAndOnlyAdmittedGrants() {
        var state = Conversation(sessionID: session)
        let admitted: JSONValue = ["type": "writable_root", "path": "/a"]
        let outside: JSONValue = ["type": "env", "name": "SECRET"]
        let cell: JSONValue = [
            "namespace": "fact.custom", "key": "remote-escalation/box/e1", "seq": 900,
            "value": [
                "escalation_id": "box/e1", "seq": 12, "status": "pending", "placement": "box",
                "tool": "fs_write", "action": "d", "strand": "sub:x",
                "denial": ["reason": "r", "source": "policy", "wanted": [admitted, outside]],
                "admitted": [admitted],
            ],
        ]
        state.apply(cut: cut(entries: [], leaf: nil, extraCells: [cell]))
        let record = state.escalations.first
        XCTAssertEqual(record?.seq, 12)
        XCTAssertEqual(record?.placement, "box")
        XCTAssertEqual(record?.grants, [admitted])
        XCTAssertEqual(record?.outsideCeiling, ["Environment variable SECRET"])
    }

    func testRemoteChildrenAndAPeekFold() {
        var state = Conversation(sessionID: session)
        state.apply(push: EventEnvelope(replyTo: nil, event: "snapshot", seq: nil, body: [
            "mode": "remote_children",
            "remote_children": [["id": "sub:^main/b-1", "parent": "main", "orchestrator": "box", "standing": "running", "title": "build", "summary": "", "tokens": 5, "model": "fast", "age_ms": .null]],
        ]))
        XCTAssertEqual(state.remoteChildren.first?.orchestrator, "box")
        XCTAssertEqual(state.remoteChildren.first?.isActive, true)

        state.beginPeek(child: "sub:^main/b-1")
        XCTAssertEqual(state.peek?.isPending, true)
        let entry = message("e", parent: nil, ["role": "assistant", "content": [["type": "text", "text": "hi"]]])
        state.apply(push: EventEnvelope(replyTo: nil, event: "snapshot", seq: nil, body: [
            "mode": "child_history", "board": ["status": "ready", "entries": [entry], "next": .null],
        ]))
        XCTAssertEqual(state.peek?.rows.count, 1)
    }
}

final class SessionGrantTests: XCTestCase {
    private func record(_ grants: [JSONValue]) -> Escalation {
        Escalation(id: "e", seq: 1, status: "pending", strand: "main", tool: "t", action: "a", preview: "", reason: "", source: "policy", grants: grants)
    }

    func testOnlyPersistentGrantsCanBeRemembered() {
        XCTAssertTrue(record([["type": "writable_root", "path": "/a"]]).canRemember)
        XCTAssertTrue(record([["type": "network", "network": ["mode": "full"]]]).canRemember)
        XCTAssertFalse(record([["type": "network", "network": ["mode": "proxy"]]]).canRemember)
        XCTAssertFalse(record([["type": "env", "name": "X"]]).canRemember)
    }

    func testAMixedRequestStaysOnceOnly() {
        XCTAssertFalse(record([["type": "writable_root", "path": "/a"], ["type": "env", "name": "X"]]).canRemember)
        XCTAssertFalse(record([]).canRemember)
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

    func testRemoteAddresses() throws {
        XCTAssertNoThrow(try DaemonEndpoint(address: "wss://box.ts.net/v2/control", token: "t").url(path: "/v2/control"))
        XCTAssertNoThrow(try DaemonEndpoint(address: "ws://127.0.0.1:7441/v2/control", token: "t").url(path: "/v2/control"))
        XCTAssertThrowsError(try DaemonEndpoint(address: "ws://box.ts.net/v2/control", token: "t").url(path: "/v2/control"))
        XCTAssertThrowsError(try DaemonEndpoint(address: "wss://h", token: "loomclaim_abc"))
        XCTAssertThrowsError(try DaemonEndpoint(address: "http://h", token: "t"))
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
            escalations: [:]
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
            escalations: [:]
        )
        XCTAssertEqual(items.map(\.kind), [.failed])
    }

    func testAnUnrecognizedActivityStateReadsAsUnknown() {
        XCTAssertEqual(activity("a", "brand_new_state").state, .unknown)
    }

    func testASickMachineSurfacesOnlyWithDependents() {
        let deployment = Deployment(["nodes": [["node": "e@h", "name": "box", "roles": ["executor"], "state": "down", "reason": "timeout"]]])
        let session = record("a", state: ["state": "saved"])
        let node = deployment.nodes[0]
        XCTAssertEqual(Mission.attention(sessions: [], activity: [:], escalations: [:], unhealthy: [(node, [session])]).map(\.kind), [.machine])
        XCTAssertTrue(Mission.attention(sessions: [], activity: [:], escalations: [:], unhealthy: [(node, [])]).isEmpty)
    }
}
