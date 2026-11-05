import Foundation

/// A unified patch read into lines a view can number and colour.
public struct DiffHunk: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case context, added, removed
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public let id: Int
        public let kind: Kind
        public let oldNumber: Int?
        public let newNumber: Int?
        public let text: String
    }

    public let id: Int
    public let header: String
    public let lines: [Line]
}

public struct DiffSummary: Sendable, Equatable {
    public let hunks: [DiffHunk]
    public let added: Int
    public let removed: Int
}

public enum Diff {
    /// Reads one file's patch. File headers are dropped, since the caller already
    /// names the file. A line outside any hunk becomes context, so a truncated or
    /// unusual patch still shows every line it was given.
    public static func parse(_ patch: String) -> DiffSummary {
        var hunks: [DiffHunk] = []
        var header = ""
        var lines: [DiffHunk.Line] = []
        var oldLine = 0
        var newLine = 0
        var added = 0
        var removed = 0
        var nextID = 0

        func close() {
            if !lines.isEmpty || !header.isEmpty {
                hunks.append(.init(id: hunks.count, header: header, lines: lines))
            }
            lines = []
        }

        func append(_ kind: DiffHunk.Kind, old: Int?, new: Int?, _ text: String) {
            lines.append(.init(id: nextID, kind: kind, oldNumber: old, newNumber: new, text: text))
            nextID += 1
        }

        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                close()
                header = line
                let numbers = hunkStart(line)
                oldLine = numbers.old
                newLine = numbers.new
            } else if isFileHeader(line) {
                continue
            } else if line.hasPrefix("+") {
                append(.added, old: nil, new: newLine, String(line.dropFirst()))
                newLine += 1
                added += 1
            } else if line.hasPrefix("-") {
                append(.removed, old: oldLine, new: nil, String(line.dropFirst()))
                oldLine += 1
                removed += 1
            } else if line.hasPrefix("\\") {
                continue
            } else if !line.isEmpty || !lines.isEmpty {
                append(.context, old: oldLine, new: newLine, line.hasPrefix(" ") ? String(line.dropFirst()) : line)
                oldLine += 1
                newLine += 1
            }
        }
        close()

        // A trailing newline in the patch reads as one empty context line.
        if var last = hunks.last, last.lines.last?.kind == .context, last.lines.last?.text.isEmpty == true {
            last = DiffHunk(id: last.id, header: last.header, lines: Array(last.lines.dropLast()))
            hunks[hunks.count - 1] = last
        }
        return DiffSummary(hunks: hunks, added: added, removed: removed)
    }

    /// Builds a diff from a tool call's before and after text, with a common
    /// prefix and suffix kept as context so a small edit reads as small.
    public static func between(old: String, new: String) -> DiffSummary {
        let before = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let after = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }

        var lines: [DiffHunk.Line] = []
        var id = 0
        func add(_ kind: DiffHunk.Kind, _ old: Int?, _ new: Int?, _ text: String) {
            lines.append(.init(id: id, kind: kind, oldNumber: old, newNumber: new, text: text))
            id += 1
        }
        for index in 0..<prefix { add(.context, index + 1, index + 1, before[index]) }
        for index in prefix..<(before.count - suffix) { add(.removed, index + 1, nil, before[index]) }
        for index in prefix..<(after.count - suffix) { add(.added, nil, index + 1, after[index]) }
        for offset in stride(from: suffix, to: 0, by: -1) {
            add(.context, before.count - offset + 1, after.count - offset + 1, before[before.count - offset])
        }
        return DiffSummary(
            hunks: [.init(id: 0, header: "", lines: lines)],
            added: after.count - suffix - prefix,
            removed: before.count - suffix - prefix
        )
    }

    /// Builds a diff from edits that name where text goes and carry only the new
    /// lines, as an anchored edit does. The text it replaces is not in the call, so
    /// the diff has added lines under a header that says what they replace, and the
    /// lines are numbered from `firstLine` when the edit names one.
    public static func inserting(_ edits: [(header: String, firstLine: Int?, lines: [String])]) -> DiffSummary {
        var hunks: [DiffHunk] = []
        var id = 0
        var added = 0
        for (index, edit) in edits.enumerated() {
            var lines: [DiffHunk.Line] = []
            for (offset, text) in edit.lines.enumerated() {
                lines.append(.init(id: id, kind: .added, oldNumber: nil, newNumber: edit.firstLine.map { $0 + offset }, text: text))
                id += 1
            }
            added += lines.count
            hunks.append(.init(id: index, header: edit.header, lines: lines))
        }
        return DiffSummary(hunks: hunks, added: added, removed: 0)
    }

    private static func isFileHeader(_ line: String) -> Bool {
        ["diff --git", "index ", "--- ", "+++ ", "new file", "deleted file", "similarity ", "rename ", "commit ", "Author:", "Date:"]
            .contains { line.hasPrefix($0) }
    }

    private static func hunkStart(_ header: String) -> (old: Int, new: Int) {
        // "@@ -12,3 +14,6 @@ context"
        let parts = header.split(separator: " ")
        guard parts.count >= 3 else { return (1, 1) }
        func first(_ part: Substring) -> Int {
            Int(part.dropFirst().split(separator: ",").first ?? "") ?? 1
        }
        return (first(parts[1]), first(parts[2]))
    }
}

/// Scores a query against a candidate for the command palette.
public enum Fuzzy {
    /// Returns nil when `query` is not a subsequence of `candidate`. A higher
    /// score means a better match: consecutive characters, word starts and an
    /// exact prefix all count, and a shorter candidate wins a tie.
    public static func score(query: String, candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        guard !needle.isEmpty else { return 0 }
        let original = Array(candidate)
        let haystack = Array(candidate.lowercased())
        guard original.count == haystack.count else {
            return candidate.lowercased().contains(query.lowercased()) ? 1 : nil
        }

        var score = 0
        var position = 0
        var previous = -2
        for character in needle {
            var found = -1
            var cursor = position
            while cursor < haystack.count {
                if haystack[cursor] == character {
                    found = cursor
                    break
                }
                cursor += 1
            }
            guard found >= 0 else { return nil }

            score += 1
            if found == previous + 1 { score += 8 }
            let atWordStart = found == 0 || !haystack[found - 1].isLetter
            if atWordStart { score += 12 }
            if found > 0, original[found].isUppercase, original[found - 1].isLowercase { score += 6 }
            previous = found
            position = found + 1
        }
        if candidate.lowercased().hasPrefix(query.lowercased()) { score += 30 }
        return score * 10 - min(haystack.count, 99) / 10
    }
}
