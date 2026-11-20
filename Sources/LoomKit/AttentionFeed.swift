import Foundation

// What the daemon says a person has to decide, as the attention inbox reads it
// (loom protocol-change/120 and its addendum on stuck strands). Four commands
// carry it: `sessions.attention` (one row per resident session), `attention.read`
// (one ask or find in full), `attention.close_find` (settling a find) and
// `approval.read` (the evidence behind a pending approval). The commands live in
// `ControlClient+Attention.swift`; this file is the typed values and the decoders.
//
// Every decoder here is total. A field that is missing, null or of the wrong type
// reads as absent, and a record that is unusable without it reads as no record,
// so a daemon that is older or newer than this client never crashes it. Text a
// model wrote travels as a plain `String` that the view draws with
// `Text(verbatim:)`; nothing here is parsed as markup.

extension JSONValue {
    /// A whole non-negative number: a time in Unix milliseconds or a count. A
    /// negative or fractional number is damage, which reads as absent.
    var natural: Int? {
        guard case .int(let value) = self, value >= 0 else { return nil }
        return Int(value)
    }

    /// The object's members, or nil for any other kind of value.
    var members: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}

// MARK: The feed row

/// The records a session read and the ones the row had room to carry.
///
/// `count` is what the session holds and `items` may be shorter, because the
/// daemon sheds the oldest items to keep a row within its bound. A count is words
/// for what was read and never for what exists.
public struct AttentionSection<Item: Sendable & Equatable>: Sendable, Equatable {
    public let count: Int
    public let items: [Item]

    public init(count: Int, items: [Item]) {
        self.count = count
        self.items = items
    }

    /// Reads `{count, items}`. A missing or negative count is damage and reads as
    /// no section, but one item that does not decode costs only itself. A count
    /// below the items it came with could only be damage, and the honest reading
    /// is the larger.
    init?(_ value: JSONValue?, item: (JSONValue) -> Item?) {
        guard let value, let count = value["count"]?.natural else { return nil }
        let items = (value["items"]?.array ?? []).compactMap(item)
        self.init(count: max(count, items.count), items: items)
    }
}

/// One open ask routed to the owner.
public struct AttentionAsk: Sendable, Equatable, Identifiable {
    /// `ask-` and ten hexadecimal digits.
    public let id: String
    public let strand: String
    /// When the ask was recorded, in Unix milliseconds.
    public let createdAt: Int
    /// The first question's prompt, cut by the daemon. Model text.
    public let head: String
    /// How many questions the ask holds.
    public let questions: Int

    public init(id: String, strand: String, createdAt: Int, head: String, questions: Int) {
        self.id = id
        self.strand = strand
        self.createdAt = createdAt
        self.head = head
        self.questions = questions
    }

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, let strand = value["strand"]?.string,
              let createdAt = value["created_at"]?.natural, let head = value["head"]?.string,
              let questions = value["questions"]?.natural
        else { return nil }
        self.init(id: id, strand: strand, createdAt: createdAt, head: head, questions: questions)
    }
}

/// What an agent calls a find. The table is closed, as the daemon's is.
public enum FindKind: String, Sendable, Equatable {
    case risk, idea, bug, question
}

/// One open find: something the agent noticed outside its task.
public struct AttentionFind: Sendable, Equatable, Identifiable {
    /// `find-` and ten hexadecimal digits.
    public let id: String
    public let strand: String
    public let kind: FindKind
    public let createdAt: Int
    /// The find's text, cut by the daemon. Model text.
    public let head: String
    public let path: String?
    /// The line in `path`. It is carried only with its path.
    public let line: Int?

    public init(id: String, strand: String, kind: FindKind, createdAt: Int, head: String, path: String?, line: Int?) {
        self.id = id
        self.strand = strand
        self.kind = kind
        self.createdAt = createdAt
        self.head = head
        self.path = path
        self.line = line
    }

    /// A find with a kind this client does not know is no find, so the inbox never
    /// words a kind it was not told about.
    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, let strand = value["strand"]?.string,
              let kind = value["kind"]?.string.flatMap(FindKind.init(rawValue:)),
              let createdAt = value["created_at"]?.natural, let head = value["head"]?.string
        else { return nil }
        let path = value["path"]?.string
        self.init(
            id: id, strand: strand, kind: kind, createdAt: createdAt, head: head,
            path: path,
            // A line without its path is a line of nothing.
            line: path == nil ? nil : value["line"]?.natural
        )
    }
}

/// One strand that stopped on a failed run and has not run since.
public struct AttentionStuck: Sendable, Equatable, Identifiable {
    public let strand: String
    /// The exact time of the failed response, or nil when the daemon had no such
    /// entry to read and for a daemon that predates the field.
    public let failedAt: Int?
    /// The run's error code, the harness's own word (`rate_limited`, `timeout`,
    /// `provider_error`), never model text.
    public let reason: String?
    /// The provider's minimum wait before a retry.
    public let retryAfterMs: Int?
    /// The strand that spawned this one. Session text, drawn as text only.
    public let parent: String?
    public var id: String { strand }

    public init(strand: String, failedAt: Int? = nil, reason: String? = nil, retryAfterMs: Int? = nil, parent: String? = nil) {
        self.strand = strand
        self.failedAt = failedAt
        self.reason = reason
        self.retryAfterMs = retryAfterMs
        self.parent = parent
    }

    init?(_ value: JSONValue) {
        guard let strand = value["strand"]?.string else { return nil }
        self.init(
            strand: strand,
            failedAt: value["failed_at"]?.natural,
            reason: value["reason"]?.string,
            retryAfterMs: value["retry_after_ms"]?.natural,
            parent: value["parent"]?.string
        )
    }
}

/// What one resident session needs from a person, from one `sessions.attention`
/// observation.
public struct AttentionRow: Sendable, Equatable {
    public let sessionID: String
    /// The creation time of the oldest open ask routed to the owner. It is the age
    /// of an ask and says nothing about an approval.
    public let waitingSince: Int?
    public let asks: AttentionSection<AttentionAsk>
    public let finds: AttentionSection<AttentionFind>
    public let stuck: AttentionSection<AttentionStuck>

    public init(
        sessionID: String, waitingSince: Int? = nil,
        asks: AttentionSection<AttentionAsk> = .init(count: 0, items: []),
        finds: AttentionSection<AttentionFind> = .init(count: 0, items: []),
        stuck: AttentionSection<AttentionStuck> = .init(count: 0, items: [])
    ) {
        self.sessionID = sessionID
        self.waitingSince = waitingSince
        self.asks = asks
        self.finds = finds
        self.stuck = stuck
    }

    /// A row that was read has `state: "ok"`. Any other state, `unknown` included,
    /// means the daemon did not read the session, which is no row and never an
    /// empty one: the inbox must not say nothing waits on a session nobody read.
    init?(_ value: JSONValue) {
        guard let id = value["session_id"]?.string, value["state"]?.string == "ok",
              let asks = AttentionSection(value["asks"], item: AttentionAsk.init),
              let finds = AttentionSection(value["finds"], item: AttentionFind.init),
              let stuck = AttentionSection(value["stuck"], item: AttentionStuck.init)
        else { return nil }
        self.init(sessionID: id, waitingSince: value["waiting_since"]?.natural, asks: asks, finds: finds, stuck: stuck)
    }
}

// MARK: One record in full

/// One option of a question.
public struct AttentionOption: Sendable, Equatable {
    public let label: String
    public let note: String?
    public let isRecommended: Bool
}

/// One question of an ask. Every part of it is model text.
public struct AttentionQuestion: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case confirm, choice, multiple, checklist, fill
        /// A kind a newer daemon added. The question still reads, as its prompt.
        case other(String)

        init(_ word: String) {
            switch word {
            case "confirm": self = .confirm
            case "choice": self = .choice
            case "multiple": self = .multiple
            case "checklist": self = .checklist
            case "fill": self = .fill
            default: self = .other(word)
            }
        }
    }

    public let key: String
    public let prompt: String
    public let kind: Kind
    public let options: [AttentionOption]
    /// For `multiple`: the fewest and most options a person may pick.
    public let min: Int?
    public let max: Int?
    /// For `fill`: `text`, `long_text`, `path`, `number` or `url`.
    public let format: String?
    public var id: String { key }

    init?(_ value: JSONValue) {
        guard let key = value["key"]?.string, let prompt = value["prompt"]?.string,
              let kind = value["kind"]?.string
        else { return nil }
        self.key = key
        self.prompt = prompt
        self.kind = Kind(kind)
        options = (value["options"]?.array ?? []).compactMap { option in
            guard let label = option["label"]?.string else { return nil }
            return AttentionOption(label: label, note: option["note"]?.string, isRecommended: option["recommended"]?.bool ?? false)
        }
        min = value["min"]?.natural
        max = value["max"]?.natural
        format = value["format"]?.string
    }
}

/// The answer of an answered ask, as the model reads it plus who gave it.
public struct AttentionAnswer: Sendable, Equatable {
    /// A key per question; null where "Other" was used. Kept as the daemon sent it.
    public let answers: JSONValue
    /// The text of each "Other", by question key.
    public let other: JSONValue
    public let by: String?
    public let at: Int?
}

/// How a closed find was settled.
public struct AttentionClosure: Sendable, Equatable {
    /// `fixed`, `filed` or `dismissed`.
    public let outcome: String
    public let at: Int?
    public let by: String?
}

/// Where in the transcript a record was raised.
public struct AttentionAnchor: Sendable, Equatable {
    public let operation: String
    public let stepID: String
    public let sourceIndex: Int
}

/// One ask or find in full, from `attention.read`, at the revision it was read.
///
/// The revision is the sequence number of the record's cell. A later write,
/// including the settling one, gives a higher number, and `attention.close_find`
/// echoes it so a record that moved since is refused rather than overwritten.
public struct AttentionRecord: Sendable, Equatable {
    public struct Ask: Sendable, Equatable {
        /// `owner`, or the name of the strand the ask is routed to.
        public let routing: String?
        public let why: String?
        public let questions: [AttentionQuestion]
        public let answer: AttentionAnswer?
        /// True only for an open ask routed to the owner that this principal may
        /// answer. An observer is told false.
        public let mayAnswer: Bool
    }

    public struct Find: Sendable, Equatable {
        public let kind: FindKind?
        public let text: String
        public let path: String?
        public let line: Int?
        public let closure: AttentionClosure?
        /// True only for an open find that this principal may close.
        public let mayClose: Bool
    }

    public enum Detail: Sendable, Equatable {
        case ask(Ask)
        case find(Find)
    }

    public let id: String
    public let revision: Int
    /// `open`, `answered` or `closed`.
    public let status: String
    public let strand: String
    public let createdAt: Int
    public let anchor: AttentionAnchor?
    public let detail: Detail

    /// A record is an ask or a find by its `kind`; any other kind, or a missing
    /// identity or revision, is no record.
    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, let revision = value["revision"]?.natural,
              let kind = value["kind"]?.string
        else { return nil }
        self.id = id
        self.revision = revision
        status = value["status"]?.string ?? ""
        strand = value["strand"]?.string ?? ""
        createdAt = value["created_at"]?.natural ?? 0
        anchor = value["anchor"].flatMap { anchor in
            guard let operation = anchor["operation"]?.string, let step = anchor["step_id"]?.string,
                  let index = anchor["source_index"]?.natural
            else { return nil }
            return AttentionAnchor(operation: operation, stepID: step, sourceIndex: index)
        }
        switch kind {
        case "ask":
            detail = .ask(Ask(
                routing: value["routing"]?.string,
                why: value["why"]?.string,
                questions: (value["questions"]?.array ?? []).compactMap(AttentionQuestion.init),
                answer: value["answer"].flatMap { answer in
                    guard answer.members != nil else { return nil }
                    return AttentionAnswer(
                        answers: answer["answers"] ?? .null, other: answer["other"] ?? .null,
                        by: answer["by"]?.string, at: answer["at"]?.natural
                    )
                },
                mayAnswer: value["may_answer"]?.bool ?? false
            ))
        case "find":
            detail = .find(Find(
                kind: value["find_kind"]?.string.flatMap(FindKind.init(rawValue:)),
                text: value["text"]?.string ?? "",
                path: value["path"]?.string,
                line: value["line"]?.natural,
                closure: value["closure"].flatMap { closure in
                    guard let outcome = closure["outcome"]?.string else { return nil }
                    return AttentionClosure(outcome: outcome, at: closure["at"]?.natural, by: closure["by"]?.string)
                },
                mayClose: value["may_close"]?.bool ?? false
            ))
        default:
            return nil
        }
    }
}

/// How `attention.close_find` settles a find. The daemon sends nothing to any
/// strand; it only records the outcome.
public enum FindOutcome: String, Sendable, Equatable {
    case dismissed, fixed, filed
}

// MARK: Approval evidence

/// What a pending approval wants beyond what the session already holds.
public struct ApprovalWanted: Sendable, Equatable {
    /// `network`, `writable_root`, `readable_root`, `env`, `limit`, `scratch` or `other`.
    public let kind: String
    /// A path, a mode, a name or a limit. Model-influenced text.
    public let detail: String
}

/// The network a call would have if it were approved.
public enum ApprovalNetwork: String, Sendable, Equatable {
    case on, off
}

/// The sandbox and network the session runs its tools under now, in the daemon's
/// words (`workspace-write` or `read-only`; `off`, `loopback`, `proxy` or `on`).
public struct ApprovalPolicy: Sendable, Equatable {
    public let sandbox: String
    public let network: String
}

/// One pending approval, as evidence for a person who will decide it elsewhere.
public struct ApprovalEvidenceItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: Int
    public let tool: String
    /// A bounded rendering of the call's arguments. Model text.
    public let preview: String?
    /// What held the call: `policy` or `execution`, or empty.
    public let source: String
    public let reason: String
    public let wanted: [ApprovalWanted]
    public let asked: Int
    /// When the question was put to a person. Absent for a record written before
    /// the field existed (loom protocol-change/126), and then no age is worded.
    public let raisedAt: Int?
    /// Absent when the daemon could not say exactly, and then nothing is drawn.
    public let network: ApprovalNetwork?
    public let policy: ApprovalPolicy?

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, let revision = value["revision"]?.natural else { return nil }
        self.id = id
        self.revision = revision
        tool = value["tool"]?.string ?? ""
        preview = value["preview"]?.string
        source = value["source"]?.string ?? ""
        reason = value["reason"]?.string ?? ""
        wanted = (value["wanted"]?.array ?? []).compactMap { grant in
            guard let kind = grant["kind"]?.string else { return nil }
            return ApprovalWanted(kind: kind, detail: grant["detail"]?.string ?? "")
        }
        asked = value["asked"]?.natural ?? 0
        raisedAt = value["raised_at"]?.natural
        network = value["network"]?.string.flatMap(ApprovalNetwork.init(rawValue:))
        policy = value["policy"].flatMap { policy in
            guard let sandbox = policy["sandbox"]?.string, let network = policy["network"]?.string else { return nil }
            return ApprovalPolicy(sandbox: sandbox, network: network)
        }
    }
}

/// A session's pending approvals, from `approval.read`.
public struct ApprovalEvidence: Sendable, Equatable {
    /// Every pending record the session holds; `items` carries at most four.
    public let count: Int
    public let items: [ApprovalEvidenceItem]

    init?(_ body: JSONValue) {
        guard let inner = body["approvals"], let count = inner["count"]?.natural else { return nil }
        let items = (inner["items"]?.array ?? []).compactMap(ApprovalEvidenceItem.init)
        self.count = max(count, items.count)
        self.items = items
    }

    /// When the oldest approval that carries a time was raised. The thread's age
    /// is counted from it, and nothing is aged when no item has one.
    public var oldestRaised: Int? {
        items.compactMap(\.raisedAt).min()
    }
}
