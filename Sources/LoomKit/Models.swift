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
    public let pool: String?
    /// The orchestrator a move in flight is taking this session to.
    public let movingTo: String?
    /// The executor's node, which only a `sessions.elsewhere` row states.
    public let executorNode: String?
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
        pool = body["pool"]?.string
        movingTo = body["moving"]?["to"]?.string
        executorNode = body["executor_node"]?.string
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

/// Where a new session should run its tools.
public enum PlacementChoice: Sendable, Equatable, Hashable {
    case local
    case executor(String)
    case pool(String)
}

/// One machine, as `deployment.status` reports it from the answering daemon.
public struct DeploymentNode: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let roles: [String]
    public let state: String
    public let isSelf: Bool
    public let reasons: [String]
    public let buildVersion: String?
    public let uptimeMs: Int?
    public let platform: String?
    public let enforcement: String?
    public let openScopes: Int?
    public let scopeLimit: Int?
    public let capacity: Int?
    public let resident: Int?
    public let workspaces: [String]
    /// Sessions this executor still holds a scope for after their owner ended.
    public let unclean: [UncleanScope]
    /// What the executor's own report contradicts in its declaration, if anything.
    public let contradiction: String?
    public let ledgerBytes: Int?
    public let ledgerLimit: Int?

    init?(_ body: JSONValue) {
        guard let node = body["node"]?.string else { return nil }
        id = node
        name = body["name"]?.string ?? node
        roles = (body["roles"]?.array ?? []).compactMap(\.string)
        state = body["state"]?.string ?? "unknown"
        isSelf = body["self"]?.bool ?? false

        // A down node carries one `reason`, and a degraded node carries many.
        reasons = (body["reasons"]?.array ?? []).compactMap(\.string) + [body["reason"]?.string].compactMap { $0 }
        buildVersion = body["build_version"]?.string
        uptimeMs = body["uptime_ms"]?.int
        platform = body["executor"]?["platform"]?.string
        enforcement = body["executor"]?["enforcement"]?.string
        openScopes = body["executor"]?["scopes"]?["open"]?.int
        scopeLimit = body["executor"]?["scope_limit"]?.int
        capacity = body["orchestrator"]?["capacity"]?.int
        resident = body["orchestrator"]?["resident"]?.int

        // An executor lists its registered workspaces and unclean scopes inside its
        // own report, and only when the read named that node.
        workspaces = (body["executor"]?["workspaces"]?.array ?? body["workspaces"]?.array ?? []).compactMap(\.string)
        unclean = (body["executor"]?["unclean"]?.array ?? []).compactMap(UncleanScope.init)
        contradiction = body["executor"]?["contradiction"]?.string
        ledgerBytes = body["executor"]?["ledger_bytes"]?.int
        ledgerLimit = body["executor"]?["ledger_limit"]?.int
    }
}

/// A scope on an executor that has not closed cleanly, which blocks reopening the
/// session it belonged to until an operator releases it.
public struct UncleanScope: Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let state: String
    public var id: String { sessionID }

    init?(_ body: JSONValue) {
        guard let session = body["session"]?.string else { return nil }
        sessionID = session
        state = body["state"]?.string ?? "unknown"
    }
}

/// Another orchestrator this daemon lists, as the deployment states it.
public struct OtherOrchestrator: Sendable, Equatable, Identifiable {
    public let name: String
    public let node: String
    public let state: String
    /// `receiving` when it accepts sessions moved to it, nil when it gave no report.
    public let imports: String?
    /// The executors it serves, by this daemon's names for them.
    public let serves: [String]
    public var id: String { name }

    init?(_ body: JSONValue) {
        guard let name = body["name"]?.string else { return nil }
        self.name = name
        node = body["node"]?.string ?? name
        state = body["state"]?.string ?? "unknown"
        imports = body["imports"]?.string
        serves = (body["serves"]?.array ?? []).compactMap(\.string)
    }
}

/// A session move in flight, from the asking daemon's own report.
public struct MoveInFlight: Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let destination: String
    public let phase: String
    public let reason: String?
    public var id: String { sessionID }

    init?(_ body: JSONValue) {
        guard let session = body["session_id"]?.string else { return nil }
        sessionID = session
        destination = body["to"]?.string ?? ""
        phase = body["phase"]?.string ?? "running"
        reason = body["reason"]?.string
    }
}

/// A place a session may be put, with whether it can take one now.
public struct PlacementOption: Sendable, Equatable, Identifiable {
    public let choice: PlacementChoice
    public let name: String
    public let node: String?
    public let state: String
    public let platform: String?
    public let enforcement: String?
    public let freeScopes: Int?
    /// For a pool, the executors it lists. An executor has none.
    public let members: [String]
    public var id: String { "\(choice)" }
}

/// The deployment as one daemon sees it right now. Nothing here is cached by
/// the daemon, and any field a node did not report is unknown rather than zero.
public struct Deployment: Sendable, Equatable {
    public let selfNode: String
    public let state: String
    public let host: String?
    public let hasDistribution: Bool
    public let nodes: [DeploymentNode]
    public let executors: [PlacementOption]
    public let pools: [PlacementOption]
    public let omitted: [String]
    public let others: [OtherOrchestrator]
    public let moves: [MoveInFlight]
    /// How the asking daemon relates to each node: serves, peers, and the link.
    public let edges: [DeploymentEdge]

    /// Whether this daemon has more than itself, which decides if a person sees
    /// any placement vocabulary at all.
    public var isDistributed: Bool { nodes.count > 1 || !executors.isEmpty || !pools.isEmpty }

    /// The word for this daemon's own machine.
    public var selfName: String { hasDistribution ? selfNode : (host ?? "This machine") }

    init(_ body: JSONValue) {
        selfNode = body["self"]?.string ?? ""
        state = body["state"]?.string ?? "unknown"
        host = body["host"]?.string
        hasDistribution = body["distribution"]?.string == "configured"
        nodes = (body["nodes"]?.array ?? []).compactMap(DeploymentNode.init)
        omitted = (body["omitted"]?.array ?? []).compactMap(\.string)
        others = (body["orchestrators"]?.array ?? []).compactMap(OtherOrchestrator.init)
        moves = (body["moves"]?.array ?? []).compactMap(MoveInFlight.init)
        edges = (body["edges"]?.array ?? []).compactMap(DeploymentEdge.init)

        let placements = body["placements"]
        executors = (placements?["executors"]?.array ?? []).compactMap { row in
            guard let name = row["name"]?.string else { return nil }
            return PlacementOption(
                choice: .executor(name),
                name: name,
                node: row["node"]?.string,
                state: row["state"]?.string ?? "unknown",
                platform: row["declared"]?["platform"]?.string,
                enforcement: row["declared"]?["enforcement"]?.string,
                freeScopes: row["free_scopes"]?.int,
                members: []
            )
        }
        pools = (placements?["pools"]?.array ?? []).compactMap { row in
            guard let name = row["name"]?.string else { return nil }
            // A pool reports which of its executors qualify, not a state of its own.
            let eligible = (row["eligible"]?.array ?? []).compactMap(\.string)
            return PlacementOption(
                choice: .pool(name),
                name: name,
                node: nil,
                state: row["state"]?.string ?? (eligible.isEmpty ? "none eligible" : "ready"),
                platform: row["declared"]?["platform"]?.string ?? row["platform"]?.string,
                enforcement: nil,
                freeScopes: row["free_scopes"]?.int,
                members: (row["executors"]?.array ?? []).compactMap(\.string)
            )
        }
    }
}

/// One other orchestrator's sessions, from `sessions.elsewhere`.
public struct ElsewhereGroup: Sendable, Equatable, Identifiable {
    public let name: String
    public let node: String
    public let answered: Bool
    public let address: String?
    public let hasMore: Bool
    public let sessions: [SessionRecord]
    public var id: String { name }

    init(_ body: JSONValue) {
        name = body["name"]?.string ?? ""
        node = body["node"]?.string ?? ""
        answered = body["state"]?.string == "answered"
        address = body["address"]?.string
        hasMore = body["more"]?.bool ?? false
        sessions = (body["sessions"]?.array ?? []).compactMap(SessionRecord.init)
    }
}

/// One relation the asking daemon holds to a node, with the state of the link.
public struct DeploymentEdge: Sendable, Equatable {
    public let from: String
    public let to: String
    public let kind: String
    /// `connected` when the asking daemon reaches the node over its own link.
    public let link: String
    public let sessions: Int

    init?(_ body: JSONValue) {
        guard let from = body["from"]?.string, let to = body["to"]?.string else { return nil }
        self.from = from
        self.to = to
        kind = body["kind"]?.string ?? ""
        link = body["link"]?.string ?? "unknown"
        sessions = body["sessions"]?.int ?? 0
    }
}
