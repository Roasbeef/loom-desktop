import Foundation

/// One block of a model's reply.
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [ListItem])
    case quote(String)
    case code(language: String?, text: String, isClosed: Bool)
    case table(header: [String], rows: [[String]])
    case rule

    public struct ListItem: Sendable, Equatable {
        public let marker: String
        public let depth: Int
        public let text: String
    }
}

/// Parses the markdown models write into blocks a native view can lay out.
///
/// It is a line parser and not a full CommonMark implementation, chosen because
/// it must also read a reply that is still streaming. An unterminated fence is
/// code through to the end, and a half-written table reads as text until its
/// delimiter row arrives, so a reply never jumps between layouts more than once.
public enum Markdown {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var index = 0
        var paragraph: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                index += 1
            } else if let fence = fence(trimmed) {
                flush()
                index += 1
                var code: [String] = []
                var closed = false
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence.marker) {
                        closed = true
                        index += 1
                        break
                    }
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: fence.language, text: code.joined(separator: "\n"), isClosed: closed))
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                index += 1
            } else if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let body = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    quoted.append(body.hasPrefix(" ") ? String(body.dropFirst()) : String(body))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
            } else if listItem(line) != nil {
                flush()
                var items: [MarkdownBlock.ListItem] = []
                var ordered = false
                while index < lines.count, let item = listItem(lines[index]) {
                    if items.isEmpty { ordered = item.isOrdered }
                    items.append(item.item)
                    index += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
            } else if index + 1 < lines.count, trimmed.contains("|"), isTableDelimiter(lines[index + 1]) {
                flush()
                let header = cells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    rows.append(normalized(cells(row), count: header.count))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
            } else {
                paragraph.append(trimmed)
                index += 1
            }
        }
        flush()
        return blocks
    }

    /// Text with its markdown markers removed, for a one-line preview.
    public static func plainPreview(_ source: String) -> String {
        var output: [String] = []
        for block in parse(source) {
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text): output.append(text)
            case .list(_, let items): output += items.map(\.text)
            case .table(let header, _): output.append(header.joined(separator: " "))
            case .code, .rule: break
            }
        }
        return output.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func fence(_ line: String) -> (marker: String, language: String?)? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) {
            let language = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return (marker, language.isEmpty ? nil : language)
        }
        return nil
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, "-*_".contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (item: MarkdownBlock.ListItem, isOrdered: Bool)? {
        let indent = line.prefix { $0 == " " }.count
        let body = line.dropFirst(indent)
        let depth = indent / 2
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            return (.init(marker: "•", depth: depth, text: String(body.dropFirst(2))), false)
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 4 {
            let after = body.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return (.init(marker: "\(digits).", depth: depth, text: String(after.dropFirst(2))), true)
            }
        }
        return nil
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var body = Substring(row)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func normalized(_ row: [String], count: Int) -> [String] {
        if row.count >= count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }
}
