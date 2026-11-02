import Foundation
import LoomKit
import SubstrateKit

/// One thing waiting on a person, from either system.
///
/// The inbox groups by what an item needs rather than by who sent it, so a
/// Loom approval and a Substrate question sit in one list.
public struct AttentionItem: Sendable, Identifiable, Equatable {
    public enum Kind: Int, Sendable, Comparable, CaseIterable {
        case approval, question, plan, failed, blocked

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        public var title: String {
            switch self {
            case .approval: return "Needs approval"
            case .question: return "Questions"
            case .plan: return "Plans to review"
            case .failed: return "Failed runs"
            case .blocked: return "Blocked"
            }
        }
    }

    public enum Source: Sendable, Equatable {
        /// A Loom session. `escalation` is nil until the record has been read
        /// from the session's own lane, since activity reports only a count.
        case loom(sessionID: String, escalation: Escalation?)
        case substrate(agent: String, threadID: String?, planReviewID: String?)
    }

    public let id: String
    public let kind: Kind
    public let source: Source
    public let agent: String
    public let title: String
    public let detail: String
}

/// One agent on the mission control board, from either system.
public struct AgentCard: Sendable, Identifiable, Equatable {
    public enum Liveness: Int, Sendable, Comparable {
        case needsYou, working, idle, off

        public static func < (lhs: Liveness, rhs: Liveness) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Origin: Sendable, Equatable {
        case loom(sessionID: String)
        case substrate(agentID: Int64)
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
    public let origin: Origin
    public let name: String
    public let context: String
    public let liveness: Liveness
    public let digest: String
    public let model: String?
    public let lines: [Line]
    public let waitingCount: Int
}

/// Combines both systems' observations into the two shared views.
///
/// These are pure functions so the merge rules are tested without a daemon.
public enum Mission {
    public static func attention(
        sessions: [SessionRecord],
        activity: [String: SessionActivity],
        escalations: [String: [Escalation]],
        feed: CommandFeed?
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
                        source: .loom(sessionID: session.id, escalation: nil),
                        agent: session.title,
                        title: "\(row.approvals) pending approval\(row.approvals == 1 ? "" : "s")",
                        detail: "Reading the request from the session."
                    ))
                }
                for escalation in known {
                    items.append(.init(
                        id: "loom/\(session.id)/\(escalation.id)",
                        kind: .approval,
                        source: .loom(sessionID: session.id, escalation: escalation),
                        agent: session.title,
                        title: escalation.reason.isEmpty ? "Allow \(escalation.tool)?" : escalation.reason,
                        detail: escalation.safePreview
                    ))
                }
            } else {
                items.append(.init(
                    id: "loom/\(session.id)/failed",
                    kind: .failed,
                    source: .loom(sessionID: session.id, escalation: nil),
                    agent: session.title,
                    title: "The last run failed",
                    detail: row.lastMessage ?? "The session reported no final message."
                ))
            }
        }

        for row in feed?.attention ?? [] {
            items.append(.init(
                id: "substrate/\(row.kind)/\(row.agentID)/\(row.messageID ?? 0)/\(row.planReviewID ?? "")",
                kind: kind(substrate: row.kind),
                source: .substrate(agent: row.agentName, threadID: row.threadID, planReviewID: row.planReviewID),
                agent: row.agentName,
                title: row.title,
                detail: row.detail ?? ""
            ))
        }
        return items.sorted { $0.kind < $1.kind }
    }

    static func kind(substrate: String) -> AttentionItem.Kind {
        switch substrate {
        case "plan": return .plan
        case "blocked": return .blocked
        default: return .question
        }
    }

    public static func cards(
        sessions: [SessionRecord],
        activity: [String: SessionActivity],
        feed: CommandFeed?
    ) -> [AgentCard] {
        var cards = sessions.map { session -> AgentCard in
            let row = activity[session.id]
            let lines = (row?.glances ?? []).map {
                AgentCard.Line(id: $0.strand, label: $0.title, text: $0.summary)
            }
            return AgentCard(
                id: "loom/\(session.id)",
                origin: .loom(sessionID: session.id),
                name: session.title,
                context: session.workspaceName,
                liveness: liveness(session: session, activity: row),
                digest: row?.lastMessage ?? session.subtitle ?? "",
                model: row?.model,
                lines: lines,
                waitingCount: row?.approvals ?? 0
            )
        }

        for lane in feed?.lanes ?? [] where lane.agent.name != "User" {
            let context = [lane.agent.projectKey, lane.agent.gitBranch]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            let waiting = lane.needsActionCount > 0 || lane.waitingFor != nil
            cards.append(AgentCard(
                id: "substrate/\(lane.agent.id)",
                origin: .substrate(agentID: lane.agent.id),
                name: lane.agent.name,
                context: context,
                liveness: waiting ? .needsYou : liveness(substrate: lane.agent.status),
                digest: lane.waitingFor.map { "Waiting on you: \($0)" } ?? lane.agent.purpose ?? "",
                model: nil,
                lines: (lane.events ?? []).prefix(3).map {
                    AgentCard.Line(id: String($0.messageID), label: $0.kind, text: $0.subject)
                },
                waitingCount: lane.needsActionCount
            ))
        }
        return cards.sorted { ($0.liveness, $0.name) < ($1.liveness, $1.name) }
    }

    static func liveness(session: SessionRecord, activity: SessionActivity?) -> AgentCard.Liveness {
        switch activity?.state {
        case .needsYou: return .needsYou
        case .working: return .working
        case .idle, .unknown: return .idle
        case nil: return session.state.isResident ? .idle : .off
        }
    }

    static func liveness(substrate status: String) -> AgentCard.Liveness {
        switch status {
        case "active", "busy": return .working
        case "idle": return .idle
        default: return .off
        }
    }
}
