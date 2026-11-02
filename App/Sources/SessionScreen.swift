import LoomKit
import MissionKit
import SwiftUI

/// One session: the transcript, the composer, and a review pane.
struct SessionScreen: View {
    @Environment(AppModel.self) private var model
    let sessionID: String
    @State private var showsReview = false

    private var record: SessionRecord? {
        model.sessions.first { $0.id == sessionID }
    }

    private var daemon: DaemonConnection? {
        model.daemon(holding: sessionID)
    }

    var body: some View {
        Group {
            if let record, record.state.isResident, let controller = model.controller(for: sessionID) {
                LiveSession(
                    record: record,
                    controller: controller,
                    placement: model.placement(of: record),
                    showsReview: $showsReview,
                    reconnect: { daemon?.attach(sessionID) }
                )
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
        VStack(spacing: 12) {
            Text(record.title).font(.title3.weight(.medium))
            Text(record.workspace).font(Theme.meta).foregroundStyle(.secondary)
            switch record.state {
            case .reserved(let failure):
                Text(failure ?? "This session never finished starting.")
                    .foregroundStyle(Theme.failure)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            case .recoveryBlocked:
                Text("Recovery is blocked, so this session cannot open.")
                    .foregroundStyle(Theme.failure)
            default:
                Button(isOpening ? "Resuming…" : "Resume session") {
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
                .disabled(isOpening)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(Theme.failure)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LiveSession: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord
    let controller: SessionController
    let placement: Placement?
    @Binding var showsReview: Bool
    let reconnect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(controller: controller)
            VStack(spacing: 10) {
                // A dead socket must never look connected, or a person acts on
                // a screen that has stopped telling the truth.
                if !controller.isLive {
                    HStack {
                        Text("Disconnected from this session. What you see may be out of date.")
                            .font(.callout)
                        Spacer()
                        Button("Reconnect", action: reconnect)
                    }
                    .padding(10)
                    .surface(fill: Theme.attention.opacity(0.07))
                }
                if !controller.conversation.remoteChildren.isEmpty {
                    RemoteAgentsStrip(controller: controller)
                }
                ForEach(controller.conversation.escalations) { escalation in
                    ApprovalCard(record: escalation, controller: controller)
                }
                if let error = controller.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Theme.failure)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Composer(controller: controller)
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(record.title)
        .sheet(isPresented: Binding(
            get: { controller.conversation.peek != nil },
            set: { if !$0 { controller.endPeek() } }
        )) {
            ChildPeekSheet(controller: controller)
        }
        .inspector(isPresented: $showsReview) {
            ReviewPane(controller: controller)
                .inspectorColumnWidth(min: 320, ideal: 460, max: 760)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SessionHeader(record: record, controller: controller, placement: placement)
            }
            ToolbarItemGroup {
                if controller.conversation.strands.count > 1 {
                    @Bindable var controller = controller
                    Picker("Strand", selection: $controller.focusedStrand) {
                        ForEach(controller.conversation.strands) { strand in
                            Text(strand.id).tag(strand.id)
                        }
                    }
                    .fixedSize()
                }
                Button {
                    showsReview.toggle()
                    if showsReview { controller.requestDiff() }
                } label: {
                    Label("Review changes", systemImage: "plus.forwardslash.minus")
                }
                .help("Review the worktree's changes")
            }
        }
    }
}

/// A single quiet line of what this session is: place, model, spend, people.
private struct SessionHeader: View {
    let record: SessionRecord
    let controller: SessionController
    let placement: Placement?

    var body: some View {
        let conversation = controller.conversation
        HStack(spacing: 10) {
            Text(record.title).font(.headline).lineLimit(1)
            Group {
                Text([record.workspaceName, conversation.branch].compactMap { $0 }.joined(separator: " · "))
                if let placement {
                    Label(placement.label, systemImage: placement.isSplit ? "arrow.left.arrow.right" : "desktopcomputer")
                        .help(placement.isSplit
                            ? "The conversation and keys are on \(placement.brain). Tools run on \(placement.hands)."
                            : "The conversation and its tools run on \(placement.brain).")
                }
                if let model = controller.strand?.model { Text(model) }
                if let cost = conversation.totalCost, cost > 0 {
                    Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                }
                if conversation.peers.count > 1 {
                    Label("\(conversation.peers.count)", systemImage: "person.2")
                        .help(conversation.peers.map { "\($0.name) (\($0.role))" }.joined(separator: ", "))
                }
            }
            .font(Theme.meta)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

private struct TranscriptView: View {
    let controller: SessionController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if controller.conversation.hasOlder(strand: controller.focusedStrand) {
                    Button(controller.isLoadingOlder ? "Loading…" : "Load earlier") {
                        controller.loadOlder()
                    }
                    .buttonStyle(.link)
                    .frame(maxWidth: .infinity)
                }
                ForEach(controller.rows) { row in
                    RowView(row: row, tails: controller.conversation.toolTails)
                }
                if let stream = controller.stream {
                    StreamView(stream: stream)
                }
                if controller.isBusy, controller.stream == nil {
                    ProgressView().controlSize(.small)
                }
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
    }
}

private struct RowView: View {
    let row: TranscriptRow
    let tails: [String: String]

    var body: some View {
        switch row.kind {
        case .user(let text, let author):
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .surface()
                    if let author, author != "Owner" {
                        Text(author).font(Theme.meta).foregroundStyle(.secondary)
                    }
                }
            }
        case .assistant(let text):
            MarkdownText(source: text)
        case .thinking(let text):
            Disclosure(title: "Thinking", icon: "brain") {
                Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .tool(let name, let arguments, let result, let isError):
            ToolRow(name: name, arguments: arguments, result: result, isError: isError)
        case .notice(let text):
            Text(text).font(Theme.meta).foregroundStyle(.secondary)
        case .failure(let text):
            Text(text)
                .textSelection(.enabled)
                .foregroundStyle(Theme.failure)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(fill: Theme.failure.opacity(0.08))
        }
    }
}

/// A tool call collapsed to one line: the tool, the argument that identifies
/// the call, and whether it failed. The detail is one click away.
private struct ToolRow: View {
    let name: String
    let arguments: JSONValue
    let result: String?
    let isError: Bool

    private var summary: String {
        for key in ["command", "path", "pattern", "query", "url", "code"] {
            if let value = arguments[key]?.string {
                return value.split(separator: "\n").first.map(String.init) ?? value
            }
        }
        return arguments == .null ? "" : arguments.compactText
    }

    var body: some View {
        Disclosure(
            title: name,
            subtitle: summary,
            icon: isError ? "exclamationmark.triangle" : "terminal",
            tint: isError ? Theme.failure : .secondary,
            running: result == nil
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if arguments != .null {
                    CodeBlock(text: arguments.compactText)
                }
                if let result, !result.isEmpty {
                    CodeBlock(text: result, tint: isError ? Theme.failure : .primary)
                }
            }
        }
    }
}

private struct Disclosure<Content: View>: View {
    var title: String
    var subtitle: String = ""
    var icon: String
    var tint: Color = .secondary
    var running = false
    @ViewBuilder var content: () -> Content
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isOpen.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon).foregroundStyle(tint).frame(width: 14)
                    Text(title).font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text(subtitle)
                        .font(Theme.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if running { ProgressView().controlSize(.mini) }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                content()
            }
        }
    }
}

private struct CodeBlock: View {
    let text: String
    var tint: Color = .primary

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .surface()
    }
}

private struct StreamView: View {
    let stream: LiveStream

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !stream.thinking.isEmpty, stream.text.isEmpty {
                Text(stream.thinking.suffix(400))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !stream.text.isEmpty {
                MarkdownText(source: stream.text)
            }
            ForEach(stream.tools) { tool in
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(tool.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                }
            }
        }
    }
}

/// Subagents on other orchestrators. Each row is the stub the parent's daemon
/// holds, so it keeps its last glance when that machine cannot be reached.
private struct RemoteAgentsStrip: View {
    let controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(controller.conversation.remoteChildren) { child in
                Button {
                    controller.peek(child: child)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(child.isActive ? Theme.working : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(child.title).lineLimit(1)
                        Text("@ \(child.orchestrator)").font(Theme.meta).foregroundStyle(.secondary)
                        Text(child.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(child.standing).font(Theme.meta).foregroundStyle(.secondary)
                        if let age = child.ageMs, age > 30_000 {
                            Text("\(age / 1000)s old").font(Theme.meta).foregroundStyle(Theme.attention)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .surface()
    }
}

/// A read-only page of a remote child's transcript, drawn as plain text because
/// it is model output from another machine.
private struct ChildPeekSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: SessionController

    var body: some View {
        let peek = controller.conversation.peek
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(peek?.child ?? "").font(.system(.headline, design: .monospaced)).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if peek?.isPending == true {
                ProgressView().controlSize(.small)
            }
            if let failure = peek?.failure {
                Text(failure).foregroundStyle(Theme.failure)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(peek?.rows ?? []) { row in
                        RowView(row: row, tails: [:])
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}

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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised").foregroundStyle(Theme.attention)
                Text("Allow ")
                    + Text(record.tool.isEmpty ? "an unnamed tool" : record.tool).font(.body.monospaced().weight(.medium))
                    + Text("?")
                Spacer()
                if !record.strand.isEmpty {
                    Text(record.strand).font(Theme.meta).foregroundStyle(.secondary)
                }
                if let placement = record.placement {
                    Text("@ \(placement)").font(Theme.meta).foregroundStyle(.secondary)
                }
            }
            if !record.reason.isEmpty {
                Text(record.reason).font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("It asks for").font(.caption).foregroundStyle(.secondary)
                ForEach(record.authorityLines, id: \.self) { line in
                    Text(line).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                if !record.outsideCeiling.isEmpty {
                    Text("Also requested, beyond what this session may grant, so an approval will not include it:")
                        .font(.caption)
                        .foregroundStyle(Theme.attention)
                    ForEach(record.outsideCeiling, id: \.self) { line in
                        Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if record.untranslatableGrants > 0 {
                    Text("\(record.untranslatableGrants) more this version of the app cannot show.")
                        .font(.callout)
                        .foregroundStyle(Theme.failure)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("A sample of the call, written by the model. The approval covers the whole action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(record.safePreview.isEmpty ? "(no preview)" : record.safePreview)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 110)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            }

            HStack {
                Spacer()
                Button("Deny") { controller.deny(record) }
                Button("Allow") { controller.approve(record) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.attention)
                    .disabled(!record.canApprove)
            }
        }
        .padding(12)
        .surface(fill: Theme.attention.opacity(0.07))
    }
}

private struct Composer: View {
    let controller: SessionController
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let busy = controller.isBusy
        HStack(alignment: .bottom, spacing: 8) {
            TextField(busy ? "Steer this run…" : "Message \(controller.focusedStrand)…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($isFocused)
                .onSubmit(send)
                .padding(.vertical, 6)

            if busy, text.isEmpty {
                Button(action: controller.abort) {
                    Image(systemName: "stop.fill").font(.system(size: 11))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.85), in: Circle())
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .buttonStyle(.plain)
                .help("Stop this run")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(text.isEmpty ? Theme.hairline : Color.primary.opacity(0.85), in: Circle())
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .surface(fill: Color(nsColor: .textBackgroundColor), radius: 12)
        .onAppear { isFocused = true }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        controller.send(text: trimmed)
        text = ""
    }
}

/// The worktree's changes, as the daemon observes them.
private struct ReviewPane: View {
    let controller: SessionController

    var body: some View {
        let board = controller.conversation.worktree
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Changes").font(.headline)
                    Spacer()
                    Button {
                        controller.requestDiff()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                if let board {
                    if board["status"]?.string == "failed" {
                        Text(board["message"]?.string ?? "The observation failed.")
                            .foregroundStyle(Theme.failure)
                    }
                    let entries = board["entries"]?.array ?? []
                    if entries.isEmpty, board["status"]?.string == "ready" {
                        Text("No uncommitted changes.").foregroundStyle(.secondary)
                    }
                    ForEach(entries, id: \.self) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry["path"]?.string ?? "")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                            DiffText(patch: entry["patch"]?.string ?? "")
                        }
                    }
                    if let omitted = board["omitted"]?.int, omitted > 0 {
                        Text("\(omitted) more files were not captured.").font(.callout).foregroundStyle(.secondary)
                    }
                    if let committed = board["committed"]?["patch"]?.string, !committed.isEmpty {
                        Text("Committed in this session").font(.headline).padding(.top, 6)
                        DiffText(patch: committed)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
        }
    }
}

/// A patch in full colour: red for removed lines, green for added.
struct DiffText: View {
    let patch: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 0.5)
                    .background(background(line))
            }
        }
        .surface(fill: .clear, radius: 6)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func background(_ line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return Color.green.opacity(0.18) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return Color.red.opacity(0.18) }
        return .clear
    }
}
