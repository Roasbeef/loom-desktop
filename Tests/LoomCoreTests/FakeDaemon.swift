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
    /// One block of an assistant message, in the order the provider wrote it.
    enum Block: Equatable {
        case thinking(String)
        case text(String)
        case tool(id: String, name: String, arguments: String)

        var label: String {
            switch self {
            case .thinking(let text): return "th:" + text
            case .text(let text): return "a:" + text
            case .tool(_, let name, _): return "tool:" + name
            }
        }
    }

    struct Entry: Equatable {
        let id: String
        let seq: Int
        let parent: String?
        let strand: String
        /// `user`, `assistant` or `toolResult`.
        let role: String
        let text: String
        /// An assistant message's blocks, which `text` is the text of.
        var blocks: [Block] = []
        var stopReason: String?
        var errorMessage: String?
        var toolCallID: String?
    }

    struct LastResult: Equatable {
        let outcome: String
        let error: String?
        var op = ""
    }

    struct Streamed: Equatable {
        var text = ""
        var thinking = ""
        var fragments = 0
    }

    /// What becomes of one provider request.
    enum Fate: Equatable {
        /// It completes, and its entry lands.
        case lands
        /// The person stops it: the stream ends, and an entry marked aborted lands with what was written.
        case aborts
        /// The provider fails after some output: the stream ends and an entry carrying the error lands.
        case failsWithEntry
        /// The provider fails and no entry is ever published: the stream ends and the strand's last result says failed.
        case failsWithoutEntry
    }

    /// One fragment the daemon will push, with the block it belongs to.
    struct Piece: Equatable {
        let block: Int
        let kind: String
        let text: String
        let callID: String?
        let toolName: String?
    }

    struct Operation: Equatable {
        var strand: String
        var id: String
        /// Requests still to make, the first being the one in progress.
        var plans: [(blocks: [Block], fate: Fate)] = []
        var generation = ""
        var reserved = ""
        var pieces: [Piece] = []
        var cursor = 0
        var ended = false
        /// The request's entry has landed and a tool is running, whose result is next.
        var awaitingResult: (id: String, name: String)?
        var requests = 0

        static func == (lhs: Operation, rhs: Operation) -> Bool {
            lhs.strand == rhs.strand && lhs.id == rhs.id && lhs.generation == rhs.generation && lhs.cursor == rhs.cursor
                && lhs.ended == rhs.ended && lhs.pieces == rhs.pieces && lhs.plans.count == rhs.plans.count
        }
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
    var operations: [String: Operation] = [:]
    /// The main strand's operation, for a test that reads one.
    var operation: Operation? { operations["main"] }
    /// What each strand's last operation came to, as the strand's `last_result` cell says.
    var lastResult: [String: LastResult] = [:]

    /// The operation-keyed copy of each terminal result, which the daemon writes beside `strand.last_result`
    /// and never overwrites.
    var operationResults: [String: LastResult] = [:]

    private mutating func record(_ result: LastResult, strand: String, op: String) {
        var keyed = result
        keyed.op = op
        lastResult[strand] = keyed
        operationResults[op] = keyed
    }
    /// The text each generation was streamed as, which the client should hold when its stream ends.
    var streamed: [String: Streamed] = [:]
    private var salt: UInt64 = 0x9E37_79B9_7F4A_7C15
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
        if command == "steer" || operations[strand] == nil {
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

    private func resultValue(_ result: LastResult, op: String) -> JSONValue {
        var value: [String: JSONValue] = ["kind": "run", "operationId": .string(op), "outcome": .string(result.outcome)]
        if let error = result.error { value["error"] = ["message": .string(error)] }
        return .object(value)
    }

    private func metadata() -> JSONValue {
        var cells: [JSONValue] = []
        for strand in strands {
            cells.append(["namespace": "strand.config", "key": .string(strand), "seq": 1, "value": ["model": ["modelId": "fake"]]])
            cells.append(["namespace": "strand.leaf", "key": .string(strand), "seq": 2, "value": leaf[strand].map { .string($0) } ?? .null])
            if let operation = operations[strand] {
                cells.append(["namespace": "strand.state", "key": .string(strand), "seq": 3, "value": ["currentOperationId": .string(operation.id)]])
            }
            if let result = lastResult[strand] {
                cells.append(["namespace": "strand.last_result", "key": .string(strand), "seq": 4, "value": resultValue(result, op: result.op)])
            }
        }
        for (op, result) in operationResults.sorted(by: { $0.key < $1.key }) {
            cells.append(["namespace": "fact.custom", "key": .string("operation-result/\(op)"), "seq": 5, "value": resultValue(result, op: op)])
        }
        let pending: [JSONValue] = held.map {
            ["id": .string($0.id), "strand": .string($0.strand), "kind": "prompt", "text": .string($0.text), "editable": .bool(true), "revision": 1]
        }
        return ["cells": .array(cells), "peers": [], "usage": .null, "pending_inputs": .array(pending)]
    }

    private func entryJSON(_ entry: Entry) -> JSONValue {
        var message: JSONValue
        switch entry.role {
        case "user":
            message = ["role": "user", "content": [["type": "text", "text": .string(entry.text)]], "origin": ["name": "owner"]]
        case "toolResult":
            message = [
                "role": "toolResult", "toolCallId": .string(entry.toolCallID ?? ""), "isError": .bool(false),
                "content": [["type": "text", "text": .string(entry.text)]],
            ]
        default:
            let content: [JSONValue] = entry.blocks.map { block in
                switch block {
                case .text(let text): return ["type": "text", "text": .string(text)]
                case .thinking(let text): return ["type": "thinking", "thinking": .string(text)]
                case .tool(let id, let name, let arguments):
                    let parsed = (try? JSONValue.parse(Data(arguments.utf8))) ?? .object([:])
                    return ["type": "toolCall", "id": .string(id), "name": .string(name), "arguments": parsed]
                }
            }
            var fields: [String: JSONValue] = ["role": "assistant", "content": .array(content)]
            if let stop = entry.stopReason { fields["stopReason"] = .string(stop) }
            if let error = entry.errorMessage { fields["errorMessage"] = .string(error) }
            message = .object(fields)
        }
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

    /// The text a reply is made of: markdown with a code fence, multi-byte text with an emoji sequence and a
    /// combining mark, plain lines, and one long enough to pass the stream flush's pace steps.
    static let corpus: [String] = [
        "Here is the plan:\n\n```swift\nlet x = 1\nprint(x)\n```\n\nThen we run it.",
        "日本語のテキスト, an emoji 👩🏽‍💻🎉 and a combined é, ok.",
        "- item one\n- item *two* with `code`\n\n> a quote\n",
        "short",
        String(repeating: "A longer reply goes on and on, in plain words. ", count: 120),
    ]

    private mutating func pick(_ n: Int) -> Int {
        salt = salt &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((salt >> 33) % UInt64(max(1, n)))
    }

    /// Cuts `text` at scalar boundaries, which can fall inside a grapheme such as an emoji sequence or a
    /// letter and its accent, into pieces of random length.
    private mutating func split(_ text: String, block: Int, kind: String, callID: String? = nil, name: String? = nil) -> [Piece] {
        let scalars = Array(text.unicodeScalars)
        var pieces: [Piece] = []
        var index = 0
        let widest = scalars.count > 1_000 ? 600 : 7
        while index < scalars.count {
            let length = min(scalars.count - index, 1 + pick(widest))
            var piece = String.UnicodeScalarView()
            piece.append(contentsOf: scalars[index..<index + length])
            pieces.append(Piece(block: block, kind: kind, text: String(piece), callID: callID, toolName: name))
            index += length
        }
        return pieces
    }

    private mutating func startOperation(strand: String) {
        counter += 1
        var op = Operation(strand: strand, id: "op-\(counter)")

        // A turn is one or more provider requests. A request that calls a tool is followed by its result and
        // another request. The fate of the turn is decided by its last request.
        let shape = pick(10)
        let blocksFor: (inout FakeDaemon, Bool) -> [Block] = { daemon, withTool in
            var blocks: [Block] = []
            if daemon.pick(2) == 0 { blocks.append(.thinking(Self.corpus[daemon.pick(Self.corpus.count - 1)])) }
            blocks.append(.text(Self.corpus[daemon.pick(Self.corpus.count)]))
            if withTool {
                daemon.counter += 1
                blocks.append(.tool(id: "call-\(daemon.counter)", name: ["bash", "fs_read", "todo"][daemon.pick(3)], arguments: "{\"command\":\"echo \(daemon.counter) \u{2713}\"}"))
            }
            return blocks
        }
        switch shape {
        case 0, 1, 2, 3:
            op.plans = [(blocksFor(&self, false), .lands)]
        case 4, 5:
            op.plans = [(blocksFor(&self, true), .lands), (blocksFor(&self, false), .lands)]
        case 6:
            op.plans = [(blocksFor(&self, false), .aborts)]
        case 7:
            op.plans = [(blocksFor(&self, false), .failsWithEntry)]
        case 8:
            op.plans = [(blocksFor(&self, false), .failsWithoutEntry)]
        default:
            op.plans = [(blocksFor(&self, true), .lands), (blocksFor(&self, false), .aborts)]
        }
        operations[strand] = op
        beginRequest(strand: strand)
    }

    /// Prepares the next provider request of an operation: its identity and the fragments it will push.
    private mutating func beginRequest(strand: String) {
        guard var op = operations[strand], let plan = op.plans.first else { return }
        counter += 1
        op.requests += 1
        op.reserved = "r\(counter)"
        op.generation = "[\"generation\",\"step-\(counter)\",0,\"\(op.reserved)\"]"
        var pieces: [Piece] = []
        for (index, block) in plan.blocks.enumerated() {
            switch block {
            case .thinking(let text): pieces += split(text, block: index, kind: "thinking")
            case .text(let text): pieces += split(text, block: index, kind: "text")
            case .tool(let id, let name, let arguments): pieces += split(arguments, block: index, kind: "tool_call", callID: id, name: name)
            }
        }

        // A request that does not complete is cut part of the way through what it would have written.
        if plan.fate != .lands { pieces = Array(pieces.prefix(max(1, pieces.count / 2))) }
        op.pieces = pieces
        op.cursor = 0
        op.ended = false
        streamed[op.generation] = Streamed()
        operations[strand] = op
    }

    func committedNotice() -> String {
        Frames.envelope(replyTo: nil, event: "committed", seq: nextSeq - 1, body: ["strand": "main"])
    }

    // MARK: What the world does on its own

    /// The strands that have an operation running, in a fixed order.
    var activeStrands: [String] { operations.keys.sorted() }

    /// Advances one running operation by one step: a fragment, the end of the stream, the landing of the
    /// request's entry, or a tool's result. `choice` picks which strand moves when two are running.
    /// Returns the pushes, in the order the daemon writes them.
    mutating func progress(choice: Int) -> [String] {
        let active = activeStrands
        guard !active.isEmpty else { return [] }
        let strand = active[choice % active.count]
        guard var op = operations[strand], let plan = op.plans.first else { return [] }
        version += 1

        // A tool's result lands after the entry that called it, and the next request follows.
        if let call = op.awaitingResult {
            var tail: [String] = []
            counter += 1
            append(Entry(id: "t\(counter)", seq: nextSeq, parent: leaf[strand], strand: strand, role: "toolResult", text: "ran \(call.name)", toolCallID: call.id))
            op.awaitingResult = nil
            op.plans.removeFirst()
            operations[strand] = op
            beginRequest(strand: strand)
            tail.append(committedNotice())
            return tail
        }

        // Fragments, then the end of the stream.
        if op.cursor < op.pieces.count {
            let piece = op.pieces[op.cursor]
            op.cursor += 1
            var generation = streamed[op.generation] ?? Streamed()
            generation.fragments += 1
            switch piece.kind {
            case "text": generation.text += piece.text
            case "thinking": generation.thinking += piece.text
            default: break
            }
            streamed[op.generation] = generation
            operations[strand] = op
            var body: [String: JSONValue] = [
                "strand": .string(strand), "op": .string(op.id), "ephemeral": .bool(true),
                "generation": .string(op.generation), "kind": .string(piece.kind),
            ]
            if piece.kind == "tool_call" {
                body["call_id"] = .string(piece.callID ?? "")
                body["tool_name"] = .string(piece.toolName ?? "")
                body["arguments_fragment"] = .string(piece.text)
            } else {
                body["text"] = .string(piece.text)
            }
            return [Frames.envelope(replyTo: nil, event: "stream_delta", body: .object(body))]
        }
        if !op.ended {
            op.ended = true
            operations[strand] = op
            return [Frames.envelope(replyTo: nil, event: "stream_delta", body: [
                "strand": .string(strand), "op": .string(op.id), "ephemeral": .bool(true),
                "generation": .string(op.generation), "kind": "end",
            ])]
        }

        // The request's entry lands after its stream ended, as the daemon publishes it, unless it never will.
        let written = writtenBlocks(plan.blocks, pieces: op.pieces)
        var frames: [String] = []
        switch plan.fate {
        case .failsWithoutEntry:
            record(LastResult(outcome: "failed", error: "the provider request failed"), strand: strand, op: op.id)
            return finish(strand: strand, frames: [committedNotice()])
        case .lands, .aborts, .failsWithEntry:
            var entry = Entry(
                id: op.reserved, seq: nextSeq, parent: leaf[strand], strand: strand, role: "assistant",
                text: written.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined(), blocks: written
            )
            if plan.fate == .aborts { entry.stopReason = "aborted" }
            if plan.fate == .failsWithEntry { entry.errorMessage = "the provider request failed" }
            append(entry)
            frames.append(committedNotice())
        }
        if plan.fate != .lands {
            record(LastResult(outcome: plan.fate == .aborts ? "aborted" : "failed", error: plan.fate == .aborts ? nil : "the provider request failed"), strand: strand, op: op.id)
            return finish(strand: strand, frames: frames)
        }
        if let tool = written.compactMap({ block -> (String, String)? in if case .tool(let id, let name, _) = block { return (id, name) } else { return nil } }).first {
            op.awaitingResult = (tool.0, tool.1)
            operations[strand] = op
            frames.append(Frames.envelope(replyTo: nil, event: "tool_output", body: [
                "strand": .string(strand), "op": .string(op.id), "step": "step", "source_index": 0, "ephemeral": .bool(true),
                "stream": "stdout", "tail": "running", "total_bytes": 7,
            ]))
            return frames
        }
        record(LastResult(outcome: "completed", error: nil), strand: strand, op: op.id)
        return finish(strand: strand, frames: frames)
    }

    /// What a request wrote: the blocks it would have written when it completes, and for a request that was
    /// cut, the blocks rebuilt from the fragments that were pushed.
    private func writtenBlocks(_ planned: [Block], pieces: [Piece]) -> [Block] {
        var texts: [Int: String] = [:]
        for piece in pieces { texts[piece.block, default: ""] += piece.text }
        return planned.enumerated().compactMap { index, block in
            guard let text = texts[index] else { return nil }
            switch block {
            case .thinking: return .thinking(text)
            case .text: return .text(text)
            case .tool(let id, let name, _): return .tool(id: id, name: name, arguments: text)
            }
        }
    }

    /// The operation is over. The next prompt held for the strand starts.
    private mutating func finish(strand: String, frames: [String]) -> [String] {
        operations[strand] = nil
        var frames = frames
        if let index = held.firstIndex(where: { $0.strand == strand }) {
            let next = held.remove(at: index)
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
