import Foundation
import LoomKit

// How a review thread lays out `sessions.review`: the order of its files, which one
// opens, the words over each, and where each find is drawn. It mirrors the web
// view's `review_pin_rule.gleam` and the wording in `view/review_thread.gleam`.
//
// The daemon already merges the commits a session made into the same list as its
// working tree (protocol-change/123, "Addendum: committed work"): a file in both
// carries the working tree's hunks first and the committed ones after, and a file
// only the commits touched follows the working tree's. The wire carries no marker
// that says which hunk is which, and the web draws them as one list, so this rule
// does not separate them either.
//
// The rule is pure. A path, a hunk line and a find's text are text a repository or a
// model wrote; the rule compares and counts them, and the view draws them verbatim.
//
// ## Flow
//
// `ordered` puts the files in the order a reviewer reads them and the first one
// opens (`opensOnArrival`); `title`, `notices`, `changeWords` and `contentNotice`
// word the review; `place` gives every find exactly one place, a line of a shown
// hunk, the top of its file, or the top of the pane.

/// One find as the placing rule sees it: an identifier the pane keeps, and the place
/// the agent gave.
public struct ReviewPin: Sendable, Equatable {
    public let id: String
    public let path: String?
    public let line: Int?

    public init(id: String, path: String?, line: Int?) {
        self.id = id
        self.path = path
        self.line = line
    }
}

/// A find drawn after one line of one hunk.
public struct ReviewAnchor: Sendable, Equatable {
    /// The hunk's position among the file's shown hunks, from zero.
    public let hunk: Int
    /// The line's position among that hunk's shown lines, from zero.
    public let line: Int
    public let find: String
}

/// Where one shown file draws finds.
public struct ReviewFilePins: Sendable, Equatable {
    public let path: String
    /// The finds drawn at a line of a shown hunk, in the order the lines come.
    public let anchored: [ReviewAnchor]
    /// The finds that name the file and are drawn at its top: no line, or a line that
    /// no shown hunk holds.
    public let loose: [String]

    /// The finds anchored after one line of one hunk.
    public func at(hunk: Int, line: Int) -> [String] {
        anchored.filter { $0.hunk == hunk && $0.line == line }.map(\.find)
    }

    /// How many finds this file draws, anchored or loose.
    public var count: Int { anchored.count + loose.count }
}

/// Where every find is drawn.
public struct ReviewPlacement: Sendable, Equatable {
    /// One entry for each shown file, in the order given.
    public let files: [ReviewFilePins]
    /// The finds that name no shown file, drawn at the top of the pane.
    public let unplaced: [String]
}

public enum ReviewRule {
    // MARK: Order

    /// The files in the order a reviewer reads them: source, then tests, then docs,
    /// and by path inside each. The daemon sends them in this order, so the sort
    /// leaves what it sent alone; it holds the order for a review that was
    /// assembled any other way. Paths compare by their UTF-8 bytes, as the
    /// daemon's do.
    public static func ordered(_ files: [ReviewRead.File]) -> [ReviewRead.File] {
        files.sorted { left, right in
            let (a, b) = (rank(left.section), rank(right.section))
            if a != b { return a < b }
            return left.path.utf8.lexicographicallyPrecedes(right.path.utf8)
        }
    }

    private static func rank(_ section: ReviewRead.Section) -> Int {
        switch section {
        case .source: return 0
        case .tests: return 1
        case .docs: return 2
        }
    }

    /// Whether the file at `index` is open when the review arrives. The first one is,
    /// so the review shows code at once and the reader opens the others.
    public static func opensOnArrival(index: Int) -> Bool { index == 0 }

    // MARK: Words

    /// The thread's title once the review is read: "Ready to review: +412 −88 across
    /// 7 files".
    public static func title(_ stat: ReviewRead.Stat) -> String {
        "Ready to review: +\(stat.added) \u{2212}\(stat.removed) across \(stat.files) \(stat.files == 1 ? "file" : "files")"
    }

    /// Every statement of what was not shown, so a count is never read as complete
    /// when it is not.
    public static func notices(_ review: ReviewRead) -> [String] {
        var words: [String] = []
        if review.repository == .unborn { words.append("The repository has no commit yet, so every file is new.") }
        if review.omitted > 0 {
            words.append("\(review.omitted) \(review.omitted == 1 ? "file" : "files") not shown")
        }
        if review.extent == .cut { words.append("Part of this diff was cut to fit, so its counts are lower bounds.") }
        return words
    }

    /// The word for what happened to a file.
    public static func changeWords(_ file: ReviewRead.File) -> String {
        switch file.change {
        case .added: return "added"
        case .modified: return "modified"
        case .deleted: return "deleted"
        }
    }

    /// The file's line counts, as far as its patch was read.
    public static func counts(_ file: ReviewRead.File) -> String {
        "+\(file.added) \u{2212}\(file.removed)"
    }

    /// What a file says when the observation had no text to show for it, or nil for
    /// one that has hunks to draw.
    public static func contentNotice(_ file: ReviewRead.File) -> String? {
        switch file.content {
        case .text: return nil
        case .binary: return "Binary file: named, with no hunks."
        case .noNetChange: return "Touched, and its content is the same."
        case .metadataOnly: return "Its mode or other metadata changed, with no text to show."
        }
    }

    /// The statements under a file's hunks about what was cut from it.
    public static func cutNotices(_ file: ReviewRead.File) -> [String] {
        var words: [String] = []
        if file.hunksOmitted > 0 {
            words.append("\(file.hunksOmitted) \(file.hunksOmitted == 1 ? "more hunk" : "more hunks") not shown")
        }
        if file.extent == .cut { words.append("This file's patch was cut, so its counts are lower bounds.") }
        return words
    }

    /// What a hunk says about lines left out of it or cut short.
    public static func hunkNotices(_ hunk: ReviewRead.Hunk) -> [String] {
        var words: [String] = []
        if hunk.omitted > 0 { words.append("\(hunk.omitted) \(hunk.omitted == 1 ? "line" : "lines") not shown") }
        if hunk.shortened > 0 {
            words.append("\(hunk.shortened) \(hunk.shortened == 1 ? "line" : "lines") shortened to \(ReviewRead.maxLineBytes) bytes")
        }
        return words
    }

    /// The marker a find carries at its line: "!" for a risk, "i" for any other.
    public static func marker(_ kind: FindKind) -> String { kind == .risk ? "!" : "i" }

    // MARK: Placing finds

    /// Gives every find exactly one place. A path is compared as the review holds
    /// it, after a leading "./" is dropped from the find's; no other normalising is
    /// done, so a path that differs in any other way names another file. A find
    /// whose line is in a shown hunk is anchored there, a find that names a shown
    /// file and no shown line is loose at the top of the file, and a find that names
    /// no shown file is unplaced.
    public static func place(files: [ReviewRead.File], pins: [ReviewPin]) -> ReviewPlacement {
        let placed = files.map { file -> ReviewFilePins in
            let located = pins.filter { names($0, file.path) }.map { ($0, locate(file, $0)) }
            let anchored = located.compactMap { pin, spot in
                spot.map { ReviewAnchor(hunk: $0.hunk, line: $0.line, find: pin.id) }
            }
            return ReviewFilePins(
                path: file.path,
                anchored: anchored.sorted(by: before),
                loose: located.filter { $0.1 == nil }.map { $0.0.id }
            )
        }
        let unplaced = pins.filter { pin in !files.contains { names(pin, $0.path) } }.map(\.id)
        return ReviewPlacement(files: placed, unplaced: unplaced)
    }

    private static func names(_ pin: ReviewPin, _ path: String) -> Bool {
        guard let named = pin.path else { return false }
        return (named.hasPrefix("./") ? String(named.dropFirst(2)) : named) == path
    }

    /// The first shown line that carries the find's line number. Only a line with a
    /// number in the new file can be named: an added line or a context line.
    private static func locate(_ file: ReviewRead.File, _ pin: ReviewPin) -> (hunk: Int, line: Int)? {
        guard let wanted = pin.line else { return nil }
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            for (lineIndex, line) in hunk.lines.enumerated() where line.new == wanted {
                if line.kind == .added || line.kind == .context { return (hunkIndex, lineIndex) }
            }
        }
        return nil
    }

    /// Orders anchors by hunk and line, and then by find, so two reads agree.
    private static func before(_ left: ReviewAnchor, _ right: ReviewAnchor) -> Bool {
        if left.hunk != right.hunk { return left.hunk < right.hunk }
        if left.line != right.line { return left.line < right.line }
        return left.find < right.find
    }
}
