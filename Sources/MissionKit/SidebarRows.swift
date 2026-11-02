import Foundation
import LoomKit

/// What the sidebar says about one session, decided apart from the view so a test
/// can read it. The accessibility tree does not list the sidebar's rows, so the
/// debug snapshot prints these values and the view draws the same ones.
public struct SidebarRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// The first line of the session's first prompt, when the daemon kept one.
    public let subtitle: String?
    /// The standing in plain words: working, idle, needs you, saved, and so on.
    public let standing: String
    /// How long ago the session was created, as the quiet line states it.
    public let created: String
    /// The directory name of the git worktree the session runs in, if it runs in one.
    public let worktree: String?
    /// The project heading the row belongs under.
    public let project: String
    /// The machine whose tools the row uses, which a single machine never names.
    public let machine: String
}

/// A heading with its rows and the number a heading states.
public struct SidebarSection: Sendable, Equatable {
    public let title: String
    public let rows: [SidebarRow]
    public var count: Int { rows.count }
}

/// How the sidebar's sections are chosen and ordered.
public enum SidebarGrouping: String, CaseIterable, Identifiable, Sendable {
    case status = "Status"
    case project = "Project"
    case machine = "Machine"
    public var id: Self { self }
}

public enum SidebarRows {
    /// The standing of a session in words. A resident session says what the agent
    /// is doing, and any other says where the session stands.
    public static func standing(of record: SessionRecord, activity: SessionActivity?) -> String {
        if let target = record.movingTo { return "moving to \(target)" }
        switch record.state {
        case .reserved(let failure?): return "failed to start: \(failure)"
        case .reserved: return "starting"
        case .saved: return "saved"
        case .opening: return "opening"
        case .stopping: return "stopping"
        case .recoveryBlocked: return "needs attention"
        case .unknown: return "unknown"
        case .resident:
            switch activity?.state {
            case .needsYou: return "needs you"
            case .working: return "working"
            case .idle: return "idle"
            case .unknown, nil: return "running"
            }
        }
    }

    /// The worktree's directory name, read from the `.git` entry of the workspace.
    /// A linked worktree keeps a file there that points into the repository's
    /// `worktrees` directory, and the repository's own checkout keeps a directory,
    /// so only a file whose pointer names `worktrees` counts.
    public static func worktree(workspace: String, gitPointer: String?) -> String? {
        guard let pointer = gitPointer, pointer.hasPrefix("gitdir:"), pointer.contains("/worktrees/") else { return nil }
        let name = (workspace as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Words for a time since creation: "4 minutes ago", "2 hours ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return unit(seconds / 60, "minute")
        case ..<86400: return unit(seconds / 3600, "hour")
        default: return unit(seconds / 86400, "day")
        }
    }

    /// One row for each session.
    public static func row(
        _ record: SessionRecord,
        activity: SessionActivity?,
        machine: String,
        gitPointer: String? = nil,
        now: Date = Date()
    ) -> SidebarRow {
        SidebarRow(
            id: record.id,
            title: record.title,
            subtitle: record.subtitle.flatMap { $0 == record.title || $0.isEmpty ? nil : $0 },
            standing: standing(of: record, activity: activity),
            created: ago(record.createdAt, now: now),
            worktree: record.executor == nil && record.pool == nil
                ? worktree(workspace: record.workspace, gitPointer: gitPointer) : nil,
            project: record.workspaceName,
            machine: machine
        )
    }

    /// Sections in the order a person reads them. Rows are newest first within a
    /// section, and a machine filter keeps only that machine's rows. Saved rows are
    /// left to the caller, which folds them apart.
    public static func sections(
        _ records: [SessionRecord],
        activity: [String: SessionActivity],
        grouping: SidebarGrouping,
        machine: (SessionRecord) -> String,
        machineFilter: String? = nil,
        gitPointer: (SessionRecord) -> String? = { _ in nil },
        now: Date = Date()
    ) -> [SidebarSection] {
        let rows: [(SessionRecord, SidebarRow)] = records
            .filter { machineFilter == nil || machine($0) == machineFilter }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            .map { ($0, row($0, activity: activity[$0.id], machine: machine($0), gitPointer: gitPointer($0), now: now)) }
        func liveness(_ record: SessionRecord) -> AgentCard.Liveness {
            Mission.liveness(session: record, activity: activity[record.id])
        }
        switch grouping {
        case .status:
            let order: [(AgentCard.Liveness, String)] = [(.needsYou, "Needs You"), (.working, "Working"), (.idle, "Idle"), (.unknown, "Not Answering")]
            return order.compactMap { state, title in
                let found = rows.filter { liveness($0.0) == state }.map(\.1)
                return found.isEmpty ? nil : SidebarSection(title: title, rows: found)
            }
        case .project, .machine:
            let live = rows.filter { liveness($0.0) != .off }
            let key: (SidebarRow) -> String = { grouping == .project ? $0.project : $0.machine }
            return Dictionary(grouping: live.map(\.1), by: key)
                .map { SidebarSection(title: $0.key, rows: $0.value) }
                .sorted { $0.title < $1.title }
        }
    }

    /// Rows that are not running, which the sidebar folds under "Saved".
    public static func saved(
        _ records: [SessionRecord],
        activity: [String: SessionActivity],
        machine: (SessionRecord) -> String,
        machineFilter: String? = nil,
        now: Date = Date()
    ) -> [SidebarRow] {
        records
            .filter { Mission.liveness(session: $0, activity: activity[$0.id]) == .off && (machineFilter == nil || machine($0) == machineFilter) }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            .map { row($0, activity: nil, machine: machine($0), now: now) }
    }
}
