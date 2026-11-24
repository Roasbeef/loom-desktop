import Foundation

/// One row of the folder picker: a place a session could start, and why it is
/// offered. The picker draws the short name large and the parent path dimmed
/// beside it, so two folders called "loom" can be told apart.
public struct PickerChoice: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A folder one of this daemon's local sessions already used.
        case recent
        /// A project the daemon runs. Choosing it chooses its workspace.
        case project(id: String)
        /// A folder found below the person's roots by `FolderIndex`.
        case found
        /// Text the person typed, offered as a path (or, for an executor, a name)
        /// for the daemon to judge.
        case typed
    }

    public let path: String
    public let kind: Kind

    public var id: String {
        switch kind {
        case .recent: return "recent:\(path)"
        case .project(let id): return "project:\(id)"
        case .found: return "found:\(path)"
        case .typed: return "typed:\(path)"
        }
    }

    /// The last path component, which is the name a person knows the folder by.
    public var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    /// Everything before the name, with the home directory written as `~`.
    public var parent: String {
        FolderPicker.abbreviate((path as NSString).deletingLastPathComponent)
    }

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// A project as `projects.list` states it. Only what the picker needs is kept.
public struct ProjectRef: Sendable, Equatable {
    public let id: String
    public let workspace: String

    public init(id: String, workspace: String) {
        self.id = id
        self.workspace = workspace
    }

    /// Decodes the reply's `projects` array. A row without both fields is dropped
    /// rather than shown half-known.
    public init?(_ row: JSONValue) {
        guard let id = row["id"]?.string, !id.isEmpty,
              let workspace = row["workspace"]?.string, !workspace.isEmpty else { return nil }
        self.init(id: id, workspace: workspace)
    }
}

/// The sections of the picker, in the order they are drawn. A section with no
/// rows is not drawn.
public struct PickerSections: Sendable, Equatable {
    public var recent: [PickerChoice] = []
    public var projects: [PickerChoice] = []
    public var found: [PickerChoice] = []
    public var typed: [PickerChoice] = []

    /// Whether the typed row is drawn first. A person who types a whole path
    /// means that path, so Return must take it before any folder that merely
    /// contains the text.
    public var typedLeads = false

    /// Every row in drawing order, which is the order the arrow keys walk and the
    /// order Return takes its first choice from.
    public var all: [PickerChoice] { typedLeads ? typed + recent + projects + found : recent + projects + found + typed }

    public init() {}
}

/// What the folder picker shows for what has been typed, kept free of views so
/// the order and the matching can be tested without a window.
///
/// Matching is by name fragment anywhere in the path, ignoring case. Several
/// words must all match, in any order, so "gocode loom" finds the loom folder
/// below gocode. Within a section a match on the short name ranks above a match
/// only in the parent path, and a name that starts with the text ranks first;
/// ties keep the order the source gave, which is newest first for recent folders.
public enum FolderPicker {
    /// How many recent folders the picker shows with nothing typed.
    public static let recentShown = 8

    /// How many folders found by search are shown for one query. The index holds
    /// more; this keeps the list readable.
    public static let foundShown = 30

    /// Splits typed text into the lowercased words a row must all contain.
    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Lower is better, and nil means the row does not match. A name that is
    /// exactly the text ranks above a longer name that starts with it, so
    /// "loom" finds `loom` before `loom-site`.
    static func rank(_ path: String, words: [String]) -> Int? {
        let lowered = path.lowercased()
        let name = ((path as NSString).lastPathComponent).lowercased()
        guard words.allSatisfy({ lowered.contains($0) }) else { return nil }
        if words.count == 1, name == words[0] { return 0 }
        if words.allSatisfy({ name.hasPrefix($0) }) { return 1 }
        if words.allSatisfy({ name.contains($0) }) { return 2 }
        return 3
    }

    /// The rows of each section for the text typed so far.
    ///
    /// With nothing typed, the picker shows the newest recent folders and the
    /// projects. With text, it shows every recent folder and project that
    /// matches, then folders found by the index that are not already listed, and
    /// finally the text itself when it names a path (starts with `/` or `~`) or
    /// matches nothing at all, so a person can always use what they typed. Text
    /// that names a path leads the list.
    public static func sections(
        query: String,
        recent: [String],
        projects: [ProjectRef],
        found: [String]
    ) -> PickerSections {
        var sections = PickerSections()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = words(trimmed)
        var shown = Set<String>()

        if words.isEmpty {
            sections.projects = projects.prefix(recentShown).map { PickerChoice(path: $0.workspace, kind: .project(id: $0.id)) }

            // A project's workspace is drawn once, under Projects.
            let owned = Set(projects.map(\.workspace))
            sections.recent = recent.filter { !owned.contains($0) }.prefix(recentShown).map { PickerChoice(path: $0, kind: .recent) }
            return sections
        }

        func ranked<T>(_ items: [T], path: (T) -> String) -> [T] {
            items.enumerated()
                .compactMap { index, item in rank(path(item), words: words).map { (index, $0, item) } }
                .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
                .map(\.2)
        }

        sections.recent = ranked(recent, path: { $0 }).map { shown.insert($0); return PickerChoice(path: $0, kind: .recent) }
        sections.projects = ranked(projects, path: \.workspace).map {
            shown.insert($0.workspace)
            return PickerChoice(path: $0.workspace, kind: .project(id: $0.id))
        }

        // A project's workspace is usually a recent folder too. It is drawn once,
        // under the heading that names what it is.
        sections.recent.removeAll { choice in sections.projects.contains { $0.path == choice.path } }
        let pool = found.filter { !shown.contains($0) }
        sections.found = ranked(pool, path: { $0 }).prefix(foundShown).map { PickerChoice(path: $0, kind: .found) }

        let isPath = trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
        if isPath || sections.all.isEmpty {
            sections.typed = [PickerChoice(path: trimmed, kind: .typed)]
            sections.typedLeads = isPath
        }
        return sections
    }

    /// A path with the home directory written as `~`, for the dimmed parent.
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// The folders below a person's roots that a session could start in, found by a
/// bounded walk so the picker can match any folder and not only recent ones.
///
/// This is the app's own walk of its own disk, which is right for a daemon on
/// this Mac: the daemon's `home.Folders.browse` (protocol-change/132) is an
/// in-process read of the web view and has no control command, and the desktop
/// already judges typed folders against the same disk (`FolderCheck`). The
/// daemon still judges the chosen path when the session is created, so this list
/// is advice, as 132 says of its own.
///
/// The walk keeps the rules 132 states for the listing, so the picker does not
/// offer what creation would refuse: no hidden folder, no `~/Library`, no folder
/// the person cannot write, and no link followed, since a link can leave the
/// root. It adds bounds of its own: breadth first so shallow folders come before
/// deep ones if a limit stops the walk, a depth limit, a visit limit, a result
/// limit and a deadline. A folder that holds a `.git` is a checkout, and below
/// one only folders that hold a `.git` themselves are listed (sub-repositories
/// and worktrees), so a source tree is not listed and a repository under a
/// container repository is. The walk still enters a checkout's folders to find
/// those, except build and dependency folders, which hold copies of other
/// people's code.
///
/// The limits are sized so that the deadline, not a count, is what normally
/// ends a walk of a large home directory. Breadth first means a deadline cut
/// loses the deepest level and not a whole branch.
public enum FolderIndex {
    public static let depthLimit = 6
    public static let visitLimit = 20_000
    public static let resultLimit = 20_000
    public static let deadline: TimeInterval = 2

    /// Folders never entered, because they hold dependencies or build output.
    static let skipped: Set<String> = ["node_modules", "vendor", "target", "build", "dist"]

    /// One directory read: the folders it lists, and the directories to read next.
    private struct Read: Sendable {
        var listed: [String] = []
        var next: [Directory] = []
    }

    private struct Directory: Sendable {
        let url: URL
        let isRoot: Bool
        let inCheckout: Bool
    }

    /// The folders below `roots`, shallowest first and alphabetical within a
    /// depth. The roots themselves are not listed. `isCancelled` is asked before
    /// each directory is read, so a walk nobody waits for stops.
    ///
    /// The directories of one depth are read in parallel, since a cold read of
    /// a large home directory is bound by file system latency and not by the
    /// processor. Each read returns its own result and the results are merged in
    /// directory order, so the list does not depend on which read finished first.
    public static func scan(
        roots: [URL],
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> [String] {
        let stop = now().addingTimeInterval(deadline)
        var found: [String] = []
        var visited = 0
        var level = roots.map { Directory(url: $0.resolvingSymlinksInPath(), isRoot: true, inCheckout: false) }

        for depth in 1...depthLimit {
            guard visited < visitLimit, !level.isEmpty else { break }
            let batch = Array(level.prefix(visitLimit - visited))
            visited += batch.count
            let reads = Reads(count: batch.count)
            DispatchQueue.concurrentPerform(iterations: batch.count) { index in
                guard now() < stop, !isCancelled() else { return }
                reads.set(index, read(batch[index], fileManager: fileManager, expandsFurther: depth < depthLimit))
            }

            var next: [Directory] = []
            for result in reads.all {
                found.append(contentsOf: result.listed)
                next.append(contentsOf: result.next)
            }
            if found.count >= resultLimit { return Array(found.prefix(resultLimit)) }
            if now() >= stop || isCancelled() { return found }
            level = next
        }
        return found
    }

    /// Lists one directory under the rules above.
    private static func read(_ directory: Directory, fileManager: FileManager, expandsFurther: Bool) -> Read {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isWritableKey, .isPackageKey]
        let wanted = Set(keys)
        var result = Read()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return result }

        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let values = try? entry.resourceValues(forKeys: wanted)
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                  values?.isPackage != true, values?.isWritable == true else { continue }

            // A first-level `Library` is the macOS folder 132 refuses to list.
            let name = entry.lastPathComponent
            if directory.isRoot && name == "Library" { continue }
            if skipped.contains(name) { continue }
            let isRepository = fileManager.fileExists(atPath: entry.appendingPathComponent(".git").path)
            if isRepository || !directory.inCheckout { result.listed.append(entry.path) }
            if expandsFurther {
                result.next.append(Directory(url: entry, isRoot: false, inCheckout: directory.inCheckout || isRepository))
            }
        }
        return result
    }

    /// The results of one depth's parallel reads, each written by exactly one
    /// iteration into its own slot.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [Read]

        init(count: Int) { slots = Array(repeating: Read(), count: count) }

        func set(_ index: Int, _ value: Read) {
            lock.lock()
            slots[index] = value
            lock.unlock()
        }

        var all: [Read] { lock.lock(); defer { lock.unlock() }; return slots }
    }

    /// The same walk run off the main actor, stopping when the awaiting task is
    /// cancelled.
    @concurrent
    public static func scanOffMain(roots: [URL]) async -> [String] {
        scan(roots: roots, isCancelled: { Task.isCancelled })
    }
}
