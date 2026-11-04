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
    var summaries: [String: String] = [:]
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
                        FoldRow(row: row, tail: row.callID.flatMap { tails[$0] }, summary: summaries[row.id])
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
    var summary: String?

    var body: some View {
        switch row.kind {
        case .tool:
            StepRow(row: row, tail: tail)
        case .thinking(let text):
            ReasoningRow(text: text, tookMs: row.tookMs, summary: summary)
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

/// A message another session's strand sent here. The head names the sender, and the
/// word under it is the daemon's, not the sender's: the origin was checked and the
/// message stored, which is all the daemon knows. Reply drafts an answer in the
/// composer, and Open goes to the sender's session when this app holds it.
struct PeerCard: View {
    @Environment(AppModel.self) private var model
    let session: String
    let strand: String
    let text: String

    private var sender: SessionRecord? { model.sessions.first { $0.id == session } }
    private var name: String { sender?.title ?? String(session.prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text("Peer · \(name) · \(strand)").font(Theme.label).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Origin checked by the daemon").font(Theme.meta).foregroundStyle(.tertiary)
            }
            Text(text).font(Theme.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Reply to Peer") {
                    model.currentSession?.composer.draft = "Reply to \(name) (session \(session), strand \(strand)): "
                }
                .accessibilityLabel("Reply to Peer")
                if sender != nil {
                    Button("Open \(name)") { model.destination = .session(session) }
                        .accessibilityLabel("Open \(name)")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Theme.radiusInner)
        .accessibilityElement(children: .contain)
    }
}

/// A message another strand of this session sent through the Agency. There is no peer
/// link behind it, so it has no receipt and no Reply. A spawn brief's result contract is
/// the harness's instruction, so it follows the sender's words as a second block.
struct SiblingCard: View {
    let strand: String
    let text: String
    let trailer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From strand \(StrandName.display(strand))").font(Theme.label).foregroundStyle(.secondary)
            Text(text).font(Theme.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let trailer {
                Text(trailer).font(Theme.caption).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Theme.radiusInner)
    }
}

/// Advisor traffic: advice and nudges the primary received, a goal continuation, and the
/// feed the advisor reads. The label is a fixed word. The body is the advisor's, drawn as
/// plain text, and a feed stays closed because it is context and not a message to anyone.
struct AdvisorLine: View {
    let frame: AdvisorFrame
    let text: String
    @State private var isOpen = false

    private var isClosed: Bool { frame == .feed || frame == .continuation }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isClosed {
                Button {
                    withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Text(frame.label).font(Theme.label).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(frame.label)
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                if isOpen { OutputBlock(text: text, tint: .secondary) }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text(frame.label).font(Theme.label).foregroundStyle(.secondary)
                }
                Text(text).font(Theme.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Theme.radiusInner)
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

            // A finished program is titled with what it did, which its result
            // records, rather than its first line of source.
            let program = parts.name == "code_mode" && parts.result != nil
                ? ProgramCard.read(arguments: parts.arguments, result: parts.result, isError: parts.isError, details: row.details)
                : nil
            let verb = program?.outcome ?? words.verb
            let subject = program == nil ? words.subject : ""
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: icon(parts.name))
                            .font(.system(size: 11))
                            .foregroundStyle(parts.isError ? Theme.failure : .secondary)
                            .frame(width: 14)
                        Text(verb)
                            .font(Theme.label)
                            .foregroundStyle(parts.isError ? Theme.failure : .secondary)
                            .layoutPriority(1)
                        if !subject.isEmpty {
                            Text(subject)
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

                        // The same disclosure mark as a fold and a thought, so a step reads
                        // as something that opens and, once open, as something to close.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(parts.name)
                .accessibilityLabel(subject.isEmpty ? verb : "\(verb) \(subject)")
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
                    // Indented to the title, past the icon, so the program and its
                    // result read as belonging to this step and not as the next row.
                    VStack(alignment: .leading, spacing: 6) {
                        detail(parts)
                    }
                    .padding(.leading, 21)
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
            // The whole command, which the line shows only the first row of. A
            // short one-line command is already all there in the title.
            if let command = parts.arguments["command"]?.string, command.contains("\n") || command.count > 70 {
                OutputBlock(text: "$ " + command, tint: .secondary, language: "sh")
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
    @State private var expanded: ImageBlock?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(pictures) { picture in
                VStack(alignment: .leading, spacing: 4) {
                    if picture.isDrawable, let image = NSImage(data: picture.data) {
                        Button { expanded = picture } label: {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 160, alignment: .leading)
                                .clipShape(.rect(cornerRadius: Theme.radiusInner))
                                .overlay(RoundedRectangle(cornerRadius: Theme.radiusInner).strokeBorder(Theme.hairline, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Expand")
                        .accessibilityLabel("Expand image, \(picture.caption)")
                    }
                    Text(picture.caption)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Image, \(picture.caption)")
                }
                .accessibilityElement(children: .contain)
            }
        }
        .sheet(item: $expanded) { ExpandedPicture(picture: $0) }
    }
}

/// One picture at the size it was sent, or scaled down to fit the screen.
/// Escape or Done closes it.
private struct ExpandedPicture: View {
    let picture: ImageBlock
    @Environment(\.dismiss) private var dismiss

    /// The picture's own size, capped so the sheet stays inside a laptop screen.
    private var size: CGSize {
        let pixels = picture.pixelSize.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 800, height: 600)
        let scale = min(1, 1200 / max(pixels.width, 1), 760 / max(pixels.height, 1))
        return CGSize(width: max(320, pixels.width * scale), height: max(200, pixels.height * scale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = NSImage(data: picture.data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .accessibilityLabel("Image, \(picture.caption)")
            }
            HStack {
                Text(picture.caption).font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
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

    /// The program's source, closed until asked for: the result is what a reader
    /// opened the step for.
    @State private var showsProgram = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The step's own title already says what the program did, so the card
            // leads with the figures, and a status word only when it is not plain
            // success.
            HStack(spacing: 8) {
                if card.state != .completed {
                    Text(card.statusWord).font(Theme.meta).foregroundStyle(card.state == .running ? Color.secondary : Theme.failure)
                }
                if card.calls.count == 1, let call = card.calls.first {
                    Text(call.count > 1 ? "\(call.capability) ×\(call.count)" : call.capability)
                        .font(Theme.meta)
                        .foregroundStyle(call.failed ? Theme.failure : .secondary)
                }
                Spacer()
                if let count = card.countWords { Text(count).font(Theme.meta).foregroundStyle(.secondary) }
                if let elapsed = card.elapsedMs { Text(StepWords.duration(ms: elapsed)).font(Theme.meta).foregroundStyle(.secondary) }
            }

            // A timeline says something only once there are calls to compare.
            if card.calls.count > 1 {
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
            if let failure = card.failure, !failure.isEmpty {
                OutputBlock(text: failure, tint: Theme.failure)
            } else if let value = card.value, !value.isEmpty {
                Text("Result").font(Theme.caption).foregroundStyle(.secondary)
                OutputBlock(text: value, tint: .primary)
            }
            if !card.program.isEmpty {
                // A running program has no result yet, so its source is the content.
                if card.state == .running {
                    Text("Program · \(card.lines) lines").font(Theme.caption).foregroundStyle(.secondary)
                    OutputBlock(text: card.program, tint: .primary, language: "gleam")
                } else {
                    DisclosureGroup("Program · \(card.lines) lines", isExpanded: $showsProgram) {
                        OutputBlock(text: card.program, tint: .primary, language: "gleam")
                    }
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Program: \(card.outcome)")
    }
}

struct OutputBlock: View {
    let text: String
    var tint: Color
    /// The language to colour the text as. Output with none is drawn in the tint alone.
    var language: String?

    private var styled: Text {
        guard let language else { return Text(text) }
        return Text(HighlightCache.attributed(text, language: language, isStreaming: false))
    }

    /// The block's own width. A scroll view that scrolls both ways gives a spacer
    /// no width, so short output was centred; the content is made at least this
    /// wide and left-aligned instead, and longer lines still scroll sideways.
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            styled
                .font(Theme.code)
                .foregroundStyle(tint)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize()
                .padding(10)
                .frame(minWidth: width, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
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
    /// The summarizer's label for a long block. It is drawn as the summarizer's, never as the agent's.
    let summary: String?
    @State private var isOpen = false

    /// The summary's section titles when it has them, or its first line otherwise.
    private var preview: AttributedString {
        let titles = Markdown.sectionTitles(in: text)
        if !titles.isEmpty { return AttributedString(titles.joined(separator: " · ")) }
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return MarkdownView.inline(line.count > 90 ? String(line.prefix(90)) + "…" : line)
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
                    if !isOpen, summary == nil {
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
            .accessibilityValue((summary.map { "Summarized: \($0). " } ?? "") + (isOpen ? "Expanded" : "Collapsed"))

            // A long block's label gets a line of its own, open or closed, so a reader
            // skimming the turn reads the summary rather than a cut fragment of it. The
            // leading word says it is the summarizer's, not the agent's.
            if let summary {
                (Text("Summary  ").font(Theme.meta).foregroundStyle(.tertiary)
                    + Text(MarkdownView.inline(summary)).font(Theme.caption).foregroundStyle(.secondary))
                    .lineLimit(isOpen ? nil : 3)
                    .textSelection(.enabled)
                    .padding(.leading, 21)
                    .accessibilityHidden(true)
            }

            if isOpen {
                MarkdownView(source: text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

    /// The section the summary is in now when it has titles, or its newest line.
    private var newest: AttributedString {
        if let title = Markdown.sectionTitles(in: thinking).last { return AttributedString(title) }
        let line = thinking.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? thinking
        return MarkdownView.inline(line.count > 120 ? "…" + String(line.suffix(120)) : line)
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
                MarkdownView(source: thinking, isStreaming: true)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
