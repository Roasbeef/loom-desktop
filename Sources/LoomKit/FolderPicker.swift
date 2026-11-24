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

    /// Lower is better, and nil means the row does not match.
    static func rank(_ path: String, words: [String]) -> Int? {
        let lowered = path.lowercased()
        let name = ((path as NSString).lastPathComponent).lowercased()
        guard words.allSatisfy({ lowered.contains($0) }) else { return nil }
        if words.allSatisfy({ name.hasPrefix($0) }) { return 0 }
        if words.allSatisfy({ name.contains($0) }) { return 1 }
        return 2
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
        found: [String],
        offersTyped: Bool = true
    ) -> PickerSections {
        var sections = PickerSections()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = words(trimmed)
        var shown = Set<String>()

        if words.isEmpty {
            sections.recent = recent.prefix(recentShown).map { PickerChoice(path: $0, kind: .recent) }
            sections.projects = projects.prefix(recentShown).map { PickerChoice(path: $0.workspace, kind: .project(id: $0.id)) }
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
        if offersTyped, isPath || sections.all.isEmpty {
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
/// limit and a deadline. A folder that holds a `.git` is listed and not entered,
/// because its subfolders are build output and source layout more often than
/// places a person starts a session; a path typed in the picker still reaches
/// them.
public enum FolderIndex {
    public static let depthLimit = 6
    public static let visitLimit = 5000
    public static let resultLimit = 3000
    public static let deadline: TimeInterval = 2

    /// The folders below `roots`, shallowest first and alphabetical within a
    /// depth. The roots themselves are not listed.
    public static func scan(roots: [URL], fileManager: FileManager = .default, now: () -> Date = Date.init) -> [String] {
        let stop = now().addingTimeInterval(deadline)
        var found: [String] = []
        var visited = 0
        var level = roots.map { ($0.resolvingSymlinksInPath(), true) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isWritableKey]

        for depth in 1...depthLimit {
            var next: [(URL, Bool)] = []
            for (directory, isRoot) in level {
                guard visited < visitLimit, found.count < resultLimit, now() < stop else { return found }
                visited += 1
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    guard found.count < resultLimit else { return found }
                    let values = try? entry.resourceValues(forKeys: Set(keys))
                    guard values?.isDirectory == true, values?.isSymbolicLink != true, values?.isWritable == true else { continue }

                    // A first-level `Library` is the macOS folder 132 refuses to list.
                    if isRoot && entry.lastPathComponent == "Library" { continue }
                    found.append(entry.path)
                    let isRepository = fileManager.fileExists(atPath: entry.appendingPathComponent(".git").path)
                    if depth < depthLimit && !isRepository { next.append((entry, false)) }
                }
            }
            level = next
        }
        return found
    }
}
