import Foundation

/// One strand of a session, as the metadata cut describes it.
public struct Strand: Sendable, Equatable, Identifiable {
    public let id: String
    public var model: String?
    public var leaf: String?
    public var currentOperation: String?
    public var lastOutcome: String?

    public var isBusy: Bool { currentOperation != nil }
}

/// A person or client attached to the session right now.
public struct Peer: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let role: String
}

/// Input the host holds until its strand can take it.
public struct PendingInput: Sendable, Equatable, Identifiable {
    public let id: String
    public let strand: String
    public let kind: String
    public let text: String
}

/// What a provider request has streamed so far. Deltas are ephemeral and never
/// part of durable history, so this is display state only.
public struct LiveStream: Sendable, Equatable {
    public var generation: String?
    public var text = ""
    public var thinking = ""
    public var tools: [LiveTool] = []
    public var ended = false

    public struct LiveTool: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public var arguments: String
    }
}

/// One row of the drawn transcript.
public struct TranscriptRow: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case user(text: String, author: String?)
        case assistant(text: String)
        case thinking(text: String)
        case tool(name: String, arguments: JSONValue, result: String?, isError: Bool)
        case notice(text: String)
        case failure(text: String)
    }

    public let id: String
    public let kind: Kind
}

/// The client's whole view of one session, kept as a pure value.
///
/// Every transition is a function of a completed cut or one pushed frame, so
/// the projection can be tested from captured frames with no socket. A cut's
/// metadata replaces what the last cut said, and its entries merge by id,
/// because overlapping catch-up intervals are legal.
public struct Conversation: Sendable, Equatable {
    public let sessionID: String
    public private(set) var role = ""
    public private(set) var connectionID = ""
    public private(set) var oldestSeq: Int?
    public private(set) var strands: [Strand] = []
    public private(set) var escalations: [Escalation] = []
    public private(set) var peers: [Peer] = []
    public private(set) var pendingInputs: [PendingInput] = []
    public private(set) var usage: JSONValue = .null
    public private(set) var branch: String?
    public private(set) var streams: [String: LiveStream] = [:]
    public private(set) var toolTails: [String: String] = [:]
    public private(set) var worktree: JSONValue?
    public private(set) var notices: [String] = []
    public private(set) var hasAdoptedCut = false

    private var entries: [String: JSONValue] = [:]

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    public var entryCount: Int { entries.count }

    /// Total spend reported for the session, when the provider priced it.
    public var totalCost: Double? { usage["cost"]?["total"]?.double }

    public var totalTokens: Int? { usage["totalTokens"]?.int }

    // MARK: Transitions

    /// Adopts one completed transfer.
    public mutating func apply(cut: Cut) {
        role = cut.identity.role
        connectionID = cut.identity.connectionID
        hasAdoptedCut = true

        var landed = false
        for entry in cut.entries {
            guard let id = entry["id"]?.string, entries[id] == nil else { continue }
            entries[id] = entry
            landed = true
        }
        if let oldest = cut.oldestSeq {
            oldestSeq = min(oldestSeq ?? oldest, oldest)
        }

        // A history page fills in older entries beside the live window, so its
        // metadata must not stand in for the newer cut already adopted.
        guard cut.window != "history", cut.window != "lineage" else { return }
        applyMetadata(cut.metadata)

        // An ended stream stays drawn until its durable entry lands, or the
        // reply would vanish for the moment between `end` and this cut.
        if landed {
            streams = streams.filter { !$0.value.ended }
        }
    }

    /// Folds one uncorrelated frame. An unknown event is ignored by rule.
    public mutating func apply(push frame: EventEnvelope) {
        switch frame.event {
        case "stream_delta":
            applyDelta(frame.body)
        case "presence":
            peers = (frame.body["peers"]?.array ?? []).compactMap(Self.peer)
        case "tool_output":
            if let call = frame.body["call_id"]?.string, let tail = frame.body["tail"]?.string {
                toolTails[call] = tail
            }
        case "snapshot":
            if frame.body["mode"]?.string == "worktree_diff" {
                worktree = frame.body["board"]
            }
        case "error":
            notices.append(frame.body["message"]?.string ?? "The daemon reported an error.")
        default:
            break
        }
    }

    /// Clears the connection-level errors already shown.
    public mutating func clearNotices() {
        notices = []
    }

    private mutating func applyDelta(_ body: JSONValue) {
        guard let strand = body["strand"]?.string else { return }
        let generation = body["generation"]?.string
        var stream = streams[strand] ?? LiveStream()

        // A new generation replaces every old fragment on the strand.
        if stream.generation != generation {
            stream = LiveStream(generation: generation)
        }
        switch body["kind"]?.string {
        case "text":
            stream.text += body["text"]?.string ?? ""
        case "thinking":
            stream.thinking += body["text"]?.string ?? ""
        case "tool_call":
            let id = body["call_id"]?.string ?? ""
            let fragment = body["arguments_fragment"]?.string ?? ""
            if let index = stream.tools.firstIndex(where: { $0.id == id }) {
                stream.tools[index].arguments += fragment
            } else {
                stream.tools.append(.init(id: id, name: body["tool_name"]?.string ?? "tool", arguments: fragment))
            }
        case "end":
            stream.ended = true
        default:
            break
        }
        streams[strand] = stream
    }

    private mutating func applyMetadata(_ metadata: JSONValue) {
        let cells = metadata["cells"]?.array ?? []
        func value(_ namespace: String, _ key: String) -> JSONValue? {
            cells.first { $0["namespace"]?.string == namespace && $0["key"]?.string == key }?["value"]
        }

        strands = cells
            .filter { $0["namespace"]?.string == "strand.config" }
            .compactMap { cell -> Strand? in
                guard let id = cell["key"]?.string else { return nil }
                return Strand(
                    id: id,
                    model: cell["value"]?["model"]?["modelId"]?.string,
                    leaf: value("strand.leaf", id)?.string,
                    currentOperation: value("strand.state", id)?["currentOperationId"]?.string,
                    lastOutcome: value("strand.last_result", id)?["outcome"]?.string
                )
            }
            .sorted { lhs, rhs in lhs.id == "main" ? true : (rhs.id == "main" ? false : lhs.id < rhs.id) }

        escalations = cells
            .filter {
                $0["namespace"]?.string == "fact.custom"
                    && ($0["key"]?.string?.hasPrefix("escalation/") ?? false)
            }
            .compactMap(Self.escalation)
            .filter { $0.status == "pending" }

        peers = (metadata["peers"]?.array ?? []).compactMap(Self.peer)
        usage = metadata["usage"] ?? .null
        branch = value("fact.custom", "client/peers/git-observation")?["repository"]?["branch"]?.string
        pendingInputs = (metadata["pending_inputs"]?.array ?? []).compactMap { row in
            guard let id = row["id"]?.string else { return nil }
            return PendingInput(
                id: id,
                strand: row["strand"]?.string ?? "",
                kind: row["kind"]?.string ?? "",
                text: row["text"]?.string ?? ""
            )
        }
    }

    private static func peer(_ row: JSONValue) -> Peer? {
        guard let id = row["connection_id"]?.string else { return nil }
        return Peer(id: id, name: row["origin"]?["name"]?.string ?? "Unknown", role: row["role"]?.string ?? "")
    }

    /// Reads one escalation cell. The sequence an approval echoes is the
    /// cell's own register sequence.
    static func escalation(_ cell: JSONValue) -> Escalation? {
        guard let value = cell["value"], let seq = cell["seq"]?.int else { return nil }
        let key = cell["key"]?.string ?? ""

        // The durable record's identity must agree with its register key.
        guard let id = value["id"]?.string, key == "escalation/\(id)" else { return nil }
        let denial = value["denial"]
        return Escalation(
            id: id,
            seq: seq,
            status: value["status"]?.string ?? "",
            strand: value["scope"]?["strand"]?.string ?? "",
            tool: value["tool"]?.string ?? "",
            action: value["action"]?.string ?? "",
            preview: value["preview"]?.string ?? "",
            reason: denial?["reason"]?.string ?? "",
            source: denial?["source"]?.string ?? "",
            grants: (denial?["wanted"]?.array ?? []).compactMap(Escalation.wireGrant),
            untranslatableGrants: (denial?["wanted"]?.array ?? []).filter { Escalation.wireGrant($0) == nil }.count
        )
    }

    // MARK: Projection

    /// Draws one strand by walking parents from its leaf.
    ///
    /// The window is not a parent closure, so the walk stops at the first entry
    /// not held, and `hasOlder` says more can be paged in. Walking the chain
    /// rather than sorting by sequence is what keeps another strand's entries
    /// and an abandoned branch out of this transcript.
    public func rows(strand: String) -> [TranscriptRow] {
        guard let leaf = strands.first(where: { $0.id == strand })?.leaf else { return [] }

        var chain: [JSONValue] = []
        var cursor: String? = leaf
        while let id = cursor, let entry = entries[id] {
            chain.append(entry)
            cursor = entry["parentId"]?.string
        }

        var rows: [TranscriptRow] = []
        var toolIndex: [String: Int] = [:]
        for entry in chain.reversed() {
            Self.append(entry, to: &rows, toolIndex: &toolIndex)
        }
        return rows
    }

    /// Whether this strand's chain continues below what is held. Asking the
    /// chain itself means the answer cannot go stale as pages arrive.
    public func hasOlder(strand: String) -> Bool {
        var cursor = strands.first { $0.id == strand }?.leaf
        while let id = cursor {
            guard let entry = entries[id] else { return true }
            cursor = entry["parentId"]?.string
        }
        return false
    }

    private static func append(_ entry: JSONValue, to rows: inout [TranscriptRow], toolIndex: inout [String: Int]) {
        let id = entry["id"]?.string ?? UUID().uuidString
        switch entry["type"]?.string {
        case "message":
            appendMessage(entry["message"], id: id, to: &rows, toolIndex: &toolIndex)
        case "compaction":
            rows.append(.init(id: id, kind: .notice(text: "Earlier conversation compacted.")))
        case "branch_summary":
            rows.append(.init(id: id, kind: .notice(text: "Returned from another branch.")))
        case "custom":
            break
        case "oversized":
            rows.append(.init(id: id, kind: .notice(text: "A record of \(entry["size"]?.int ?? 0) bytes was left out.")))
        case let other:
            // The type set is closed, so an unknown type is corruption and is
            // shown as such rather than skipped (protocol section 5.7).
            rows.append(.init(id: id, kind: .failure(text: "Unrecognized entry type \(other ?? "none").")))
        }
    }

    private static func appendMessage(
        _ message: JSONValue?,
        id: String,
        to rows: inout [TranscriptRow],
        toolIndex: inout [String: Int]
    ) {
        let blocks = message?["content"]?.array ?? []
        switch message?["role"]?.string {
        case "user":
            let origin = message?["origin"]
            let author = origin?["name"]?.string ?? origin?["strand"]?.string
            let body = text(of: blocks)

            // The harness writes its own notes into the conversation as user
            // turns with no author. Drawing one as a person's message would put
            // words in their mouth.
            if author == nil, body.hasPrefix("[loom] ") {
                rows.append(.init(id: id, kind: .notice(text: String(body.dropFirst(7)))))
            } else {
                rows.append(.init(id: id, kind: .user(text: body, author: author)))
            }

        case "assistant":
            for (index, block) in blocks.enumerated() {
                let rowID = "\(id)/\(index)"
                switch block["type"]?.string {
                case "text":
                    rows.append(.init(id: rowID, kind: .assistant(text: block["text"]?.string ?? "")))
                case "thinking":
                    if block["redacted"]?.bool != true, let thinking = block["thinking"]?.string, !thinking.isEmpty {
                        rows.append(.init(id: rowID, kind: .thinking(text: thinking)))
                    }
                case "toolCall":
                    // A pushed `entry` event nests the call, while a transfer
                    // carries the durable record, which inlines it.
                    let call = block["toolCall"] ?? block
                    if let callID = call["id"]?.string { toolIndex[callID] = rows.count }
                    rows.append(.init(id: rowID, kind: .tool(
                        name: call["name"]?.string ?? "tool",
                        arguments: call["arguments"] ?? .null,
                        result: nil,
                        isError: false
                    )))
                default:
                    break
                }
            }
            if let error = message?["errorMessage"]?.string {
                rows.append(.init(id: "\(id)/error", kind: .failure(text: error)))
            }

        case "toolResult":
            // A result folds into the row of the call it answers.
            let result = text(of: blocks)
            let failed = message?["isError"]?.bool ?? false
            if let callID = message?["toolCallId"]?.string, let index = toolIndex[callID],
               case .tool(let name, let arguments, _, _) = rows[index].kind {
                rows[index] = .init(id: rows[index].id, kind: .tool(name: name, arguments: arguments, result: result, isError: failed))
            } else {
                rows.append(.init(id: id, kind: .tool(
                    name: message?["toolName"]?.string ?? "tool",
                    arguments: .null,
                    result: result,
                    isError: failed
                )))
            }

        default:
            break
        }
    }

    private static func text(of blocks: [JSONValue]) -> String {
        blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
    }
}
