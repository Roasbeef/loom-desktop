import LoomKit
import Markup
import MissionKit
import SwiftUI

/// One session: the transcript, the composer floating over it, and an inspector.
struct SessionScreen: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    private var record: SessionRecord? {
        model.sessions.first { $0.id == sessionID }
    }

    private var daemon: DaemonConnection? {
        model.daemon(holding: sessionID)
    }

    var body: some View {
        Group {
            if let record, record.state.isResident, let controller = model.controller(for: sessionID) {
                LiveSession(record: record, controller: controller, placement: model.placement(of: record))
            } else if let record {
                NotRunning(record: record)
            } else {
                ContentUnavailableView("Session not found", systemImage: "questionmark.circle")
            }
        }
        .task(id: record?.state.isResident) {
            if record?.state.isResident == true {
                daemon?.attach(sessionID)
            }
        }
    }
}

/// A saved session. Resuming claims a daemon slot, so it waits to be asked.
private struct NotRunning: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord
    @State private var error: String?
    @State private var isOpening = false

    var body: some View {
        ContentUnavailableView {
            Label(record.title, systemImage: "moon.zzz")
        } description: {
            VStack(spacing: 6) {
                Text(record.workspace).font(Theme.meta)
                switch record.state {
                case .reserved(let failure):
                    Text(failure ?? "This session never finished starting.")
                        .foregroundStyle(Theme.failure)
                case .recoveryBlocked:
                    Text("Recovery is blocked, so this session cannot open.")
                        .foregroundStyle(Theme.failure)
                default:
                    Text("The conversation is saved. Resuming uses one of the daemon's session slots.")
                }
                if let error {
                    Text(error).foregroundStyle(Theme.failure)
                }
            }
        } actions: {
            if canResume {
                Button(isOpening ? "Resuming…" : "Resume Session") {
                    isOpening = true
                    Task {
                        defer { isOpening = false }
                        do {
                            try await model.daemon(holding: record.id)?.resume(record.id)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isOpening)
            }
        }
        .navigationTitle(record.title)
    }

    private var canResume: Bool {
        switch record.state {
        case .reserved, .recoveryBlocked: return false
        default: return true
        }
    }
}

private struct LiveSession: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord
    let controller: SessionController
    let placement: Placement?
    @State private var query = ""

    private var subtitle: String {
        var parts: [String] = []
        if let placement { parts.append(placement.label) }
        parts.append([record.workspaceName, controller.branch].compactMap { $0 }.joined(separator: " · "))
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var controller = controller
        TranscriptView(controller: controller, query: query)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                ComposerStack(controller: controller)
            }
            .navigationTitle(record.title)
            .navigationSubtitle(subtitle)
            .onChange(of: model.activity[record.id]?.lastMessage, initial: true) {
                model.markSeen(record.id)
            }
            .searchable(text: $query, isPresented: $controller.isSearching, placement: .toolbar, prompt: "Find in transcript")
            .inspector(isPresented: $model.showsInspector) {
                SessionInspector(record: record, controller: controller, placement: placement)
                    .inspectorColumnWidth(min: 320, ideal: 460, max: 800)
            }
            .sheet(isPresented: Binding(
                get: { controller.peek != nil },
                set: { if !$0 { controller.endPeek() } }
            )) {
                ChildPeekSheet(controller: controller)
            }
            .toolbar {
                if controller.strands.count > 1 {
                    ToolbarItem {
                        Picker("Agent", selection: $controller.focusedStrand) {
                            ForEach(controller.strands) { strand in
                                Text(StrandName.display(strand.id)).tag(strand.id)
                            }
                        }
                        .help("Choose which agent's transcript to read")
                    }
                    ToolbarSpacer(.fixed)
                }
                ToolbarItem {
                    Button {
                        model.showsInspector.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help("Show the changes, agents and details (⌥⌘I)")
                }
            }
    }
}

enum StrandName {
    /// `sub:^main/build-1a2b` reads as `build`, and `main` stays itself.
    static func display(_ id: String) -> String {
        guard id.hasPrefix("sub:") else { return id }
        let last = id.split(separator: "/").last.map(String.init) ?? id
        if let dash = last.lastIndex(of: "-"), last.distance(from: dash, to: last.endIndex) <= 6 {
            return String(last[..<dash])
        }
        return last
    }
}

/// The reading column.
///
/// It follows the newest output while the person is at the bottom and stays put
/// once they scroll up, with a control to return. That is the behaviour that lets
/// someone read an earlier step while the agent keeps working.
private struct TranscriptView: View {
    let controller: SessionController
    let query: String
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @State private var viewport: CGFloat = 0

    private var visibleBlocks: [TranscriptBlock] {
        guard !query.isEmpty else { return controller.blocks }
        return controller.blocks.filter { $0.contains(query) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if controller.hasOlder, query.isEmpty {
                    Button(controller.isLoadingOlder ? "Loading…" : "Load Earlier") {
                        controller.loadOlder()
                    }
                    .buttonStyle(.link)
                    .frame(maxWidth: .infinity)
                }
                ForEach(visibleBlocks) { block in
                    BlockView(block: block, controller: controller)
                }
                if query.isEmpty {
                    LiveTail(controller: controller)
                }
                if !query.isEmpty, visibleBlocks.isEmpty {
                    Text("No matches in what is loaded.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                if !controller.isAdopted {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: Theme.contentWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)

            // A short conversation starts at the top and follows the bottom only once
            // it overflows, so a new session does not float under empty space. This
            // is a minimum, so a long transcript still has its full height to scroll.
            .frame(minHeight: viewport, alignment: .top)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // The visible rectangle accounts for the composer's inset, which the
            // raw offset does not, so a short transcript never reads as scrolled.
            geometry.visibleRect.maxY >= geometry.contentSize.height - 40
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        // Layout geometry excludes the toolbar and composer insets, and it reports at
        // once, before anything has scrolled.
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { viewport = $0 }
        .overlay(alignment: .bottom) {
            if !isAtBottom {
                Button {
                    withAnimation(.smooth(duration: 0.25)) { position.scrollTo(edge: .bottom) }
                } label: {
                    Label("Latest", systemImage: "arrow.down")
                        .font(Theme.label)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.smooth(duration: 0.18), value: isAtBottom)
    }
}

extension TranscriptBlock {
    func contains(_ query: String) -> Bool {
        func search(_ text: String) -> Bool { text.localizedCaseInsensitiveContains(query) }
        func search(_ row: TranscriptRow) -> Bool {
            switch row.kind {
            case .user(let text, _), .assistant(let text), .thinking(let text), .notice(let text), .failure(let text):
                return search(text)
            case .tool(let name, let arguments, let result, _):
                return search(name) || search(arguments.compactText) || search(result ?? "")
            }
        }
        switch self {
        case .row(let row): return search(row)
        case .activity(let rows): return rows.contains(where: search)
        }
    }
}

private struct BlockView: View {
    let block: TranscriptBlock
    let controller: SessionController

    var body: some View {
        switch block {
        case .row(let row):
            RowView(row: row)
        case .activity(let rows):
            ActivityGroup(rows: rows, tails: controller.toolTails)
        }
    }
}

struct RowView: View {
    let row: TranscriptRow
    @State private var isHovering = false

    var body: some View {
        switch row.kind {
        case .user(let text, let author):
            HStack(alignment: .top, spacing: 6) {
                Spacer(minLength: 80)
                CopyButton(text: text, label: "Copy message")
                    .opacity(isHovering ? 1 : 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(text)
                        .font(Theme.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(Theme.tintStrong, in: .rect(cornerRadius: Theme.radius))
                    if let author, author != "Owner" {
                        Text(author).font(Theme.meta).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
            .onHover { isHovering = $0 }
        case .assistant(let text):
            MarkdownView(source: text)
                .overlay(alignment: .topTrailing) {
                    CopyButton(text: text, label: "Copy reply")
                        .opacity(isHovering ? 1 : 0)
                }
                .onHover { isHovering = $0 }
        case .thinking(let text):
            Disclosure {
                Image(systemName: "brain").foregroundStyle(.tertiary)
                Text("Thought").foregroundStyle(.secondary)
            } content: {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .tool:
            ToolRow(row: row, tail: nil)
        case .notice(let text):
            HStack(spacing: 10) {
                VStack { Divider() }
                Text(text.split(separator: "\n").first.map(String.init) ?? text)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .help(text)
                VStack { Divider() }
            }
        case .failure(let text):
            Label {
                Text(text).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.octagon").foregroundStyle(Theme.failure)
            }
            .font(Theme.body)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(fill: Theme.failure.opacity(0.09))
        }
    }
}

/// A run of tool calls read as one line until the person opens it, and open by
/// itself while it is running, so work is visible while it happens.
private struct ActivityGroup: View {
    let rows: [TranscriptRow]
    let tails: [String: String]
    @State private var userOpened: Bool?

    private var status: ToolSummary.Status { ToolSummary.status(rows) }
    private var isOpen: Bool { userOpened ?? (status == .running) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { userOpened = !isOpen }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(ToolSummary.describe(rows))
                        .font(Theme.label)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                    if !isOpen, let target = ToolSummary.firstTarget(rows) {
                        Text(target)
                            .font(Theme.meta)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
            .accessibilityLabel(ToolSummary.describe(rows))
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        ToolRow(row: row, tail: row.callID.flatMap { tails[$0] })
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

/// One tool call, drawn for what the tool does. A shell command reads as a command
/// and its output, and a write reads as the change it made.
private struct ToolRow: View {
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
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: icon(parts.name))
                            .font(.system(size: 11))
                            .foregroundStyle(parts.isError ? Theme.failure : .secondary)
                            .frame(width: 14)
                        Text(title(parts.name, parts.arguments))
                            .font(Theme.code)
                            .foregroundStyle(parts.isError ? Theme.failure : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if parts.result == nil {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(parts.name)
                .accessibilityLabel("\(parts.name): \(title(parts.name, parts.arguments))")

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
            DiffView(summary: Diff.between(
                old: parts.arguments["old"]?.string ?? parts.arguments["old_string"]?.string ?? "",
                new: parts.arguments["new"]?.string ?? parts.arguments["new_string"]?.string ?? ""
            ))
        case "bash", "fs_read", "grep":
            EmptyView()
        default:
            if parts.arguments != .null {
                OutputBlock(text: parts.arguments.compactText, tint: .secondary)
            }
        }
        if let result = parts.result, !result.isEmpty {
            OutputBlock(text: result, tint: parts.isError ? Theme.failure : .primary)
        }
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

    private func title(_ name: String, _ arguments: JSONValue) -> String {
        for key in ["command", "path", "pattern", "query", "url"] {
            if let value = arguments[key]?.string {
                return value.split(separator: "\n").first.map(String.init) ?? value
            }
        }
        return name
    }
}

private struct OutputBlock: View {
    let text: String
    var tint: Color

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(Theme.code)
                .foregroundStyle(tint)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
        .surface(radius: Theme.radiusInner)
    }
}

private struct Disclosure<Header: View, Content: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 7) {
                    header()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .font(Theme.label)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isOpen { content() }
        }
    }
}

/// What the agent is doing right now. It reads the stream alone, so tokens arriving
/// redraw this view and not the transcript above it. Its pieces are direct children
/// of the transcript's lazy stack.
private struct LiveTail: View {
    let controller: SessionController

    var body: some View {
        if let stream = controller.stream {
            if !stream.thinking.isEmpty, stream.text.isEmpty {
                Text(stream.thinking.suffix(500))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
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
        if let since = controller.busySince {
            WorkingLine(since: since)
        }
    }
}

/// The elapsed time of a run. Its timeline ticks once a second and redraws only
/// this line.
private struct WorkingLine: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            HStack(spacing: 8) {
                StatusDot(liveness: .working)
                Text("Working")
                Text(Duration.seconds(context.date.timeIntervalSince(since)).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .font(Theme.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: Composer

/// Everything that floats over the transcript. It shares one glass container, since
/// glass cannot sample other glass and nearby pieces must be drawn together.
private struct ComposerStack: View {
    let controller: SessionController

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                if !controller.isLive {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Reconnecting. What you see may be out of date.")
                            .font(Theme.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular.tint(Theme.attention.opacity(0.18)), in: .rect(cornerRadius: Theme.radius))
                }
                // The card is flat, as it is everywhere, on one plain piece of glass
                // that keeps it legible over the transcript scrolling beneath it.
                ForEach(controller.escalations) { escalation in
                    ApprovalCard(record: escalation, controller: controller)
                        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radiusFloating))
                }
                if !controller.remoteChildren.isEmpty {
                    RemoteAgentsStrip(controller: controller)
                }
                ForEach(controller.pendingInputs.filter { $0.strand == controller.focusedStrand }) { input in
                    HStack(spacing: 8) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text(input.text).lineLimit(1)
                        Spacer()
                        Text(input.kind == "steer" ? "next step" : "queued")
                            .font(Theme.meta)
                            .foregroundStyle(.secondary)
                    }
                    .font(Theme.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .rect(cornerRadius: Theme.radius))
                }
                if let error = controller.lastError {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.failure)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }
                Composer(controller: controller)
            }
        }
        .frame(maxWidth: Theme.contentWidth)
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.2), value: controller.escalations)
    }
}

private struct Composer: View {
    let controller: SessionController
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let busy = controller.isBusy
        VStack(alignment: .leading, spacing: 8) {
            TextField(placeholder(busy), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...12)
                .focused($isFocused)
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                    send()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard controller.isBusy else { return .ignored }
                    controller.abort()
                    return .handled
                }
                .accessibilityLabel("Message")

            HStack(spacing: 10) {
                Group {
                    if let model = controller.strand?.model {
                        Label(model, systemImage: "cpu")
                    }
                    if let tokens = controller.totalTokens, tokens > 0 {
                        Text("\(tokens.formatted(.number.notation(.compactName))) tokens")
                    }
                    if let cost = controller.totalCost, cost > 0 {
                        Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                    }
                    if controller.peers.count > 1 {
                        Label("\(controller.peers.count)", systemImage: "person.2")
                            .help(controller.peers.map { "\($0.name) (\($0.role))" }.joined(separator: ", "))
                    }
                }
                .font(Theme.meta)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)

                Spacer(minLength: 8)

                if busy, text.isEmpty {
                    Button {
                        controller.abort()
                    } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Stop this run (⎋)")
                    .accessibilityLabel("Stop this run")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(busy ? "Steer this run (↩)" : "Send (↩)")
                    .accessibilityLabel(busy ? "Steer this run" : "Send")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radiusFloating))
        .onAppear { isFocused = true }
    }

    private func placeholder(_ busy: Bool) -> String {
        busy ? "Steer this run…" : "Message \(StrandName.display(controller.focusedStrand))…"
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        controller.send(text: trimmed)
        text = ""
    }
}

// MARK: Approvals

/// The consent surface.
///
/// The layout carries the rules of protocol section 5.10: the tool is always
/// named, the model-authored preview sits in its own bounded block with controls
/// escaped, the screen says it is a sample of a larger action, and the requested
/// authority is listed literally.
struct ApprovalCard: View {
    let record: Escalation
    let controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.attention)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(record.authorityLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 13, weight: .semibold).monospaced())
                            .textSelection(.enabled)
                    }
                    if record.authorityLines.isEmpty {
                        Text("Allow this call?").font(.system(size: 13, weight: .semibold))
                    }
                    HStack(spacing: 6) {
                        Text(record.tool.isEmpty ? "unnamed tool" : record.tool).font(Theme.meta)
                        if !record.strand.isEmpty { Text("· \(StrandName.display(record.strand))") }
                        if let placement = record.placement { Text("· @ \(placement)") }
                    }
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if !record.reason.isEmpty {
                Text(record.reason).font(Theme.caption).foregroundStyle(.secondary)
            }
            if !record.outsideCeiling.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also requested, beyond what this session may grant, so an approval will not include it:")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.attention)
                    ForEach(record.outsideCeiling, id: \.self) { line in
                        Text(line).font(Theme.code).foregroundStyle(.secondary)
                    }
                }
            }
            if record.untranslatableGrants > 0 {
                Text("\(record.untranslatableGrants) more this version of the app cannot show.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.failure)
            }

            // The preview stays on screen, as protocol section 5.10 asks of consent:
            // it is the only view of what the call does beyond the authority it wants.
            ScrollView {
                Text(record.safePreview.isEmpty ? "(no preview)" : record.safePreview)
                    .font(Theme.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 96)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: .rect(cornerRadius: Theme.radiusInner))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusInner).strokeBorder(Theme.hairline, lineWidth: 0.5))

            HStack(spacing: 8) {
                Text("A sample of the call, written by the model. Allowing covers the whole action.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ApprovalButtons(record: record, controller: controller)
            }
        }
        .padding(13)
        .background(Theme.attention.opacity(0.09), in: .rect(cornerRadius: Theme.radiusFloating))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusFloating).strokeBorder(Theme.attention.opacity(0.4), lineWidth: 1))
    }
}

/// The answers to a request, the same wherever one is shown. Remembering a grant
/// widens it past this one call, so that choice sits behind the menu rather than
/// beside a single click.
struct ApprovalButtons: View {
    let record: Escalation
    let controller: SessionController

    var body: some View {
        Button("Deny") { controller.deny(record) }
            .buttonStyle(.bordered)
            .help("Deny (⇧⌘D)")
        Button("Allow") { controller.approve(record) }
            .buttonStyle(.borderedProminent)
            .tint(Theme.grant)
            .disabled(!record.canApprove)
            .help("Allow once (⇧⌘A)")
        if record.canRemember {
            Menu {
                Button("Allow for This Session") { controller.approve(record, remember: true) }
                    .help("Keeps this authority for the session, across restarts.")
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More ways to allow")
            .accessibilityLabel("More ways to allow")
        }
    }
}

// MARK: Remote agents

/// Subagents on other orchestrators. Each row is the stub the parent's daemon
/// holds, so it keeps its last glance when that machine cannot be reached.
private struct RemoteAgentsStrip: View {
    let controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(controller.remoteChildren) { child in
                Button {
                    controller.peek(child: child)
                } label: {
                    RemoteChildRow(child: child)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radiusFloating))
    }
}

struct RemoteChildRow: View {
    let child: RemoteChild

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(liveness: child.isActive ? .working : .idle)
            Text(child.title).font(Theme.label).lineLimit(1)
            Text("@ \(child.orchestrator)").font(Theme.meta).foregroundStyle(.secondary)
            Text(child.summary).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(child.standing).font(Theme.meta).foregroundStyle(.secondary)
            if let age = child.ageMs, age > 30_000 {
                Text("\(age / 1000)s old").font(Theme.meta).foregroundStyle(Theme.attention)
            }
        }
    }
}

/// A read-only page of a remote child's transcript. Its markdown is drawn as plain
/// text, because it is model output from another machine.
private struct ChildPeekSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: SessionController

    var body: some View {
        let peek = controller.peek
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if peek?.isPending == true {
                        ProgressView().controlSize(.small)
                    }
                    if let failure = peek?.failure {
                        Text(failure).foregroundStyle(Theme.failure)
                    }
                    ForEach(peek?.rows ?? []) { row in
                        if case .assistant(let text) = row.kind {
                            Text(text).font(Theme.body).textSelection(.enabled)
                        } else {
                            RowView(row: row)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(StrandName.display(peek?.child ?? ""))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(width: 680, height: 540)
    }
}

// MARK: Inspector

private struct SessionInspector: View {
    let record: SessionRecord
    let controller: SessionController
    let placement: Placement?

    enum Tab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case agents = "Agents"
        case details = "Details"
        var id: Self { self }
    }

    @SceneStorage("inspectorTab") private var tab = Tab.changes

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollView {
                Group {
                    switch tab {
                    case .changes: ChangesPane(controller: controller)
                    case .agents: AgentsPane(controller: controller)
                    case .details: DetailsPane(record: record, controller: controller, placement: placement)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The worktree's changes, as the daemon observes them on the machine with the
/// checkout. It reads again whenever a tool run in this session settles.
private struct ChangesPane: View {
    let controller: SessionController

    private var settledTools: Int {
        controller.blocks.reduce(0) { total, block in
            if case .activity(let rows) = block { return total + rows.count }
            return total
        }
    }

    var body: some View {
        let board = controller.worktree
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                let entries = board?["entries"]?.array ?? []
                Text(entries.isEmpty ? "Changes" : "\(entries.count) changed file\(entries.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                Button {
                    controller.requestDiff()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Read the worktree again")
                .accessibilityLabel("Refresh changes")
            }
            if let board {
                if board["status"]?.string == "failed" {
                    Text(board["message"]?.string ?? "The observation failed.")
                        .foregroundStyle(Theme.failure)
                } else if board["status"]?.string == "pending" {
                    ProgressView().controlSize(.small)
                }
                let entries = board["entries"]?.array ?? []
                if entries.isEmpty, board["status"]?.string == "ready" {
                    Text("No uncommitted changes.").foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.self) { entry in
                    FileChange(entry: entry)
                }
                if let omitted = board["omitted"]?.int, omitted > 0 {
                    Text("\(omitted) more files were not captured.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                if let committed = board["committed"]?["patch"]?.string, !committed.isEmpty {
                    Text("Committed in this session").font(.headline).padding(.top, 6)
                    DiffView(summary: Diff.parse(committed))
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: settledTools) {
            try? await Task.sleep(for: .milliseconds(300))
            controller.requestDiff()
        }
    }
}

private struct FileChange: View {
    let entry: JSONValue
    @State private var isOpen = true

    var body: some View {
        let path = entry["path"]?.string ?? ""
        let summary = Diff.parse(entry["patch"]?.string ?? "")
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(path).font(.system(size: 12, weight: .medium).monospaced()).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 6)
                    if summary.added > 0 {
                        Text("+\(summary.added)").font(Theme.meta).foregroundStyle(Theme.addedText)
                    }
                    if summary.removed > 0 {
                        Text("−\(summary.removed)").font(Theme.meta).foregroundStyle(Theme.removedText)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(path), \(summary.added) added, \(summary.removed) removed")

            if isOpen {
                DiffView(summary: summary, language: Syntax.language(forPath: path))
            }
        }
    }
}

/// Every agent in this session, on this orchestrator or another.
private struct AgentsPane: View {
    let controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.strands) { strand in
                Button {
                    controller.focusedStrand = strand.id
                } label: {
                    HStack(spacing: 8) {
                        StatusDot(liveness: strand.isBusy ? .working : .idle)
                        Text(StrandName.display(strand.id))
                            .font(.system(size: 13, weight: strand.id == controller.focusedStrand ? .semibold : .regular))
                        Spacer()
                        if let model = strand.model {
                            Text(model).font(Theme.meta).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(strand.id == controller.focusedStrand ? Theme.tintStrong : .clear, in: .rect(cornerRadius: Theme.radiusInner))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if !controller.remoteChildren.isEmpty {
                Text("On other machines")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                ForEach(controller.remoteChildren) { child in
                    Button {
                        controller.peek(child: child)
                    } label: {
                        RemoteChildRow(child: child)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct DetailsPane: View {
    let record: SessionRecord
    let controller: SessionController
    let placement: Placement?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("Where") {
                if let placement {
                    row("Conversation", placement.brain)
                    row("Tools", placement.hands)
                }
                row("Workspace", record.workspace)
                if let branch = controller.branch { row("Branch", branch) }
            }
            group("Usage") {
                row("Total tokens", (controller.totalTokens ?? 0).formatted())
                row("Input", (controller.usage["input"]?.int ?? 0).formatted())
                row("Output", (controller.usage["output"]?.int ?? 0).formatted())
                row("Cache read", (controller.usage["cacheRead"]?.int ?? 0).formatted())
                if let cost = controller.totalCost, cost > 0 {
                    row("Cost", cost.formatted(.currency(code: "USD").precision(.fractionLength(4))))
                } else {
                    row("Cost", "Not priced")
                }
            }
            if !controller.peers.isEmpty {
                group("Attached") {
                    ForEach(controller.peers) { peer in
                        row(peer.name, peer.role)
                    }
                }
            }
            group("Session") {
                HStack {
                    Text(record.id).font(Theme.meta).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    CopyButton(text: record.id, label: "Copy session ID")
                }
                row("Created", record.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12).monospaced())
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
