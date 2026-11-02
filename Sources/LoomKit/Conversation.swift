import Foundation

/// One strand of a session, as the metadata cut describes it.
public struct Strand: Sendable, Equatable, Identifiable {
    public let id: String
    public var model: String?
    /// The reasoning level this strand asks models for (`off` through `max`).
    public var thinkingLevel: String?
    public var leaf: String?
    public var currentOperation: String?
    public var lastOutcome: String?
    /// The message of a failed last run, which a strand card gives as the reason.
    public var lastError: String?

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
    /// Whether this client may edit or withdraw the input. The daemon decides per
    /// recipient: only the principal who submitted it can.
    public let editable: Bool
    public let revision: Int?
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

/// A subagent running on another orchestrator.
///
/// It has no strand in this session. These fields are the stub the parent's
/// daemon keeps, so while that orchestrator is unreachable the row keeps its last
/// glance, and `ageMs` says how old that glance is. All of it is model text or
/// configuration from another machine.
public struct RemoteChild: Sendable, Equatable, Identifiable {
    public let id: String
    public let parent: String
    public let orchestrator: String
    public let standing: String
    public let title: String
    public let summary: String
    public let tokens: Int
    public let model: String
    public let ageMs: Int?

    init?(_ row: JSONValue) {
        guard let id = row["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        parent = row["parent"]?.string ?? ""
        orchestrator = row["orchestrator"]?.string ?? ""
        standing = row["standing"]?.string ?? "unknown"
        title = row["title"]?.string ?? id
        summary = row["summary"]?.string ?? ""
        tokens = row["tokens"]?.int ?? 0
        model = row["model"]?.string ?? ""
        ageMs = row["age_ms"]?.int
    }

    public var isActive: Bool { standing == "running" || standing == "starting" }
}

/// One page of a remote child's transcript, or why there is none.
public struct ChildPeek: Sendable, Equatable {
    public let child: String
    public let isPending: Bool
    public let failure: String?
    public let rows: [TranscriptRow]
    public let next: Int?
}

/// A held prompt the daemon returned while it drained.
public struct ReturnedDraft: Sendable, Equatable {
    public let strand: String
    public let text: String
    /// Images the prompt carried, which do not come back with the text.
    public let attachmentCount: Int
}

/// An approval that was answered.
public struct Decision: Sendable, Equatable {
    public let id: String
    public let seq: Int
    public let strand: String
    public let tool: String
    public let summary: String
    /// `approved`, `rejected` or `consumed`, as the ledger records it.
    public let outcome: String
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
        /// A subagent the strand started, left outside the fold so it is not missed.
        case spawned(child: String, purpose: String)
        /// A subagent's report, as `agent_wait` returned it.
        case agentReport(child: String, outcome: String, report: String)
        /// A decided approval, from the session's ledger.
        case decision(tool: String, summary: String, outcome: String)
        /// The memory context the daemon attached to a run: a notes index nobody typed.
        case memory(lines: Int, text: String)
        /// A message another session's strand sent. The daemon stored it and checked its
        /// origin, and does not know that it was read.
        case peer(session: String, strand: String, text: String)
        /// A message another strand of this session sent through the Agency, with the
        /// framing removed and a spawn brief's result contract apart from the sender's words.
        case sibling(strand: String, text: String, trailer: String?)
        /// Advisor traffic, which the harness wrote as a user turn.
        case advisor(frame: AdvisorFrame, body: String)

        /// Whether this row starts a turn of its own: something asked the strand to act.
        public var opensTurn: Bool {
            switch self {
            case .user, .peer, .sibling, .advisor: return true
            default: return false
            }
        }
    }

    public let id: String
    public let kind: Kind
    /// The tool call this row draws, which keys its live output.
    public let callID: String?
    /// When the daemon recorded this row, in milliseconds. Every duration the
    /// transcript states comes from these and never from this client's clock.
    public var at: Int?
    /// When a tool call's result was recorded.
    public var settledAt: Int?
    /// How long a response took, from the record before it to this one.
    public var tookMs: Int?
    /// Images the message carried, which the row names but does not draw.
    public var images = 0
    /// The images of a message or a tool result, with the bytes the record held.
    public var pictures: [ImageBlock] = []
    /// The structured result a tool returned beside its text.
    public var details: JSONValue?
    /// The record's place in the session's sequence, which orders decisions among rows.
    public var seq: Int?
    /// What the request that wrote this message read and wrote of the prompt cache.
    /// Only the first row of an assistant message carries it.
    public var cache: CacheUse?

    public init(id: String, kind: Kind, callID: String? = nil, at: Int? = nil) {
        self.id = id
        self.kind = kind
        self.callID = callID
        self.at = at
    }
}

/// Describes a run of tool calls in the words a person would use.
public enum ToolSummary {
    public enum Status: Sendable, Equatable {
        case running, done, failed
    }

    public static func status(_ rows: [TranscriptRow]) -> Status {
        var failed = false
        for row in rows {
            guard case .tool(_, _, let result, let isError) = row.kind else { continue }
            if result == nil { return .running }
            if isError { failed = true }
        }
        return failed ? .failed : .done
    }

    public static func describe(_ rows: [TranscriptRow]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var failures = 0
        for row in rows {
            guard case .tool(let name, _, _, let isError) = row.kind else { continue }

            // A call that failed did not do what its verb says, so it is counted
            // apart. "Wrote 1 file" must never describe a refused write.
            if isError {
                failures += 1
                continue
            }
            let key = verb(name)
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        // A run still going speaks in the present, so it never claims work is done.
        let isRunning = status(rows) == .running
        func phrase(_ past: String, _ present: String, _ noun: String, _ count: Int) -> String {
            "\(isRunning ? present : past) \(count) \(noun)\(count == 1 ? "" : "s")"
        }
        let parts = order.map { key -> String in
            let count = counts[key] ?? 0
            switch key {
            case "bash": return phrase("ran", "running", "command", count)
            case "write": return phrase("wrote", "writing", "file", count)
            case "edit": return phrase("edited", "editing", "file", count)
            case "read": return phrase("read", "reading", "file", count)
            case "search":
                return isRunning ? "searching" : "searched \(count) time\(count == 1 ? "" : "s")"
            case "code": return phrase("ran", "running", "program", count)
            case "agent": return isRunning ? "coordinating agents" : "coordinated agents"
            default: return isRunning ? "using \(key)" : "used \(key)"
            }
        }
        let failed = failures > 0 ? ["\(failures) call\(failures == 1 ? "" : "s") failed"] : []
        let joined = (parts + failed).joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// What the first call in a run acted on, so a folded run still says what ran.
    public static func firstTarget(_ rows: [TranscriptRow]) -> String? {
        for row in rows {
            guard case .tool(_, let arguments, _, _) = row.kind else { continue }
            for key in ["command", "path", "pattern", "query", "url"] {
                if let value = arguments[key]?.string {
                    return value.split(separator: "\n").first.map(String.init)
                }
            }
        }
        return nil
    }

    private static func verb(_ name: String) -> String {
        switch name {
        case "bash": return "bash"
        case "fs_write": return "write"
        case "fs_edit": return "edit"
        case "fs_read": return "read"
        case "grep", "history_search": return "search"
        case "code_mode": return "code"
        case _ where name.hasPrefix("agent_"): return "agent"
        default: return name
        }
    }
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
    public private(set) var remoteChildren: [RemoteChild] = []
    /// The latest `snapshot` of each mode, as the daemon sent it, for surfaces such as
    /// `notes`, `schedules`, `context` and `live_jobs`.
    public private(set) var surfaces: [String: JSONValue] = [:]
    public private(set) var peek: ChildPeek?
    public private(set) var hasAdoptedCut = false
    /// Approvals already answered, from the session's ledger, keyed by id.
    public private(set) var decisions: [String: Decision] = [:]

    /// Each strand's glance, from its `client/glance/` cell.
    public private(set) var glances: [String: Glance] = [:]
    /// The newest ready `context` board and the words for why it is stale, if
    /// the last read failed. A pending reply changes neither, so a refresh does
    /// not blank a figure the person is looking at.
    public private(set) var context: ContextBoard?
    public private(set) var contextNotice: String?
    /// How many times the daemon has said a surface changed, by event name, so a
    /// view that shows one can read it again when the count moves.
    public private(set) var signals: [String: Int] = [:]
    /// Spend by children on other orchestrators, from the metadata document.
    public private(set) var remoteUsage: [RemoteUsage] = []
    /// Prompts a draining daemon handed back, for the host to put in the editor.
    /// Each is the prompt's last copy, so the host empties the list as it takes them.
    public private(set) var returnedDrafts: [ReturnedDraft] = []
    /// The summarizer's labels for long reasoning blocks, by `entry/block`, which is also the
    /// id of the reasoning row. They are the summarizer's words and never the agent's.
    public private(set) var summaries: [String: String] = [:]
    /// Blocks already asked about on this attachment, so a block with no label is asked once.
    private var askedSummaries: Set<String> = []
    /// How fast each strand last generated, timed from this client's own observation.
    public private(set) var generation = GenerationRate()

    /// Moves when what `rows` would return may have changed, so a host can keep
    /// its projection until then and a streamed token never rebuilds it.
    public private(set) var revision = 0

    private var entries: [String: JSONValue] = [:]
    private var lastMetadata: JSONValue?

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    public var entryCount: Int { entries.count }

    /// Total spend reported for the session, when the provider priced it.
    public var totalCost: Double? { usage["cost"]?["total"]?.double }

    public var totalTokens: Int? { usage["totalTokens"]?.int }

    // MARK: Transitions

    /// Adopts one completed transfer. Returns whether anything changed, because
    /// the idle refresh delivers an identical cut every second and must cost a
    /// comparison rather than a redraw.
    @discardableResult
    public mutating func apply(cut: Cut) -> Bool {
        role = cut.identity.role
        connectionID = cut.identity.connectionID
        let wasAdopted = hasAdoptedCut
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

        // The ledger of decided approvals is a metadata-only read of other cells.
        if cut.window == "decided" {
            return adopt(decisions: cut.metadata)
        }

        // A history page fills in older entries beside the live window, so its
        // metadata must not stand in for the newer cut already adopted.
        guard cut.window != "history", cut.window != "lineage" else {
            if landed { revision += 1 }
            return landed
        }
        let metadataChanged = cut.metadata != lastMetadata
        if metadataChanged {
            lastMetadata = cut.metadata
            applyMetadata(cut.metadata)
        }
        if landed || metadataChanged { revision += 1 }

        // A request already running at attach is one this client saw only the end of.
        if !wasAdopted { generation.attached(busy: strands.filter(\.isBusy).map(\.id)) }

        // An ended stream stays drawn until its durable entry lands, or the
        // reply would vanish for the moment between `end` and this cut.
        if landed {
            streams = streams.filter { !$0.value.ended }
        }
        return landed || metadataChanged || !wasAdopted
    }

    /// Reads the decided escalations out of a `decided` transfer.
    private mutating func adopt(decisions metadata: JSONValue) -> Bool {
        var changed = false
        for cell in metadata["cells"]?.array ?? [] {
            guard let record = Self.escalation(cell), record.status != "pending" else { continue }
            let decision = Decision(
                id: record.id,
                seq: cell["seq"]?.int ?? record.seq,
                strand: record.strand,
                tool: record.tool,
                summary: record.authorityLines.first ?? record.action,
                outcome: record.status
            )
            if decisions[record.id] != decision {
                decisions[record.id] = decision
                changed = true
            }
        }
        if changed { revision += 1 }
        return changed
    }

    /// Folds one uncorrelated frame. An unknown event is ignored by rule.
    public mutating func apply(push frame: EventEnvelope, now: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        switch frame.event {
        case "usage_observation", "usage":
            if let strand = frame.body["strand"]?.string {
                let usage = frame.body["last_usage"] ?? frame.body["usage"]
                generation.settle(strand: strand, output: usage?["output"]?.int ?? 0, now: now)
            }
        case "stream_delta":
            if let strand = frame.body["strand"]?.string, let id = frame.body["generation"]?.string, frame.body["kind"]?.string != "end" {
                generation.fragment(strand: strand, generation: id, now: now)
            }
            applyDelta(frame.body)
        case "presence":
            peers = (frame.body["peers"]?.array ?? []).compactMap(Self.peer)
        case "tool_output":
            if let call = frame.body["call_id"]?.string, let tail = frame.body["tail"]?.string {
                toolTails[call] = tail
            }
        case "block_summary":
            if frame.body["subject"]?.string == "block", let entry = frame.body["entry"]?.string,
               let block = frame.body["block"]?.int, let text = frame.body["text"]?.string {
                summaries["\(entry)/\(block)"] = text
                revision += 1
            }
        case "held_input_returned":
            // The daemon is draining and gives each held prompt back unsent
            // (protocol-change/038), so the text is retained before the socket closes.
            returnedDrafts.append(ReturnedDraft(
                strand: frame.body["strand"]?.string ?? "main",
                text: frame.body["text"]?.string ?? "",
                attachmentCount: frame.body["attachment_count"]?.int ?? 0
            ))
        case "goal_changed", "proposals_changed", "evolution_changed":
            signals[frame.event, default: 0] += 1
        case "snapshot":
            if let mode = frame.body["mode"]?.string { surfaces[mode] = frame.body }
            switch frame.body["mode"]?.string {
            case "block_summaries":
                for row in frame.body["board"]?["summaries"]?.array ?? [] {
                    if let entry = row["entry"]?.string, let block = row["block"]?.int, let text = row["text"]?.string {
                        summaries["\(entry)/\(block)"] = text
                    }
                }
            case "context":
                switch ContextBoard.reading(frame.body["board"]) {
                case .ready(let board):
                    context = board
                    contextNotice = nil
                case .failed(_, let message):
                    context = nil
                    contextNotice = message
                case .pending, nil:
                    break
                }
            case "worktree_diff":
                worktree = frame.body["board"]
            case "remote_children":
                remoteChildren = (frame.body["remote_children"]?.array ?? []).compactMap(RemoteChild.init)
            case "child_history":
                applyPeek(frame.body["board"])
            default:
                break
            }
        case "error":
            notices.append(frame.body["message"]?.string ?? "The daemon reported an error.")
        default:
            break
        }
    }

    /// The reasoning blocks long enough to be labelled that have neither a label nor a read
    /// in flight, at most the protocol's 32. Asking marks them, so a block the daemon has
    /// no label for is not asked about again on this attachment.
    public mutating func takeWantedSummaries(in rows: [TranscriptRow]) -> [(entry: String, block: Int)] {
        var wanted: [(entry: String, block: Int)] = []
        for row in rows {
            guard case .thinking(let text) = row.kind, text.utf8.count >= 512, summaries[row.id] == nil,
                  !askedSummaries.contains(row.id), wanted.count < 32,
                  let slash = row.id.lastIndex(of: "/"), let block = Int(row.id[row.id.index(after: slash)...]) else { continue }
            askedSummaries.insert(row.id)
            wanted.append((String(row.id[..<slash]), block))
        }
        return wanted
    }

    /// Hands over the returned prompts and forgets them.
    public mutating func takeReturnedDrafts() -> [ReturnedDraft] {
        defer { returnedDrafts = [] }
        return returnedDrafts
    }

    /// Clears the connection-level errors already shown.
    public mutating func clearNotices() {
        notices = []
    }

    /// Marks a peek as asked for, so the view can draw that it is on its way.
    public mutating func beginPeek(child: String) {
        peek = ChildPeek(child: child, isPending: true, failure: nil, rows: [], next: nil)
    }

    public mutating func endPeek() {
        peek = nil
    }

    private mutating func applyPeek(_ board: JSONValue?) {
        guard let current = peek, let board else { return }
        switch board["status"]?.string {
        case "ready":
            peek = ChildPeek(
                child: current.child,
                isPending: false,
                failure: nil,
                rows: Self.rows(ordered: board["entries"]?.array ?? []),
                next: board["next"]?.int
            )
        case "failed":
            peek = ChildPeek(
                child: current.child,
                isPending: false,
                failure: board["message"]?.string ?? "The other orchestrator refused the read.",
                rows: [],
                next: nil
            )
        default:
            break
        }
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
                    thinkingLevel: cell["value"]?["thinkingLevel"]?.string,
                    leaf: value("strand.leaf", id)?.string,
                    currentOperation: value("strand.state", id)?["currentOperationId"]?.string,
                    lastOutcome: value("strand.last_result", id)?["outcome"]?.string,
                    lastError: value("strand.last_result", id)?["error"]?["message"]?.string
                )
            }
            .sorted { lhs, rhs in lhs.id == "main" ? true : (rhs.id == "main" ? false : lhs.id < rhs.id) }

        escalations = cells
            .filter {
                $0["namespace"]?.string == "fact.custom"
                    && ($0["key"]?.string?.hasPrefix("escalation/") ?? false
                        || $0["key"]?.string?.hasPrefix(Self.remoteEscalationPrefix) ?? false)
            }
            .compactMap(Self.escalation)
            .filter { $0.status == "pending" }

        glances = Dictionary(cells.compactMap { cell -> (String, Glance)? in
            guard cell["namespace"]?.string == "fact.custom",
                  let key = cell["key"]?.string, key.hasPrefix(Glance.keyPrefix),
                  let glance = Glance(cell["value"]) else { return nil }
            return (String(key.dropFirst(Glance.keyPrefix.count)), glance)
        }, uniquingKeysWith: { first, _ in first })

        peers = (metadata["peers"]?.array ?? []).compactMap(Self.peer)
        remoteUsage = RemoteUsage.list(metadata)
        usage = metadata["usage"] ?? .null
        branch = value("fact.custom", "client/peers/git-observation")?["repository"]?["branch"]?.string
        pendingInputs = (metadata["pending_inputs"]?.array ?? []).compactMap { row in
            guard let id = row["id"]?.string else { return nil }
            return PendingInput(
                id: id,
                strand: row["strand"]?.string ?? "",
                kind: row["kind"]?.string ?? "",
                text: row["text"]?.string ?? "",
                editable: row["editable"]?.bool ?? false,
                revision: row["revision"]?.int
            )
        }
    }

    private static func peer(_ row: JSONValue) -> Peer? {
        guard let id = row["connection_id"]?.string else { return nil }
        return Peer(id: id, name: row["origin"]?["name"]?.string ?? "Unknown", role: row["role"]?.string ?? "")
    }

    private static let remoteEscalationPrefix = "remote-escalation/"

    /// Reads a question a child raised on another orchestrator.
    ///
    /// This is the protocol's own record, so its grants are already in the wire
    /// vocabulary. Its `seq` is the other orchestrator's, which is the one an
    /// answer must name, and an answer may carry only what `admitted` lists.
    private static func remoteEscalation(_ cell: JSONValue, value: JSONValue) -> Escalation? {
        guard
            let id = value["escalation_id"]?.string,
            cell["key"]?.string == remoteEscalationPrefix + id,
            let seq = value["seq"]?.int,
            let placement = value["placement"]?.string
        else { return nil }
        let wanted = value["denial"]?["wanted"]?.array ?? []
        let admitted = value["admitted"]?.array ?? []
        return Escalation(
            id: id,
            seq: seq,
            status: value["status"]?.string ?? "",
            strand: value["strand"]?.string ?? "",
            tool: value["tool"]?.string ?? "",
            action: value["action"]?.string ?? "",
            preview: value["preview"]?.string ?? "",
            reason: value["denial"]?["reason"]?.string ?? "",
            source: value["denial"]?["source"]?.string ?? "",
            grants: wanted.filter(admitted.contains),
            placement: placement,
            outsideCeiling: wanted.filter { !admitted.contains($0) }.map(Escalation.describe)
        )
    }

    /// Reads one escalation cell. The sequence an approval echoes is the
    /// cell's own register sequence.
    static func escalation(_ cell: JSONValue) -> Escalation? {
        if cell["key"]?.string?.hasPrefix(remoteEscalationPrefix) == true, let value = cell["value"] {
            return remoteEscalation(cell, value: value)
        }
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
    public func rows(strand: String, clearedThrough: Int? = nil) -> [TranscriptRow] {
        guard let leaf = strands.first(where: { $0.id == strand })?.leaf else { return [] }

        var chain: [JSONValue] = []
        var cursor: String? = leaf
        while let id = cursor, let entry = entries[id] {
            chain.append(entry)
            cursor = entry["parentId"]?.string
        }
        var rows = Self.rows(ordered: Array(chain.reversed()))

        // `/clear` hides what this client had already drawn. The records stay in
        // the session, so another client and a reopened window still show them.
        if let clearedThrough {
            rows.removeAll { ($0.seq ?? Int.max) <= clearedThrough }
        }

        // A decision stands among the rows by the sequence of its record, so it
        // reads where the person answered and not at the end.
        for decision in decisions.values.filter({ ($0.strand == strand || $0.strand.isEmpty) && $0.seq > (clearedThrough ?? -1) }).sorted(by: { $0.seq < $1.seq }) {
            let row = TranscriptRow(
                id: "decision/\(decision.id)",
                kind: .decision(tool: decision.tool, summary: decision.summary, outcome: decision.outcome),
                at: nil
            )
            if let index = rows.firstIndex(where: { ($0.seq ?? 0) > decision.seq }) {
                rows.insert(row, at: index)
            } else if rows.first?.seq.map({ $0 <= decision.seq }) ?? false {
                rows.append(row)
            }
        }
        return rows
    }

    /// Draws entries already in order, as a remote child's page delivers them.
    static func rows(ordered entries: [JSONValue]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var toolIndex: [String: Int] = [:]
        var previous: Int?
        var lastCache: (use: CacheUse, at: Int)?
        for entry in entries {
            let before = rows.count
            append(entry, previous: previous, to: &rows, toolIndex: &toolIndex)
            previous = entry["timestamp"]?.int ?? previous

            // A miss is noticed after the request that paid for it, and its row
            // stands just before that request's reply.
            if rows.count > before, let use = CacheUse(entry["message"]?["usage"]),
               entry["message"]?["role"]?.string == "assistant", use.readsContext, let at = entry["timestamp"]?.int {
                rows[before].cache = use
                if let held = lastCache,
                   let miss = CacheWatch.detect(previous: held.use, previousAt: held.at, current: use, currentAt: at) {
                    var notice = TranscriptRow(id: "\(rows[before].id)/cache-miss", kind: .notice(text: miss.words), at: at)
                    notice.seq = rows[before].seq
                    rows.insert(notice, at: before)
                }
                lastCache = (use, at)
            }
        }
        return rows
    }

    /// The highest record sequence this strand's chain holds, which `/clear` hides through.
    public func newestSeq(strand: String) -> Int? {
        rows(strand: strand).compactMap(\.seq).max()
    }

    /// The strand's todo board: the newest successful `todo` result on its chain.
    /// Walking the chain stops at the first board, so a long transcript costs
    /// only the distance to the last call. A strand whose chain holds none has
    /// no board here, and the caller may seed one from the strand's notes.
    public func todoBoard(strand: String) -> TodoBoard? {
        var cursor = strands.first { $0.id == strand }?.leaf
        while let id = cursor, let entry = entries[id] {
            if let board = TodoBoard.from(toolResult: entry["message"]) { return board }
            cursor = entry["parentId"]?.string
        }
        return nil
    }

    /// The `code_mode` programs on the strand's chain, for the Trace tab.
    public func traceBoard(strand: String) -> TraceBoard {
        var chain: [JSONValue] = []
        var cursor = strands.first { $0.id == strand }?.leaf
        while let id = cursor, let entry = entries[id] {
            chain.append(entry)
            cursor = entry["parentId"]?.string
        }
        return TraceBoard.fold(chain: chain.reversed())
    }

    /// One line for each strand, in the order the strands are held.
    public func strandLines() -> [StrandLine] {
        strands.map { strand in
            StrandLine.make(
                strand: strand,
                glance: glances[strand.id],
                rows: rows(strand: strand.id),
                approvals: escalations.filter { $0.strand == strand.id }.count,
                hasHeldInput: pendingInputs.contains { $0.strand == strand.id }
            )
        }
    }

    /// Whether this strand's chain continues below what is held. Asking the
    /// chain itself means the answer cannot go stale as pages arrive.
    public func hasOlder(strand: String) -> Bool {
        olderAnchor(strand: strand) != nil || oldestIsOpaque(strand: strand)
    }

    /// The identity of the entry the chain needs next: the parent of the oldest
    /// held record, which is what `history_lineage` is asked to start from.
    /// Nil when the chain is complete, or when a record too large to decode
    /// hides its parent.
    public func olderAnchor(strand: String) -> String? {
        var cursor = strands.first { $0.id == strand }?.leaf
        while let id = cursor {
            guard let entry = entries[id] else { return id }
            if entry["unknownParent"]?.bool == true { return nil }
            cursor = entry["parentId"]?.string
        }
        return nil
    }

    private func oldestIsOpaque(strand: String) -> Bool {
        var cursor = strands.first { $0.id == strand }?.leaf
        while let id = cursor, let entry = entries[id] {
            if entry["unknownParent"]?.bool == true { return true }
            cursor = entry["parentId"]?.string
        }
        return false
    }

    /// How many of the person's messages the strand's held chain contains. A
    /// page of older records counts as a turn once this goes up.
    public func inputCount(strand: String) -> Int {
        rows(strand: strand).filter {
            if case .user = $0.kind { return true }
            return false
        }.count
    }

    private static func append(
        _ entry: JSONValue,
        previous: Int?,
        to rows: inout [TranscriptRow],
        toolIndex: inout [String: Int]
    ) {
        let id = entry["id"]?.string ?? UUID().uuidString
        let at = entry["timestamp"]?.int
        let seq = entry["seq"]?.int
        let before = rows.count
        switch entry["type"]?.string {
        case "message":
            appendMessage(entry["message"], id: id, at: at, previous: previous, to: &rows, toolIndex: &toolIndex)
        case "compaction":
            rows.append(.init(id: id, kind: .notice(text: "Earlier conversation compacted."), at: at))
        case "branch_summary":
            rows.append(.init(id: id, kind: .notice(text: "Returned from another branch."), at: at))
        case "custom":
            break
        case "oversized":
            rows.append(.init(id: id, kind: .notice(text: "A record of \(entry["size"]?.int ?? 0) bytes was left out."), at: at))
        case let other:
            // The type set is closed, so an unknown type is corruption and is
            // shown as such rather than skipped (protocol section 5.7).
            rows.append(.init(id: id, kind: .failure(text: "Unrecognized entry type \(other ?? "none")."), at: at))
        }
        for index in before..<rows.count {
            if rows[index].at == nil { rows[index].at = at }
            rows[index].seq = seq
        }
    }

    private static func appendMessage(
        _ message: JSONValue?,
        id: String,
        at: Int?,
        previous: Int?,
        to rows: inout [TranscriptRow],
        toolIndex: inout [String: Int]
    ) {
        let blocks = message?["content"]?.array ?? []
        let took = at.flatMap { now in previous.map { max(0, now - $0) } }
        switch message?["role"]?.string {
        case "user":
            let origin = message?["origin"]
            let author = origin?["name"]?.string ?? origin?["strand"]?.string
            let body = text(of: blocks)
            let images = blocks.filter { $0["type"]?.string == "image" }.count

            // The harness writes its own notes into the conversation as user
            // turns with no author. Drawing one as a person's message would put
            // words in their mouth.
            let kind = origin?["kind"]?.string
            if let lines = MemoryContext.lines(in: body) {
                rows.append(.init(id: id, kind: .memory(lines: lines, text: body)))
            } else if kind == "peer", let session = origin?["session"]?.string, let strand = origin?["strand"]?.string {
                rows.append(.init(id: id, kind: .peer(session: session, strand: strand, text: body)))
            } else if kind == "strand" || (kind == nil && origin?["name"] == nil && origin?["strand"]?.string != nil),
                      let sender = origin?["strand"]?.string {
                let framed = StrandFraming.strip(body, sender: sender)
                rows.append(.init(id: id, kind: .sibling(strand: sender, text: framed.body, trailer: framed.trailer)))
            } else if origin == nil || origin == .null, let advisor = AdvisorFrame.read(body) {
                rows.append(.init(id: id, kind: .advisor(frame: advisor.frame, body: advisor.body)))
            } else if author == nil, body.hasPrefix("[loom] ") {
                rows.append(.init(id: id, kind: .notice(text: String(body.dropFirst(7)))))
            } else {
                var row = TranscriptRow(id: id, kind: .user(text: body, author: author))
                row.images = images
                row.pictures = ImageBlock.read(blocks: blocks, rowID: id)
                rows.append(row)
            }

        case "assistant":
            for (index, block) in blocks.enumerated() {
                let rowID = "\(id)/\(index)"
                switch block["type"]?.string {
                case "text":
                    rows.append(.init(id: rowID, kind: .assistant(text: block["text"]?.string ?? "")))
                case "thinking":
                    if block["redacted"]?.bool != true, let thinking = block["thinking"]?.string, !thinking.isEmpty {
                        var row = TranscriptRow(id: rowID, kind: .thinking(text: thinking))
                        row.tookMs = took
                        rows.append(row)
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
                    ), callID: call["id"]?.string))
                default:
                    break
                }
            }
            if message?["stopReason"]?.string == "aborted" {
                rows.append(.init(id: "\(id)/stopped", kind: .notice(text: "Stopped before the turn finished.")))
            }
            if let error = message?["errorMessage"]?.string {
                rows.append(.init(id: "\(id)/error", kind: .failure(text: error)))
            }

        case "toolResult":
            // A result folds into the row of the call it answers.
            let result = text(of: blocks)
            let failed = message?["isError"]?.bool ?? false
            let details = message?["details"]
            if let callID = message?["toolCallId"]?.string, let index = toolIndex[callID],
               case .tool(let name, let arguments, _, _) = rows[index].kind {
                var row = TranscriptRow(
                    id: rows[index].id,
                    kind: .tool(name: name, arguments: arguments, result: result, isError: failed),
                    callID: rows[index].callID,
                    at: rows[index].at
                )
                row.settledAt = at
                row.details = details
                row.pictures = ImageBlock.read(blocks: blocks, rowID: row.id)
                row.seq = rows[index].seq
                rows[index] = row

                if name == "agent_spawn", !failed, let child = details?["strand"]?.string {
                    var spawned = TranscriptRow(
                        id: row.id,
                        kind: .spawned(child: child, purpose: arguments["purpose"]?.string ?? ""),
                        callID: row.callID,
                        at: row.at
                    )
                    spawned.settledAt = at
                    spawned.seq = row.seq
                    rows[index] = spawned
                }
                if name == "agent_wait", !failed {
                    for (number, ready) in (details?["results"]?.array ?? []).enumerated()
                    where ready["state"]?.string == "ready" {
                        rows.append(.init(
                            id: "\(id)/report/\(number)",
                            kind: .agentReport(
                                child: ready["strand"]?.string ?? "",
                                outcome: ready["outcome"]?.string ?? "settled",
                                report: ready["report"]?.string ?? ""
                            ),
                            at: at
                        ))
                    }
                }
            } else {
                var row = TranscriptRow(id: id, kind: .tool(
                    name: message?["toolName"]?.string ?? "tool",
                    arguments: .null,
                    result: result,
                    isError: failed
                ))
                row.settledAt = at
                row.details = details
                rows.append(row)
            }

        default:
            break
        }
    }

    private static func text(of blocks: [JSONValue]) -> String {
        blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
    }
}
