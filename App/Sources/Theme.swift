import MissionKit
import SwiftUI

/// The small set of visual rules the whole app shares.
///
/// Surfaces are a quiet tint with a hairline border, with no accent bars and no
/// shadows. Colour is reserved for state, so colour on screen always means that
/// something is running, waiting or wrong.
enum Theme {
    static let hairline = Color.primary.opacity(0.1)
    static let tint = Color.primary.opacity(0.035)
    static let radius: CGFloat = 8
    static let meta = Font.system(size: 11, design: .monospaced)
    static let attention = Color.orange
    static let working = Color.green
    static let failure = Color.red
}

extension View {
    /// The one surface style: a tinted fill and a hairline border.
    func surface(fill: Color = Theme.tint, radius: CGFloat = Theme.radius) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline))
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

/// A status dot, the same glyph everywhere state is drawn.
struct StatusDot: View {
    let liveness: AgentCard.Liveness

    var body: some View {
        Circle()
            .fill(liveness.color)
            .frame(width: 7, height: 7)
            .accessibilityLabel(liveness.label)
    }
}

/// Substrate's liveness trace: a small heartbeat line, readable across a whole
/// board without a status word. Only a working agent animates, so motion on the
/// board always marks real activity.
struct HeartbeatTrace: View {
    let liveness: AgentCard.Liveness

    var body: some View {
        Group {
            if liveness == .working {
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    trace(phase: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                trace(phase: 0)
            }
        }
        .frame(width: 64, height: 14)
        .accessibilityHidden(true)
    }

    private func trace(phase: Double) -> some View {
        Canvas { context, size in
            var path = Path()
            let mid = size.height / 2
            path.move(to: CGPoint(x: 0, y: mid))
            let period = size.width / 2
            for x in stride(from: 0, through: size.width, by: 1) {
                let position = (x + phase * 18).truncatingRemainder(dividingBy: period) / period
                path.addLine(to: CGPoint(x: x, y: mid - offset(position) * mid * 0.85))
            }
            let style = liveness == .off
                ? StrokeStyle(lineWidth: 1, dash: [2, 3])
                : StrokeStyle(lineWidth: 1.2, lineJoin: .round)
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

/// Renders model text: fenced code as blocks, the rest as inline markdown.
struct MarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.segments(source).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    Text(Self.attributed(text))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .surface()
                }
            }
        }
    }

    enum Segment { case prose(String), code(String) }

    /// Splits on code fences. An unterminated fence, the normal state of a
    /// reply still streaming, reads as code through to the end.
    static func segments(_ source: String) -> [Segment] {
        var segments: [Segment] = []
        var lines: [Substring] = []
        var inCode = false
        func flush() {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(inCode ? .code(text) : .prose(text)) }
            lines = []
        }
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                lines.append(line)
            }
        }
        flush()
        return segments
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
