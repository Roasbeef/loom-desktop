import Foundation
import LoomKit

/// Where a session runs: the brain keeps the conversation, the model keys and
/// the approvals, and the hands run its tools beside the checkout.
public struct Placement: Sendable, Equatable {
    public let brain: String
    public let hands: String
    /// Whether the tools run on another machine than the conversation.
    public let isSplit: Bool

    public init(record: SessionRecord, brain: String) {
        self.brain = brain
        if let executor = record.executor {
            hands = executor
            isSplit = true
        } else if let pool = record.pool {
            // A pool session has no executor until its first open chooses one.
            hands = "\(pool) pool"
            isSplit = true
        } else {
            hands = brain
            isSplit = false
        }
    }

    public var label: String { isSplit ? "\(brain) → \(hands)" : brain }
}

/// One thing waiting on a person.
///
/// The inbox groups by what an item needs rather than by which session raised it.
public struct AttentionItem: Sendable, Identifiable, Equatable {
    public enum Kind: Int, Sendable, Comparable, CaseIterable {
        case approval, failed, machine

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        public var title: String {
            switch self {
            case .approval: return "Needs approval"
            case .failed: return "Failed runs"
            case .machine: return "Machines"
            }
        }
    }

    public enum Source: Sendable, Equatable {
        /// A session. `escalation` is nil until the record has been read from
        /// the session's own lane, since activity reports only a count.
        case session(id: String, escalation: Escalation?)
        /// A machine that is not healthy, and the sessions depending on it.
        case machine(node: String, sessions: [String])
    }

    public let id: String
    public let kind: Kind
    public let source: Source
    public let agent: String
    public let title: String
    public let detail: String
}

/// One agent on the mission control board.
public struct AgentCard: Sendable, Identifiable, Equatable {
    public enum Liveness: Int, Sendable, Comparable {
        case needsYou, working, idle, unknown, off

        public static func < (lhs: Liveness, rhs: Liveness) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let text: String

        public init(id: String, label: String, text: String) {
            self.id = id
            self.label = label
            self.text = text
        }
    }

    public let id: String
    public let sessionID: String
    public let name: String
    public let context: String
    public let liveness: Liveness
    public let digest: String
    public let model: String?
    public let lines: [Line]
    public let waitingCount: Int
    /// Where it runs, or nil when there is only one machine to speak of.
    public let placement: Placement?
    /// The machine this card's tools depend on, for grouping and blast radius.
    public let machine: String?
}

/// Combines each daemon's observations into the two shared views.
///
/// These are pure functions so the merge rules are tested without a daemon.
public enum Mission {
    public static func attention(
        sessions: [SessionRecord],
        activity: [String: SessionActivity],
        escalations: [String: [Escalation]],
        unhealthy: [(node: DeploymentNode, sessions: [SessionRecord])] = []
    ) -> [AttentionItem] {
        var items: [AttentionItem] = []
        for session in sessions {
            guard let row = activity[session.id], row.state == .needsYou else { continue }
            let known = escalations[session.id] ?? []
            if row.approvals > 0 {
                if known.isEmpty {
                    // The count arrived before the lane's record did.
                    items.append(.init(
                        id: "loom/\(session.id)/pending",
                        kind: .approval,
                        source: .session(id: session.id, escalation: nil),
                        agent: session.title,
                        title: "\(row.approvals) pending approval\(row.approvals == 1 ? "" : "s")",
                        detail: "Reading the request from the session."
                    ))
                }
                for escalation in known {
                    items.append(.init(
                        id: "loom/\(session.id)/\(escalation.id)",
                        kind: .approval,
                        source: .session(id: session.id, escalation: escalation),
                        agent: session.title,
                        title: escalation.reason.isEmpty ? "Allow \(escalation.tool)?" : escalation.reason,
                        detail: escalation.safePreview
                    ))
                }
            } else {
                items.append(.init(
                    id: "loom/\(session.id)/failed",
                    kind: .failed,
                    source: .session(id: session.id, escalation: nil),
                    agent: session.title,
                    title: "The last run failed",
                    detail: row.lastMessage ?? "The session reported no final message."
                ))
            }
        }

        // A sick machine is worth a person's attention before it fails a run,
        // but only when something depends on it.
        for (node, dependents) in unhealthy where !dependents.isEmpty {
            items.append(.init(
                id: "machine/\(node.id)",
                kind: .machine,
                source: .machine(node: node.id, sessions: dependents.map(\.id)),
                agent: node.name,
                title: "\(node.name) is \(node.state)",
                detail: ([node.reasons.joined(separator: ", ")] + dependents.map(\.title))
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            ))
        }
        return items.sorted { $0.kind < $1.kind }
    }

    public static func cards(
        sessions: [SessionRecord],
        activity: [String: SessionActivity],
        placement: (SessionRecord) -> Placement? = { _ in nil }
    ) -> [AgentCard] {
        sessions.map { session -> AgentCard in
            let row = activity[session.id]
            let lines = (row?.glances ?? []).map {
                AgentCard.Line(id: $0.strand, label: $0.title, text: $0.summary)
            }
            return AgentCard(
                id: "loom/\(session.id)",
                sessionID: session.id,
                name: session.title,
                context: session.workspaceName,
                liveness: liveness(session: session, activity: row),
                digest: row?.lastMessage ?? session.subtitle ?? "",
                model: row?.model,
                lines: lines,
                waitingCount: row?.approvals ?? 0,
                placement: placement(session),
                machine: placement(session)?.hands
            )
        }

        .sorted { ($0.liveness, $0.name) < ($1.liveness, $1.name) }
    }

    public static func liveness(session: SessionRecord, activity: SessionActivity?) -> AgentCard.Liveness {
        switch activity?.state {
        case .needsYou: return .needsYou
        case .working: return .working
        case .idle: return .idle
        case .unknown: return .unknown
        case nil: return session.state.isResident ? .idle : .off
        }
    }

    /// Names each machine that is not healthy and the sessions that depend on it,
    /// so a person can see what a sick node affects before it fails a run.
    public static func blastRadius(
        nodes: [DeploymentNode],
        sessions: [SessionRecord]
    ) -> [(node: DeploymentNode, sessions: [SessionRecord])] {
        nodes.filter { $0.state != "ok" }.map { node in
            (node, sessions.filter { $0.executor == node.name || $0.executorNode == node.id })
        }
    }

}
