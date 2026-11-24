import Foundation

// The wire shapes of the two commands that complete the attention inbox (loom
// protocol-change/128 and docs/client-protocol.md section 3.34):
// `attention.answer`, which delivers a person's answer to an ask and settles it, and
// `sessions.saved_attention`, which reads the counts the catalogue keeps for
// sessions that are not running. The calls live in `ControlClient+Attention.swift`;
// this file is the request bodies, the reply decoders and the one question a
// caller asks of an error, whether the daemon knows the command at all.
//
// Both decoders are total, as every decoder in this module is: a field that is
// missing or of the wrong type reads as absent, and a reply that is unusable
// without it reads as no reply.

// MARK: An answer

/// One question's answer, in the value the kind takes (loom protocol-change/119,
/// "The answer").
public enum AnswerValue: Sendable, Equatable {
    /// A `confirm` question: yes or no.
    case confirm(Bool)
    /// A `choice` question: the chosen option's label.
    case choice(String)
    /// A `multiple` or `checklist` question: the chosen labels.
    case labels([String])
    /// A `fill` question: the text as typed. A `number` is carried as a string.
    case text(String)
    /// "Other", for any question: the person's own words. The daemon receives a null
    /// in `answers` and the text beside it in `other`.
    case other(String)
}

/// A person's answer to every question of an ask, as `attention.answer` carries it.
public struct AttentionAnswerBody: Sendable, Equatable {
    /// One entry for each question key, in the order of the questions.
    public let entries: [(key: String, value: AnswerValue)]

    public init(entries: [(key: String, value: AnswerValue)]) {
        self.entries = entries
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    /// The object of protocol-change/119 without its `ask` key, which the daemon
    /// adds: `{"answers": {...}, "other": {...}}`. `other` is left out when no
    /// question was answered by Other, as the document's example leaves it.
    public var json: JSONValue {
        var answers: [String: JSONValue] = [:]
        var others: [String: JSONValue] = [:]
        for (key, value) in entries {
            switch value {
            case .confirm(let yes): answers[key] = .bool(yes)
            case .choice(let label): answers[key] = .string(label)
            case .labels(let labels): answers[key] = .array(labels.map { .string($0) })
            case .text(let text): answers[key] = .string(text)
            case .other(let text):
                answers[key] = .null
                others[key] = .string(text)
            }
        }
        var body: [String: JSONValue] = ["answers": .object(answers)]
        if !others.isEmpty { body["other"] = .object(others) }
        return .object(body)
    }
}

/// How the daemon took the prompt that carries an answer.
public enum AnswerDelivery: String, Sendable, Equatable {
    /// The strand was idle and the prompt started its next run.
    case admitted
    /// The strand was busy and holds the prompt behind its turn.
    case queued
}

/// The reply of `attention.answer`.
public struct AnswerReceipt: Sendable, Equatable {
    public let ask: String
    public let delivery: AnswerDelivery
    /// The ask's revision after it was settled.
    public let revision: Int

    init?(_ body: JSONValue) {
        guard let ask = body["ask"]?.string,
              let delivery = body["delivery"]?.string.flatMap(AnswerDelivery.init(rawValue:)),
              let revision = body["revision"]?.natural
        else { return nil }
        self.ask = ask
        self.delivery = delivery
        self.revision = revision
    }
}

// MARK: Saved sessions' counts

/// What the catalogue remembers of one session's attention (loom
/// protocol-change/122). It is a cache of the session's own records and can lag
/// them, so a view that draws it says it came from the catalogue.
public struct SavedAttention: Sendable, Equatable {
    public let sessionID: String
    public let pendingApprovals: Int
    public let openAsks: Int
    public let openFinds: Int
    /// The creation time of the oldest open ask or find, in Unix milliseconds. It says
    /// nothing about approvals, which carry a time only through `approval.read`.
    public let oldestOpenAt: Int?
    /// When the daemon wrote the row, in Unix milliseconds.
    public let updatedAt: Int

    public init(
        sessionID: String, pendingApprovals: Int, openAsks: Int, openFinds: Int,
        oldestOpenAt: Int? = nil, updatedAt: Int
    ) {
        self.sessionID = sessionID
        self.pendingApprovals = pendingApprovals
        self.openAsks = openAsks
        self.openFinds = openFinds
        self.oldestOpenAt = oldestOpenAt
        self.updatedAt = updatedAt
    }

    /// A negative or missing count or time is damage, which the daemon's own table
    /// forbids, and the row is dropped as a session that was never read.
    init?(_ value: JSONValue) {
        guard let id = value["session_id"]?.string,
              let approvals = value["pending_approvals"]?.natural,
              let asks = value["open_asks"]?.natural,
              let finds = value["open_finds"]?.natural,
              let updated = value["updated_at"]?.natural
        else { return nil }
        self.init(
            sessionID: id, pendingApprovals: approvals, openAsks: asks, openFinds: finds,
            oldestOpenAt: value["oldest_open_at"]?.natural, updatedAt: updated
        )
    }
}

/// What a read of the catalogue's counts found, as the inbox's counts take it.
public enum SavedReading: Sendable, Equatable {
    /// No read has answered, or the daemon does not know the command. Saved sessions
    /// are then "not checked", which is never "nothing waits".
    case unchecked
    /// The rows the daemon read, by session. A saved session with no entry was not
    /// read, which the daemon says for a session never summarised and one this
    /// credential does not hold alike.
    case read([String: SavedAttention])
}

// MARK: The commands' bodies

/// The request bodies, apart from the socket so a test states them.
public enum AttentionWire {
    /// `sessions.saved_attention` takes one to 24 distinct ids.
    public static let savedBatch = 24

    public static func answerBody(session: String, ask: String, revision: Int, answer: AttentionAnswerBody, epoch: String) -> JSONValue {
        [
            "session": .string(session),
            "ask": .string(ask),
            "revision": .int(Int64(revision)),
            "answer": answer.json,
            "epoch": .string(epoch),
        ]
    }

    public static func savedBody(sessions: [String], epoch: String) -> JSONValue {
        ["sessions": .array(sessions.map { .string($0) }), "epoch": .string(epoch)]
    }

    /// The rows of a `sessions.saved_attention` reply, by session. A row that does
    /// not decode costs only itself.
    public static func savedRows(_ body: JSONValue) -> [String: SavedAttention] {
        (body["saved"]?.array ?? []).compactMap(SavedAttention.init).reduce(into: [:]) { rows, row in
            rows[row.sessionID] = row
        }
    }
}

// MARK: Unknown command

extension LoomError {
    /// Whether the daemon answered `not_found`. For a `projects.*` command that
    /// says the daemon started no project table.
    public var isNotFound: Bool {
        guard case .server(let code, _, _) = self else { return false }
        return code == "not_found"
    }

    /// Whether the daemon does not know the command. A daemon built before a command
    /// answers `unsupported`, or `bad_request` with the message `unsupported control
    /// command` (client protocol sections 1.5, 3.29 and 3.31), and either leaves the
    /// caller where it was before the command existed.
    public var isUnknownCommand: Bool {
        guard case .server(let code, let message, _) = self else { return false }
        return code == "unsupported" || (code == "bad_request" && message.contains("unsupported control command"))
    }
}
