import Foundation
import LoomKit
import MissionKit

/// The sidebar's data, which the view and the debug snapshot both read so that a
/// test of one is a test of the other.
extension AppModel {
    /// The machine whose tools a session uses. A single machine has only one name.
    func machine(of record: SessionRecord) -> String {
        placement(of: record)?.hands ?? "This machine"
    }

    /// The pointer a linked git worktree keeps at its top, which names the
    /// repository it belongs to. Only a daemon on this Mac has a workspace this
    /// app can read.
    func gitPointer(of record: SessionRecord) -> String? {
        guard record.executor == nil, record.pool == nil, daemon(holding: record.id)?.isRemote == false else { return nil }
        return WorkspaceGit.pointer(record.workspace)
    }

    func sidebarSections(grouping: SidebarGrouping, machineFilter: String?) -> [SidebarSection] {
        let records = sessions.filter(isListed)
        return SidebarRows.sections(
            records, activity: activity, grouping: grouping,
            machine: { [self] in machine(of: $0) },
            machineFilter: machineFilter,
            gitPointer: { [self] in gitPointer(of: $0) }
        )
    }

    func sidebarSaved(machineFilter: String?) -> [SidebarRow] {
        SidebarRows.saved(sessions.filter(isListed), activity: activity, machine: { [self] in machine(of: $0) }, machineFilter: machineFilter)
    }

    /// A reservation without a failure is a create still in flight, not a session.
    private func isListed(_ record: SessionRecord) -> Bool {
        if case .reserved(let failure) = record.state { return failure != nil }
        return true
    }

    /// Each machine that holds listed sessions, with how many.
    var machineCounts: [(name: String, count: Int)] {
        Dictionary(grouping: sessions.filter(isListed), by: { machine(of: $0) })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name < $1.name }
    }
}

/// Reads a workspace's `.git` entry. A linked worktree has a file there, so a
/// directory or a missing entry reads as nothing.
enum WorkspaceGit {
    @MainActor private static var known: [String: String?] = [:]

    @MainActor static func pointer(_ workspace: String) -> String? {
        if let hit = known[workspace] { return hit }
        let path = (workspace as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        var text: String?
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            text = try? String(contentsOfFile: path, encoding: .utf8)
        }
        known[workspace] = text
        return text
    }
}
