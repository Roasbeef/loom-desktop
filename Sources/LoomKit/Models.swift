import Foundation

/// What the control socket's `hello` says about this daemon lifetime.
public struct DaemonHello: Sendable, Equatable {
    public let epoch: String
    public let principal: String
    public let buildVersion: String
    public let buildCommit: String
}

/// `status`: the daemon's capacity at a moment.
public struct DaemonStatus: Sendable, Equatable {
    public let ready: Bool
    public let capacity: Int
    public let resident: Int
    public let blocked: Int

    init(_ body: JSONValue) {
        ready = body["ready"]?.bool ?? false
        capacity = body["capacity"]?.int ?? 0
        resident = body["resident"]?.int ?? 0
        blocked = body["blocked"]?.int ?? 0
    }
}

/// A session's lifecycle state, discriminated by the status object's `state`.
public enum SessionState: Sendable, Equatable {
    case reserved(failure: String?)
    case saved
    case opening(operation: String)
    case resident(incarnation: String)
    case stopping(operation: String)
    case recoveryBlocked
    case unknown(String)

    init(_ status: JSONValue?) {
        switch status?["state"]?.string {
        case "reserved": self = .reserved(failure: status?["failure"]?["reason"]?.string)
        case "saved": self = .saved
        case "opening": self = .opening(operation: status?["operation"]?.string ?? "")
        case "resident": self = .resident(incarnation: status?["incarnation"]?.string ?? "")
        case "stopping": self = .stopping(operation: status?["operation"]?.string ?? "")
        case "recovery_blocked": self = .recoveryBlocked
        case let other: self = .unknown(other ?? "")
        }
    }

    public var isResident: Bool {
        if case .resident = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .reserved: return "Reserved"
        case .saved: return "Saved"
        case .opening: return "Opening"
        case .resident: return "Running"
        case .stopping: return "Stopping"
        case .recoveryBlocked: return "Blocked"
        case .unknown(let text): return text
        }
    }
}

/// One catalogue record from `sessions.list`.
public struct SessionRecord: Sendable, Identifiable, Equatable {
    public let id: String
    public let workspace: String
    public let name: String
    public let subtitle: String?
    public let createdAt: Date
    public let state: SessionState
    public let executor: String?
    /// A moved session is this daemon's tombstone and is not listed as openable.
    public let hasMoved: Bool

    init?(_ body: JSONValue) {
        guard let id = body["session_id"]?.string else { return nil }
        self.id = id
        workspace = body["workspace"]?.string ?? ""
        name = body["name"]?.string ?? ""
        subtitle = body["subtitle"]?.string
        createdAt = Date(timeIntervalSince1970: (body["created_at"]?.double ?? 0) / 1000)
        state = SessionState(body["status"])
        executor = body["executor"]?.string
        hasMoved = body["moved"] != nil
    }

    /// The name to draw, preferring what a person typed over a default.
    public var title: String {
        if let subtitle, name.isEmpty || name == workspaceName { return subtitle }
        return name.isEmpty ? workspaceName : name
    }

    public var workspaceName: String {
        (workspace as NSString).lastPathComponent
    }
}

/// What a resident session is doing, from one `sessions.activity` observation.
public struct SessionActivity: Sendable, Equatable {
    public enum State: String, Sendable {
        case needsYou = "needs_you"
        case working
        case idle
        case unknown
    }

    public struct Glance: Sendable, Equatable, Identifiable {
        public let strand: String
        public let title: String
        public let summary: String
        public var id: String { strand }
    }

    public let sessionID: String
    public let state: State
    public let strands: Int
    public let working: Int
    public let approvals: Int
    public let lastOutcome: String?
    public let lastMessage: String?
    public let model: String?
    public let glances: [Glance]

    init?(_ body: JSONValue) {
        guard let id = body["session_id"]?.string else { return nil }
        sessionID = id

        // An unrecognized state reads as unknown, and a missing optional field
        // reads as empty (protocol section 3.21).
        state = State(rawValue: body["state"]?.string ?? "") ?? .unknown
        strands = body["strands"]?.int ?? 0
        working = body["working"]?.int ?? 0
        approvals = body["approvals"]?.int ?? 0
        lastOutcome = body["last_outcome"]?.string
        lastMessage = body["last_message"]?.string
        model = body["model"]?.string
        glances = (body["glances"]?.array ?? []).compactMap { glance in
            guard let strand = glance["strand"]?.string else { return nil }
            return Glance(
                strand: strand,
                title: glance["title"]?.string ?? strand,
                summary: glance["summary"]?.string ?? ""
            )
        }
    }
}
