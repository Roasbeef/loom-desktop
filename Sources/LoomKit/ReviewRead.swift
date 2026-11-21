import Foundation

// A session's worktree as a reviewer reads it, from `sessions.review` (loom
// protocol-change/123). The decoder is total, as the ones in `AttentionFeed.swift`
// are.

/// A session's worktree as a reviewer reads it, from `sessions.review`.
///
/// Everything is bounded and every cut is counted: at most `maxFiles` files,
/// `maxHunks` hunks a file, `maxHunkLines` lines a hunk and `maxLineBytes` bytes a
/// line. The decoder holds the same bounds on what it keeps, so a decoded review is
/// bounded in shape even when the daemon was not the one that sent it. A path or a
/// line is the repository's own text and is drawn as text.
public struct ReviewRead: Sendable, Equatable {
    public static let maxFiles = 24
    public static let maxHunks = 12
    public static let maxHunkLines = 80
    public static let maxLineBytes = 400

    public enum Repository: String, Sendable, Equatable {
        case head, unborn
        case notRepository = "not_repository"
    }

    public enum Extent: String, Sendable, Equatable {
        case whole, cut
    }

    public enum Section: String, Sendable, Equatable {
        case source, tests, docs
    }

    public enum Change: String, Sendable, Equatable {
        case added, modified, deleted
    }

    public enum Content: String, Sendable, Equatable {
        case text, binary
        case noNetChange = "no_net_change"
        case metadataOnly = "metadata_only"
    }

    public struct Stat: Sendable, Equatable {
        /// Every file the observation read, those left out of `files` included.
        public let files: Int
        public let added: Int
        public let removed: Int
    }

    public struct Line: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case added = "+", removed = "-", context = " ", noNewline = "\\"
        }

        public let kind: Kind
        /// The line numbers in the old and the new file, when the hunk header gave them.
        public let old: Int?
        public let new: Int?
        public let text: String
    }

    public struct Hunk: Sendable, Equatable {
        public let header: String
        public let lines: [Line]
        /// Lines past the bound that were left out.
        public let omitted: Int
        /// How many of `lines` were cut to the byte bound.
        public let shortened: Int
    }

    public struct File: Sendable, Equatable, Identifiable {
        public let path: String
        public let change: Change
        public let section: Section
        public let content: Content
        public let added: Int
        public let removed: Int
        public let hunks: [Hunk]
        public let hunksOmitted: Int
        public let extent: Extent
        public var id: String { path }
    }

    public let observedAtMs: Int
    public let repository: Repository
    public let stat: Stat
    public let files: [File]
    /// Files read and not carried.
    public let omitted: Int
    public let extent: Extent

    init?(_ body: JSONValue) {
        guard let observed = body["observed_at_ms"]?.natural,
              let repository = body["repository"]?.string.flatMap(Repository.init(rawValue:)),
              let stat = Self.stat(body["stat"]),
              let omitted = body["omitted"]?.natural,
              let extent = body["extent"]?.string.flatMap(Extent.init(rawValue:)),
              let raw = body["files"]?.array
        else { return nil }

        // Each file decodes alone, and one that does not is a file left out. The
        // review then says it was cut, since something was not carried.
        let files = raw.prefix(Self.maxFiles).compactMap(Self.file)
        let dropped = raw.count - files.count
        observedAtMs = observed
        self.repository = repository
        self.stat = stat
        self.files = files
        self.omitted = omitted + dropped
        self.extent = dropped == 0 ? extent : .cut
    }

    private static func stat(_ value: JSONValue?) -> Stat? {
        guard let value, let files = value["files"]?.natural, let added = value["added"]?.natural,
              let removed = value["removed"]?.natural
        else { return nil }
        return Stat(files: files, added: added, removed: removed)
    }

    /// A file, or nil for one that is damaged or whose path is not relative to the
    /// workspace. A hunk that does not decode makes its whole file damaged, so a
    /// reviewer never reads a file with a hunk missing and nothing said.
    private static func file(_ value: JSONValue) -> File? {
        guard let path = value["path"]?.string, isWorkspaceRelative(path),
              let change = value["change"]?.string.flatMap(Change.init(rawValue:)),
              let section = value["section"]?.string.flatMap(Section.init(rawValue:)),
              let content = value["content"]?.string.flatMap(Content.init(rawValue:)),
              let added = value["added"]?.natural, let removed = value["removed"]?.natural,
              let hunksOmitted = value["hunks_omitted"]?.natural,
              let extent = value["extent"]?.string.flatMap(Extent.init(rawValue:)),
              let rawHunks = value["hunks"]?.array
        else { return nil }
        var hunks: [Hunk] = []
        for raw in rawHunks.prefix(maxHunks) {
            guard let hunk = hunk(raw) else { return nil }
            hunks.append(hunk)
        }
        return File(
            path: path, change: change, section: section, content: content, added: added, removed: removed,
            hunks: hunks, hunksOmitted: hunksOmitted, extent: extent
        )
    }

    private static func hunk(_ value: JSONValue) -> Hunk? {
        guard let header = value["header"]?.string, let omitted = value["omitted"]?.natural,
              let shortened = value["shortened"]?.natural, let rawLines = value["lines"]?.array
        else { return nil }
        var lines: [Line] = []
        for raw in rawLines.prefix(maxHunkLines) {
            guard let kind = raw["k"]?.string.flatMap(Line.Kind.init(rawValue:)), let text = raw["t"]?.string
            else { return nil }
            lines.append(Line(kind: kind, old: raw["o"]?.natural, new: raw["n"]?.natural, text: prefix(text, bytes: maxLineBytes)))
        }
        return Hunk(header: prefix(header, bytes: maxLineBytes), lines: lines, omitted: omitted, shortened: shortened)
    }

    /// A path that is absolute or climbs out of the workspace is not a workspace
    /// path, and a file at one is not drawn.
    static func isWorkspaceRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// The longest prefix of `text` within `bytes` UTF-8 bytes that ends between
    /// characters, so a cut never splits one.
    static func prefix(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var used = 0
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            if used + size > limit { break }
            used += size
            kept.append(scalar)
        }
        return String(kept)
    }
}
