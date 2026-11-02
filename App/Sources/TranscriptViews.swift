import AppKit
import LoomKit
import Markup
import SwiftUI

/// A turn's work behind one line: `Worked 48s · 4 steps · 2 files`.
///
/// It opens by itself while the turn runs, so the step that is asking or failing is
/// visible as it happens, and closes to one line when the turn is done.
struct FoldView: View {
    let fold: Fold
    let tails: [String: String]
    @State private var userOpened: Bool?

    private var isOpen: Bool { userOpened ?? fold.isLive }

    private var status: ToolSummary.Status { ToolSummary.status(fold.rows) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { userOpened = !isOpen }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(fold.title)
                        .font(Theme.label)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                    if fold.changeText != nil {
                        ChangeCounts(added: fold.added, removed: fold.removed)
                            .accessibilityHidden(true)
                    }
                    if !isOpen {
                        Text(ToolSummary.describe(fold.rows.filter { if case .tool = $0.kind { return true }; return false }))
                            .font(Theme.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(fold.title)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(fold.rows) { row in
                        FoldRow(row: row, tail: row.callID.flatMap { tails[$0] })
                    }
                }
                .padding(.leading, 22)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini).frame(width: 14)
        case .done:
            Image(systemName: "checkmark.circle").foregroundStyle(.tertiary).frame(width: 14)
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.failure).frame(width: 14)
        }
    }
}

/// `+12 −3`, in the diff colours, which are the one place colour means a change.
struct ChangeCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 { Text("+\(added)").foregroundStyle(Theme.addedText) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Theme.removedText) }
        }
        .font(Theme.meta)
    }
}

/// One row inside a fold.
struct FoldRow: View {
    let row: TranscriptRow
    let tail: String?

    var body: some View {
        switch row.kind {
        case .tool:
            StepRow(row: row, tail: tail)
        case .thinking(let text):
            ReasoningRow(text: text, tookMs: row.tookMs)
        case .assistant(let text):
            // Prose the strand wrote between steps is narration, so it is drawn
            // quieter than the answer.
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        default:
            RowView(row: row)
        }
    }
}

/// The notes index the daemon attached to a run, closed to one line. Opening it shows
/// the text the model was given, which the person did not write.
struct MemoryRow: View {
    let lines: Int
    let text: String
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text(MemoryContext.summary(lines: lines)).font(Theme.label).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MemoryContext.summary(lines: lines))
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            if isOpen {
                OutputBlock(text: text, tint: .secondary)
            }
        }
    }
}

// MARK: Steps

/// One tool call: a verb, what it acted on, and what it changed.
struct StepRow: View {
    let row: TranscriptRow
    let tail: String?
    @State private var isOpen = false

    private var parts: (name: String, arguments: JSONValue, result: String?, isError: Bool)? {
        if case .tool(let name, let arguments, let result, let isError) = row.kind {
            return (name, arguments, result, isError)
        }
        return nil
    }

    var body: some View {
        if let parts {
            let words = StepWords.of(name: parts.name, arguments: parts.arguments, isRunning: parts.result == nil)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: icon(parts.name))
                            .font(.system(size: 11))
                            .foregroundStyle(parts.isError ? Theme.failure : .secondary)
                            .frame(width: 14)
                        Text(words.verb)
                            .font(Theme.label)
                            .foregroundStyle(parts.isError ? Theme.failure : .secondary)
                            .layoutPriority(1)
                        if !words.subject.isEmpty {
                            Text(words.subject)
                                .font(Theme.code)
                                .foregroundStyle(parts.isError ? Theme.failure : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if words.added != nil || words.removed != nil {
                            ChangeCounts(added: words.added ?? 0, removed: words.removed ?? 0)
                        }
                        if parts.result == nil {
                            if let started = row.at {
                                StepClock(startedAt: started)
                            }
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(parts.name)
                .accessibilityLabel(words.subject.isEmpty ? words.verb : "\(words.verb) \(words.subject)")
                .accessibilityValue(changeValue(words) + (isOpen ? "Expanded" : "Collapsed"))

                if parts.isError, parts.name != "code_mode" {
                    Text(StepWords.failure(name: parts.name, arguments: parts.arguments, result: parts.result))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.failure)
                        .textSelection(.enabled)
                }
                if parts.result == nil, let tail, !tail.isEmpty {
                    OutputBlock(text: tail, tint: .secondary)
                }
                if isOpen {
                    detail(parts)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ parts: (name: String, arguments: JSONValue, result: String?, isError: Bool)) -> some View {
        switch parts.name {
        case "fs_write":
            DiffView(summary: Diff.between(old: "", new: parts.arguments["content"]?.string ?? ""))
        case "fs_edit":
            if let hunks = parts.arguments["hunks"]?.array {
                OutputBlock(text: hunks.map(Self.hunkText).joined(separator: "\n"), tint: .secondary)
            } else {
                DiffView(summary: Diff.between(
                    old: parts.arguments["old"]?.string ?? parts.arguments["old_string"]?.string ?? "",
                    new: parts.arguments["new"]?.string ?? parts.arguments["new_string"]?.string ?? ""
                ))
            }
        case "bash":
            // The whole command, which the line shows only the first row of.
            if let command = parts.arguments["command"]?.string {
                OutputBlock(text: "$ " + command, tint: .secondary)
            }
        case "fs_read", "grep":
            EmptyView()
        case "code_mode":
            ProgramCardView(card: ProgramCard.read(
                arguments: parts.arguments, result: parts.result, isError: parts.isError, details: row.details
            ))
        default:
            if parts.arguments != .null {
                OutputBlock(text: parts.arguments.compactText, tint: .secondary)
            }
        }
        if parts.name != "code_mode", let result = parts.result, !result.isEmpty {
            OutputBlock(text: result, tint: parts.isError ? Theme.failure : .primary)
        }
        if !row.pictures.isEmpty {
            PictureStrip(pictures: row.pictures)
        }
    }

    /// The change counts, spoken ahead of the open state.
    private func changeValue(_ words: StepWords) -> String {
        var parts: [String] = []
        if let added = words.added, added > 0 { parts.append("\(added) added") }
        if let removed = words.removed, removed > 0 { parts.append("\(removed) removed") }
        return parts.isEmpty ? "" : parts.joined(separator: ", ") + ". "
    }

    /// One anchored hunk as the lines it removes and adds.
    private static func hunkText(_ hunk: JSONValue) -> String {
        let op = hunk["op"]?.string ?? "edit"
        let from = hunk["from"]?["line"]?.int ?? hunk["at"]?["line"]?.int
        let to = hunk["to"]?["line"]?.int
        let place = from.map { start in to.map { "lines \(start)–\($0)" } ?? "after line \(start)" } ?? "at the start"
        let lines = (hunk["lines"]?.array ?? []).compactMap(\.string).map { "+ " + $0 }
        return (["\(op) \(place)"] + lines).joined(separator: "\n")
    }

    private func icon(_ name: String) -> String {
        switch name {
        case "bash": return "terminal"
        case "fs_read": return "doc.text"
        case "fs_write", "fs_edit": return "pencil"
        case "grep", "history_search": return "magnifyingglass"
        case "code_mode": return "curlybraces"
        case _ where name.hasPrefix("agent_"): return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// The images a message or a tool result carried, each with a line giving its type,
/// its size in pixels and its weight. A picture whose bytes are not the type the
/// record declared is not drawn, and the line says so.
struct PictureStrip: View {
    let pictures: [ImageBlock]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(pictures) { picture in
                VStack(alignment: .leading, spacing: 4) {
                    if picture.isDrawable, let image = NSImage(data: picture.data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 160, alignment: .leading)
                            .clipShape(.rect(cornerRadius: Theme.radiusInner))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusInner).strokeBorder(Theme.hairline, lineWidth: 0.5))
                            .accessibilityHidden(true)
                    }
                    Text(picture.caption)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Image, \(picture.caption)")
            }
        }
    }
}

/// How long a step has run, from the time its call was recorded.
private struct StepClock: View {
    let startedAt: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let started = Date(timeIntervalSince1970: Double(startedAt) / 1000)
            Text(StepWords.duration(ms: Int(max(0, context.date.timeIntervalSince(started)) * 1000)))
                .font(Theme.meta)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

/// A `code_mode` program, laid out from what its result recorded.
struct ProgramCardView: View {
    let card: ProgramCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(card.outcome).font(Theme.label)
                Text(card.statusWord).font(Theme.meta).foregroundStyle(card.state == .completed || card.state == .running ? Color.secondary : Theme.failure)
                Spacer()
                if let count = card.countWords { Text(count).font(Theme.meta).foregroundStyle(.secondary) }
                if let elapsed = card.elapsedMs { Text(StepWords.duration(ms: elapsed)).font(Theme.meta).foregroundStyle(.secondary) }
            }
            if !card.calls.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(card.calls) { call in
                        HStack(spacing: 8) {
                            Text(call.count > 1 ? "\(call.capability) ×\(call.count)" : call.capability)
                                .font(Theme.meta)
                                .foregroundStyle(call.failed ? Theme.failure : .secondary)
                                .frame(width: 130, alignment: .leading)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(call.failed ? Theme.failure : Color.secondary.opacity(0.5))
                                    .frame(width: max(2, proxy.size.width * CGFloat(call.width) / 100), height: 5)
                                    .offset(x: proxy.size.width * CGFloat(call.offset) / 100)
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }
            if !card.program.isEmpty {
                Text("Program · \(card.lines) lines").font(Theme.caption).foregroundStyle(.secondary)
                OutputBlock(text: card.program, tint: .primary)
            }
            if let failure = card.failure, !failure.isEmpty {
                OutputBlock(text: failure, tint: Theme.failure)
            } else if let value = card.value, !value.isEmpty {
                Text("Result").font(Theme.caption).foregroundStyle(.secondary)
                OutputBlock(text: value, tint: .primary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Program: \(card.outcome)")
    }
}

struct OutputBlock: View {
    let text: String
    var tint: Color

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            HStack(spacing: 0) {
                Text(text)
                    .font(Theme.code)
                    .foregroundStyle(tint)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
        .surface(radius: Theme.radiusInner)
    }
}

// MARK: Reasoning

/// Settled reasoning: a preview, how long it is, how long it took, and the body.
struct ReasoningRow: View {
    let text: String
    let tookMs: Int?
    @State private var isOpen = false

    private var preview: String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }

    private var figures: String {
        var parts: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
        parts.append("\(lines) line\(lines == 1 ? "" : "s")")
        if let tookMs, tookMs >= 1000 { parts.append(StepWords.duration(ms: tookMs)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain").foregroundStyle(.tertiary).frame(width: 14)
                    Text("Thought").font(Theme.label).foregroundStyle(.secondary)
                    if !isOpen {
                        Text(preview).font(Theme.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(figures).font(Theme.meta).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thought, \(figures)")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: Other agents

/// An approval that was answered, where it was answered.
struct DecisionLine: View {
    let tool: String
    let summary: String
    let outcome: String

    private var word: String {
        switch outcome {
        case "rejected": return "Denied"
        case "consumed": return "Allowed once"
        default: return "Allowed"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: outcome == "rejected" ? "hand.raised.slash" : "hand.thumbsup")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(word).font(Theme.label).foregroundStyle(.secondary)
            Text(summary).font(Theme.code).lineLimit(1).truncationMode(.middle)
            if !tool.isEmpty { Text(tool).font(Theme.meta).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(word): \(summary)")
    }
}

struct SpawnedLine: View {
    let child: String
    let purpose: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.plus").foregroundStyle(.secondary).frame(width: 14)
            Text("Started").font(Theme.label).foregroundStyle(.secondary)
            Text(StrandName.display(child)).font(Theme.code)
            if !purpose.isEmpty {
                Text(purpose).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Started agent \(StrandName.display(child)): \(purpose)")
    }
}

/// A subagent's report, which opens to the text it returned.
struct AgentReportLine: View {
    let child: String
    let outcome: String
    let report: String
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.left").foregroundStyle(.secondary).frame(width: 14)
                    Text(StrandName.display(child)).font(Theme.code)
                    Text(outcome).font(Theme.label).foregroundStyle(outcome == "settled" || outcome == "completed" ? Color.secondary : Theme.failure)
                    if !isOpen, !report.isEmpty {
                        Text(report.split(separator: "\n").first.map(String.init) ?? "")
                            .font(Theme.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Report from \(StrandName.display(child)), \(outcome)")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                MarkdownView(source: report).padding(.leading, 22)
            }
        }
    }
}

// MARK: The live end of the transcript

/// What the agent is doing right now. It reads the stream alone, so tokens arriving
/// redraw this view and not the transcript above it. Its pieces are direct children
/// of the transcript's lazy stack.
struct LiveTail: View {
    let controller: SessionController

    var body: some View {
        let stream = controller.stream
        if let stream, !stream.thinking.isEmpty {
            LiveReasoning(thinking: stream.thinking, isSettling: !stream.text.isEmpty)
        }
        if let stream {
            if !stream.text.isEmpty {
                MarkdownView(source: stream.text, isStreaming: true).blocks
            }
            ForEach(stream.tools) { tool in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).frame(width: 14)
                    Text(tool.name).font(Theme.code).foregroundStyle(.secondary)
                }
            }
        }
        if let observed = controller.busySince {
            let since = controller.turnStartedAt ?? observed
            WorkingLine(since: since, isThinking: (stream?.thinking.isEmpty ?? true) && (stream?.text.isEmpty ?? true))
        }
    }
}

/// Reasoning as it streams. It shows the newest line and opens to everything so
/// far, and it folds to a quiet row once the answer begins.
private struct LiveReasoning: View {
    let thinking: String
    let isSettling: Bool
    @State private var isOpen = false

    private var newest: String {
        let line = thinking.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? thinking
        return line.count > 120 ? "…" + String(line.suffix(120)) : line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 7) {
                    if isSettling {
                        Image(systemName: "brain").foregroundStyle(.tertiary).frame(width: 14)
                    } else {
                        ProgressView().controlSize(.mini).frame(width: 14).accessibilityHidden(true)
                    }
                    Text(isSettling ? "Thought" : "Thinking").font(Theme.label).foregroundStyle(.secondary)
                    if !isOpen {
                        Text(newest).font(Theme.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSettling ? "Thought" : "Thinking")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                Text(thinking)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The elapsed time of a run, measured from the input the daemon recorded for it.
/// Its timeline ticks once a second and redraws only this line.
struct WorkingLine: View {
    let since: Date
    let isThinking: Bool

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            HStack(spacing: 8) {
                StatusDot(liveness: .working)
                Text(isThinking ? "Thinking" : "Working")
                Text(Duration.seconds(max(0, context.date.timeIntervalSince(since))).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .font(Theme.caption)
            .foregroundStyle(.secondary)
        }
    }
}
