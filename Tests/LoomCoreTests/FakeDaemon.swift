import Foundation
import LoomKit

/// A simulated daemon's session half: one session, entries with parents and sequence
/// numbers, a metadata document, a running operation that streams, held inputs, and the
/// session socket's rules.
///
/// It is the world the core runs in, not a mock of the core. It answers whatever
/// request is outstanding, as Loom's generated server does, so any sub-list of a
/// schedule is still a valid schedule. It is as strict as the real daemon where a lenient
/// fake would let a lane bug pass: one command in flight per socket, one transfer open at
/// a time (`stale_snapshot`), `snapshot_next` named by index, and an unknown command refused
/// by code. A rule the client breaks is recorded in `violations` with the lane's tag.
///
/// Every state change increments `version`, so a harness can tell an unchanged daemon
/// from a changed one when it checks that an identical cut changes nothing.
struct FakeDaemon: Equatable {
    struct Entry: Equatable {
        let id: String
        let seq: Int
        let parent: String?
        let strand: String
        let role: String
        let text: String
    }

    struct Operation: Equatable {
        var strand: String
        var generation: String
        var reserved: String
        var text: String
        var tokens = 0
        var ended = false
    }

    struct Held: Equatable {
        let id: String
        let strand: String
        let text: String
    }

    /// One fragment of a record, ready to answer a `snapshot_next`.
    struct Fragment: Equatable {
        let record: String
        let kind: String
        let seq: Int?
        let total: Int
        let offset: Int
        let data: String
    }

    struct OpenTransfer: Equatable {
        let id: String
        let nextSeq: Int
        let fragments: [Fragment]
        var index = 0
    }

    /// The socket the lane is attached through. A new attachment is a new socket.
    struct Socket: Equatable {
        var isOpen = true
        var transfer: OpenTransfer?
        /// Replies written and not yet consumed by the client, so a second command
        /// before the first reply is a stop-and-wait violation.
        var owed = 0
        var role = "owner"
    }

    static let fragmentBytes = 40

    var sessionID = "s1"
    var entries: [Entry] = []
    var leaf: [String: String] = [:]
    var nextSeq = 1
    var version = 0
    var operation: Operation?
    var held: [Held] = []
    var applied: [String: Int] = [:]
    var violations: [Sim.Violation] = []
    var socket = Socket()
    var counter = 0
    var strands: [String] = ["main"]
    /// When set, a `recent` transfer carries only this many of the newest entries, as the real window does.
    var recentLimit: Int?
    /// The fragments of each entry, which never change once written, so a transfer does not encode it again.
    var fragmentsByEntry: [String: [Fragment]] = [:]

    mutating func attach() {
        socket = Socket(role: socket.role)
    }

    // MARK: Commands from the client

    /// Answers one command frame. Returns the frames to put on the wire, in order.
    mutating func receive(command text: String) -> [String] {
        guard socket.isOpen, let command = Frames.decode(command: text) else { return [] }
        if socket.owed > 0 {
            violations.append(Sim.Violation("I1", "\(command.cmd) arrived while a reply was still owed"))
        }
        socket.owed += 1
        let id = command.id
        switch command.cmd {
        case "subscribe":
            return beginTransfer(id: id, window: "recent", from: 0)
        case "catch_up":
            return beginTransfer(id: id, window: "catch_up", from: command.body["from_seq"]?.int ?? 0)
        case "history", "history_lineage", "escalations_decided":
            return beginTransfer(id: id, window: command.cmd == "history" ? "history" : command.cmd == "escalations_decided" ? "decided" : "lineage", from: .max)
        case "snapshot_next":
            return nextFragment(id: id, body: command.body)
        case "prompt", "steer":
            return mutate(id: id, command: command.cmd, body: command.body)
        case "abort":
            applied["abort", default: 0] += 1
            return [Frames.envelope(replyTo: id, event: "ack", body: ["status": "admitted"])]
        case "notes", "models", "block_summaries", "profile_get":
            return [Frames.envelope(replyTo: id, event: "snapshot", body: ["mode": .string(command.cmd)])]
        default:
            return [Frames.error(replyTo: id, code: "unknown_command")]
        }
    }

    /// Records that the client consumed (or the harness dropped) a reply.
    mutating func replyConsumed() {
        socket.owed = max(0, socket.owed - 1)
    }

    private mutating func mutate(id: Int, command: String, body: JSONValue) -> [String] {
        let strand = body["strand"]?.string ?? "main"
        let text = body["text"]?.string ?? ""
        guard strands.contains(strand) else { return [Frames.error(replyTo: id, code: "unknown_strand", message: "no such strand")] }
        applied["\(command):\(text)", default: 0] += 1
        version += 1
        if command == "steer" || operation == nil {
            land(user: text, strand: strand)
            if command == "prompt" { startOperation(strand: strand) }
            return [Frames.envelope(replyTo: id, event: "ack", body: ["status": "admitted"])] + [committedNotice()]
        }
        counter += 1
        held.append(Held(id: "h\(counter)", strand: strand, text: text))
        return [Frames.envelope(replyTo: id, event: "ack", body: ["status": "queued"]), Frames.envelope(replyTo: nil, event: "input_queue_changed")]
    }

    // MARK: Transfers

    private mutating func beginTransfer(id: Int, window: String, from: Int) -> [String] {
        if socket.transfer != nil {
            violations.append(Sim.Violation("I1", "a transfer began while one was open"))
            return [Frames.error(replyTo: id, code: "stale_snapshot", message: "finish the current transfer or subscribe first")]
        }
        counter += 1
        let snapshot = "x\(counter)"
        var fragments = Self.fragments(record: "metadata", kind: "metadata", seq: nil, payload: metadata())
        let served = window == "recent" ? Array(entries.suffix(recentLimit ?? entries.count)) : entries
        if window != "decided" {
            for entry in served where window == "history" ? false : entry.seq >= from {
                fragments += fragmentsByEntry[entry.id] ?? []
            }
        }
        socket.transfer = OpenTransfer(id: snapshot, nextSeq: nextSeq, fragments: fragments)
        return [Frames.begin(replyTo: id, snapshot: snapshot, window: window, nextSeq: nextSeq, session: sessionID, role: socket.role, oldestSeq: window == "history" ? nil : (served.first?.seq ?? 1))]
    }

    private mutating func nextFragment(id: Int, body: JSONValue) -> [String] {
        guard var open = socket.transfer else {
            violations.append(Sim.Violation("I6", "snapshot_next with no open transfer"))
            return [Frames.error(replyTo: id, code: "stale_snapshot")]
        }
        guard body["snapshot_id"]?.string == open.id, body["index"]?.int == open.index else {
            violations.append(Sim.Violation("I6", "snapshot_next named \(body) while \(open.id) expected index \(open.index)"))
            return [Frames.error(replyTo: id, code: "stale_snapshot")]
        }
        if open.index < open.fragments.count {
            let fragment = open.fragments[open.index]
            open.index += 1
            socket.transfer = open
            var chunk: [String: JSONValue] = [
                "snapshot_id": .string(open.id), "index": .int(Int64(open.index - 1)), "record_id": .string(fragment.record),
                "kind": .string(fragment.kind), "total_bytes": .int(Int64(fragment.total)), "offset": .int(Int64(fragment.offset)),
                "data": .string(fragment.data),
            ]
            if let seq = fragment.seq { chunk["record_seq"] = .int(Int64(seq)) }
            return [Frames.envelope(replyTo: id, event: "snapshot_chunk", body: .object(chunk))]
        }
        socket.transfer = nil
        return [Frames.end(replyTo: id, snapshot: open.id, nextSeq: open.nextSeq)]
    }

    // MARK: The session

    private func metadata() -> JSONValue {
        var cells: [JSONValue] = []
        for strand in strands {
            cells.append(["namespace": "strand.config", "key": .string(strand), "seq": 1, "value": ["model": ["modelId": "fake"]]])
            cells.append(["namespace": "strand.leaf", "key": .string(strand), "seq": 2, "value": leaf[strand].map { .string($0) } ?? .null])
            if let operation, operation.strand == strand {
                cells.append(["namespace": "strand.state", "key": .string(strand), "seq": 3, "value": ["currentOperationId": .string("op-\(operation.reserved)")]])
            }
        }
        let pending: [JSONValue] = held.map {
            ["id": .string($0.id), "strand": .string($0.strand), "kind": "prompt", "text": .string($0.text), "editable": .bool(true), "revision": 1]
        }
        return ["cells": .array(cells), "peers": [], "usage": .null, "pending_inputs": .array(pending)]
    }

    private func entryJSON(_ entry: Entry) -> JSONValue {
        let message: JSONValue = entry.role == "user"
            ? ["role": "user", "content": [["type": "text", "text": .string(entry.text)]], "origin": ["name": "owner"]]
            : ["role": "assistant", "content": [["type": "text", "text": .string(entry.text)]]]
        return [
            "id": .string(entry.id), "seq": .int(Int64(entry.seq)), "parentId": entry.parent.map { .string($0) } ?? .null,
            "timestamp": .int(Int64(entry.seq)), "type": "message", "message": message,
        ]
    }

    private mutating func land(user text: String, strand: String) {
        let entry = Entry(id: "u\(nextSeq)", seq: nextSeq, parent: leaf[strand], strand: strand, role: "user", text: text)
        append(entry)
    }

    /// Cuts one record into the fragments a transfer sends, so a record spans several chunks.
    static func fragments(record: String, kind: String, seq: Int?, payload: JSONValue) -> [Fragment] {
        let data = Array(Frames.text(payload).utf8)
        var out: [Fragment] = []
        var offset = 0
        repeat {
            let end = min(offset + fragmentBytes, data.count)
            out.append(Fragment(
                record: record, kind: kind, seq: seq, total: data.count, offset: offset,
                data: Data(data[offset..<end]).base64EncodedString()
            ))
            offset = end
        } while offset < data.count
        return out
    }

    private mutating func append(_ entry: Entry) {
        fragmentsByEntry[entry.id] = Self.fragments(record: entry.id, kind: "entry", seq: entry.seq, payload: entryJSON(entry))
        entries.append(entry)
        leaf[entry.strand] = entry.id
        nextSeq += 1
        version += 1
    }

    private mutating func startOperation(strand: String) {
        counter += 1
        let reserved = "r\(counter)"
        operation = Operation(
            strand: strand,
            generation: "[\"generation\",\"step-\(counter)\",0,\"\(reserved)\"]",
            reserved: reserved, text: "reply \(counter)"
        )
    }

    func committedNotice() -> String {
        Frames.envelope(replyTo: nil, event: "committed", seq: nextSeq - 1, body: ["strand": "main"])
    }

    // MARK: What the world does on its own

    /// Advances the running operation by one step: a token, the end of the stream, or the
    /// landing of the reply's entry. Returns the pushes.
    mutating func progress(choice: Int) -> [String] {
        guard var op = operation else { return [] }
        version += 1
        if !op.ended, op.tokens == 0 || choice % 3 != 0 {
            op.tokens += 1
            operation = op
            return [Frames.envelope(replyTo: nil, event: "stream_delta", body: [
                "strand": .string(op.strand), "generation": .string(op.generation), "kind": "text", "text": .string("tok\(op.tokens) "),
            ])]
        }
        if !op.ended {
            op.ended = true
            operation = op
            return [Frames.envelope(replyTo: nil, event: "stream_delta", body: [
                "strand": .string(op.strand), "generation": .string(op.generation), "kind": "end", "text": "",
            ])]
        }

        // The entry lands after the stream ended, as the daemon publishes it.
        let text = (1...max(1, op.tokens)).map { "tok\($0) " }.joined()
        append(Entry(id: op.reserved, seq: nextSeq, parent: leaf[op.strand], strand: op.strand, role: "assistant", text: text))
        operation = nil
        var frames = [committedNotice()]
        if !held.isEmpty {
            let next = held.removeFirst()
            land(user: next.text, strand: next.strand)
            startOperation(strand: next.strand)
            frames.append(committedNotice())
        }
        return frames
    }

    /// A row on another strand lands, which says nothing about the running reply.
    mutating func unrelatedEntry() -> [String] {
        if !strands.contains("side") { strands.append("side") }
        append(Entry(id: "o\(nextSeq)", seq: nextSeq, parent: leaf["side"], strand: "side", role: "user", text: "side \(nextSeq)"))
        return [committedNotice()]
    }

    /// The main strand's durable rows, as the client should come to show them.
    func chain(strand: String) -> [Entry] {
        var out: [Entry] = []
        var cursor = leaf[strand]
        while let id = cursor, let entry = entries.first(where: { $0.id == id }) {
            out.append(entry)
            cursor = entry.parent
        }
        return out.reversed()
    }
}
