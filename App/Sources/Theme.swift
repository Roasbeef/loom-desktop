import AppKit
import Markup
import MissionKit
import SwiftUI

/// The visual rules the whole app shares.
///
/// The window chrome belongs to the system: the sidebar, toolbar, sheets and menus
/// get Liquid Glass from being left unpainted. Glass here is reserved for what
/// floats above content, such as the composer and the palette. Content surfaces
/// are a quiet tint with a hairline border, with no accent bars and no shadows.
///
/// Colour follows the plant-display palette the web redesign measured (Loom's
/// `docs/design-notes/web-ui-redesign.md`, section 9): normal is grey, amber means a
/// decision is waiting, red means failed or down, and green appears only in diffs.
/// A loud screen therefore always means something needs a person.
enum Theme {
    static let hairline = Color(nsColor: .separatorColor)
    static let tint = Color.primary.opacity(0.04)
    static let tintStrong = Color.primary.opacity(0.07)
    /// Three radii: inner blocks, content surfaces, and what floats over content.
    static let radiusInner: CGFloat = 6
    static let radius: CGFloat = 10
    static let radiusFloating: CGFloat = 16
    static let contentWidth: CGFloat = 740

    static let attention = adaptive(light: 0x985000, dark: 0xF5A742)
    static let working = adaptive(light: 0x50565A, dark: 0xBCC2C6)
    static let failure = adaptive(light: 0x800C10, dark: 0xFF7A70)

    /// The fill of the one button that grants authority. Glass tinting needs a
    /// resolved colour, so this is fixed rather than adaptive.
    static let grant = Color(red: 0.76, green: 0.44, blue: 0.04)

    /// Monospaced type marks identifiers only: paths, hosts, commands, model ids.
    /// Words a person reads as prose stay in the system face.
    static let meta = Font.system(size: 11).monospaced()
    static let code = Font.system(size: 12).monospaced()
    static let caption = Font.system(size: 11)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 12, weight: .medium)

    /// A colour that follows the appearance of whatever draws it.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }

    static func color(_ kind: SyntaxKind) -> Color {
        switch kind {
        case .plain: return .primary
        case .keyword: return adaptive(light: 0x9B2393, dark: 0xFF7AB2)
        case .string: return adaptive(light: 0xB3261E, dark: 0xFF8170)
        case .comment: return adaptive(light: 0x5D6C79, dark: 0x7F8C98)
        case .number: return adaptive(light: 0x272AD8, dark: 0xD9C97C)
        case .type: return adaptive(light: 0x0B4F79, dark: 0x6BDFFF)
        case .function: return adaptive(light: 0x326D74, dark: 0x67B7A4)
        }
    }

    static let addedFill = adaptive(light: 0xE6F7E2, dark: 0x0E2715)
    static let removedFill = adaptive(light: 0xF6C6C2, dark: 0x642120)
    static let addedText = adaptive(light: 0x125A2B, dark: 0xADEB9F)
    static let removedText = adaptive(light: 0x7C0B0E, dark: 0xFFB6AF)
}

extension NSColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    /// The content surface: a tinted fill and a hairline border.
    func surface(fill: Color = Theme.tint, radius: CGFloat = Theme.radius) -> some View {
        background(fill, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

extension AgentCard.Liveness {
    var color: Color {
        switch self {
        case .needsYou: return Theme.attention
        case .working: return Theme.working
        case .idle: return .secondary
        case .unknown: return Color.secondary.opacity(0.6)
        case .off: return Color.secondary.opacity(0.35)
        }
    }

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .idle: return "Idle"
        case .unknown: return "Not answering"
        case .off: return "Saved"
        }
    }
}

/// The state glyph, the same everywhere. Its shape differs as well as its colour,
/// so state survives colour blindness: a filled dot is active, a hollow ring is
/// at rest, and needing you is a diamond.
struct StatusDot: View {
    let liveness: AgentCard.Liveness
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch liveness {
            case .needsYou:
                Rectangle()
                    .fill(liveness.color)
                    .frame(width: 6.5, height: 6.5)
                    .rotationEffect(.degrees(45))
            case .working:
                // Static on purpose. A continuously animating dot redraws at the
                // display's rate for every working row, which costs real CPU for
                // what its shape already says. The heartbeat carries the motion.
                Circle()
                    .fill(liveness.color)
                    .frame(width: 7, height: 7)
            default:
                Circle()
                    .strokeBorder(liveness.color, lineWidth: 1.2)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(liveness.label)
    }
}

/// A liveness line, readable across a whole board without a status word. Only a
/// working agent animates, so motion on the board always marks real activity.
struct HeartbeatTrace: View {
    let liveness: AgentCard.Liveness
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if liveness == .working, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 12)) { context in
                    trace(phase: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                trace(phase: 0)
            }
        }
        .frame(width: 56, height: 14)
        .accessibilityHidden(true)
    }

    private func trace(phase: Double) -> some View {
        Canvas { context, size in
            var path = Path()
            let mid = size.height / 2
            path.move(to: CGPoint(x: 0, y: mid))
            let period = size.width
            for x in stride(from: 0, through: size.width, by: 1) {
                let position = (x + phase * 22).truncatingRemainder(dividingBy: period) / period
                path.addLine(to: CGPoint(x: x, y: mid - offset(position) * mid * 0.85))
            }
            let style = liveness == .off
                ? StrokeStyle(lineWidth: 1, dash: [2, 3])
                : StrokeStyle(lineWidth: 1.1, lineJoin: .round)
            context.stroke(path, with: .color(liveness.color), style: style)
        }
    }

    private func offset(_ position: Double) -> Double {
        guard liveness == .working || liveness == .needsYou else { return 0 }
        switch position {
        case 0.40..<0.46: return (position - 0.40) / 0.06
        case 0.46..<0.54: return 1 - (position - 0.46) / 0.08 * 1.7
        case 0.54..<0.60: return -0.7 + (position - 0.54) / 0.06 * 0.7
        default: return 0
        }
    }
}

/// A small copy control that confirms itself.
struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "square.on.square")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 11))
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Renders model markdown with native layout.
///
/// Parsing runs in the initializer's body on each change of `source`. It is linear
/// in the reply and the controller paces streamed updates, so this stays well
/// under a frame for any reply a person would read.
struct MarkdownView: View {
    let source: String
    var isStreaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            blocks
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The blocks with no stack of their own. A reply still streaming can grow
    /// without bound, so the live tail places these directly in the transcript's
    /// lazy stack, and only the ones on screen pay for each token. A second lazy
    /// stack nested inside would leave the bottom-anchored scroll view with no
    /// height to measure, and it draws nothing.
    @ViewBuilder
    var blocks: some View {
        ForEach(Array(Markdown.parse(source).enumerated()), id: \.offset) { _, block in
            view(for: block)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .system(size: 14, weight: .semibold))
                .padding(.top, level <= 2 ? 8 : 4)
                .accessibilityAddTraits(.isHeader)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(Theme.body)
                .lineSpacing(3.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .list(_, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(item.marker == "•" ? Theme.body : Theme.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 12, alignment: .trailing)
                        Text(Self.inline(item.text))
                            .font(Theme.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let text):
            Text(Self.inline(text))
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(radius: Theme.radiusInner)
        case .alert(let kind, let text):
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title)
                    .font(Theme.label)
                    .accessibilityAddTraits(.isHeader)
                Text(Self.inline(text))
                    .font(Theme.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(radius: Theme.radiusInner)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(kind.title): \(text)")
        case .footnote(let label, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("[\(label)]").font(Theme.caption).foregroundStyle(.secondary)
                Text(Self.inline(text)).font(Theme.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .code(let language, let text, let closed):
            // A diagram is drawn once its fence closes; while it streams it is code.
            if language?.lowercased() == "mermaid", closed {
                DiagramBlock(source: text)
            } else {
                CodeBlockView(code: text, language: language, isStreaming: isStreaming && !closed)
            }
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    /// Remembers parsed inline text. While a reply streams, every finished paragraph
    /// is asked for again on each token, and Foundation's markdown parser is by far
    /// the most expensive step on that path.
    @MainActor private static var inlineCache: [String: AttributedString] = [:]

    @MainActor
    static func inline(_ text: String) -> AttributedString {
        if let hit = inlineCache[text] { return hit }
        let result = parseInline(text)
        if inlineCache.count > 4000 { inlineCache.removeAll() }
        inlineCache[text] = result
        return result
    }

    private static func parseInline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var result = try? AttributedString(markdown: Markdown.footnoteReferences(in: text), options: options) else {
            return AttributedString(text)
        }

        // A link is followed only when its destination passes the same rule the web
        // page applies. A refused one stays as its label, and says it was not followed.
        for run in result.runs.reversed() {
            guard let link = run.link, LinkRule.destination(link.absoluteString) == nil else { continue }
            result[run.range].link = nil
            result.insert(AttributedString(" (link not followed)"), at: run.range.upperBound)
        }

        // Inline code gets a monospaced face and a soft fill, not a colour.
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(size: 12).monospaced()
            result[run.range].backgroundColor = Color.primary.opacity(0.08)
        }
        return result
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownView.inline(cell))
                            .font(Theme.label)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownView.inline(cell))
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .surface(fill: .clear, radius: Theme.radiusInner)
            .clipShape(.rect(cornerRadius: Theme.radiusInner))
        }
    }
}

/// A code block: a quiet header naming the language, a copy control on hover, and
/// colour by lexical class.
struct CodeBlockView: View {
    let code: String
    let language: String?
    var isStreaming = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "text").font(Theme.meta).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: code, label: "Copy code")
                    .opacity(isHovering ? 1 : 0.35)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Theme.tint)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HighlightedCode(code: code, language: language, isStreaming: isStreaming)
                    .padding(12)
            }
        }
        .surface(fill: Theme.tint.opacity(0.6))
        .clipShape(.rect(cornerRadius: Theme.radius))
        .onHover { isHovering = $0 }
    }
}

struct HighlightedCode: View {
    let code: String
    let language: String?
    var isStreaming = false

    var body: some View {
        Text(HighlightCache.attributed(code, language: language, isStreaming: isStreaming))
            .font(Theme.code)
            .lineSpacing(2.5)
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
    }
}

/// Remembers highlighted code, because a view body can run many times for text
/// that has not changed. A block still streaming is not stored, since each token
/// makes a new key that would never be read again.
@MainActor
enum HighlightCache {
    private static var cache: [Int: AttributedString] = [:]

    static func attributed(_ code: String, language: String?, isStreaming: Bool) -> AttributedString {
        var hasher = Hasher()
        hasher.combine(code)
        hasher.combine(language)
        let key = hasher.finalize()
        if let hit = cache[key] { return hit }

        var result = AttributedString()
        for token in Syntax.highlight(code, language: language) {
            var run = AttributedString(token.text)
            run.foregroundColor = Theme.color(token.kind)
            result.append(run)
        }
        if !isStreaming {
            if cache.count > 2000 { cache.removeAll() }
            cache[key] = result
        }
        return result
    }
}

/// A numbered patch with full red and green lines.
struct DiffView: View {
    let summary: DiffSummary
    var language: String?

    // Lines fill the pane even when shorter than it, so colour runs edge to edge.
    @State private var paneWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(summary.hunks) { hunk in
                    if !hunk.header.isEmpty {
                        Text(hunk.header)
                            .font(Theme.meta)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.tint)
                    }
                    ForEach(hunk.lines) { line in
                        row(line)
                    }
                }
            }
            .frame(minWidth: paneWidth, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { paneWidth = $0 }
        .surface(fill: .clear, radius: Theme.radiusInner)
        .clipShape(.rect(cornerRadius: Theme.radiusInner))
    }

    /// A new file has no old side, so its gutter does not reserve a column for one.
    private var hasOldSide: Bool { summary.removed > 0 || summary.hunks.contains { $0.lines.contains { $0.kind == .context } } }

    private func row(_ line: DiffHunk.Line) -> some View {
        HStack(spacing: 0) {
            if hasOldSide {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: 34, alignment: .trailing)
            }
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
            Text(marker(line.kind))
                .frame(width: 18)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(textColor(line.kind))
                .padding(.trailing, 12)
                .textSelection(.enabled)
        }
        .font(Theme.code)
        .foregroundStyle(.secondary)
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill(line.kind))
    }

    private func marker(_ kind: DiffHunk.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .context: return ""
        }
    }

    private func fill(_ kind: DiffHunk.Kind) -> Color {
        switch kind {
        case .added: return Theme.addedFill
        case .removed: return Theme.removedFill
        case .context: return .clear
        }
    }

    private func textColor(_ kind: DiffHunk.Kind) -> Color {
        switch kind {
        case .added: return Theme.addedText
        case .removed: return Theme.removedText
        case .context: return .primary
        }
    }
}
