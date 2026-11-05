import LoomKit
import Markup
import MissionKit
import SwiftUI

/// One session: the transcript, the composer floating over it, and an inspector.
struct SessionScreen: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    /// Set while a session that was running has stopped being resident for a
    /// short while, which is what a configuration reload or a profile switch looks
    /// like from here: the daemon closes the session and opens it again. The page
    /// stays on the session it was showing instead of falling back to the saved
    /// session screen and losing its scroll, its tab and its draft.
    @State private var isReopening = false

    private var record: SessionRecord? {
        model.sessions.first { $0.id == sessionID }
    }

    private var daemon: DaemonConnection? {
        model.daemon(holding: sessionID)
    }

    var body: some View {
        Group {
            if let record, record.state.isResident || isReopening, let controller = model.controller(for: sessionID) {
                LiveSession(record: record, controller: controller, placement: model.placement(of: record))
            } else if let record {
                NotRunning(record: record)
            } else {
                ContentUnavailableView("Session not found", systemImage: "questionmark.circle")
            }
        }
        .task(id: record?.state.isResident) {
            if record?.state.isResident == true {
                isReopening = false
                daemon?.attach(sessionID)
            } else if model.controller(for: sessionID) != nil, record != nil {
                // A session that does not come back within the wait was stopped,
                // and the saved session screen is the honest page for it.
                isReopening = true
                try? await Task.sleep(for: .seconds(10))
                isReopening = false
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
                    .inspectorColumnWidth(min: 260, ideal: 460, max: 800)
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
                        // A menu rather than a picker, whose pill sets its title at the
                        // left with the arrows after it, off the centre of the pill.
                        Menu {
                            Picker("Agent", selection: $controller.focusedStrand) {
                                ForEach(controller.strands) { strand in
                                    Text(StrandName.display(strand.id)).tag(strand.id)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text(StrandName.display(controller.focusedStrand))
                        }
                        .help("Choose which agent's transcript to read")
                        .accessibilityLabel("Agent")
                        .accessibilityValue(StrandName.display(controller.focusedStrand))
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

        // The daemon suffixes a child's name with a hexadecimal id, short in some
        // builds and sixteen characters in others. Any such suffix of four or more
        // hexadecimal characters is dropped; a word after a dash is kept.
        if let dash = last.lastIndex(of: "-") {
            let suffix = last[last.index(after: dash)...]
            if suffix.count >= 4, suffix.allSatisfy(\.isHexDigit), suffix.contains(where: \.isNumber) {
                return String(last[..<dash])
            }
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
    #if DEBUG
    @Environment(AppModel.self) private var model
    #endif
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @State private var viewport: CGFloat = 0

    // Whether the reader is following the end. Only the reader's own scrolling
    // changes it, so content that changes height under the viewport cannot.
    @State private var isFollowing = true

    #if DEBUG
    @State private var sweep = SweepNotes()
    #endif
    @State private var width: CGFloat = 0

    /// What changes when a reply settles: the live tail ends and its committed
    /// rows replace it, often at a different height. Older turns paging in at the
    /// top leave both parts alone, so they never pull the reader to the end.
    private var tailKey: String {
        "\(controller.blocks.last?.id ?? "")|\(controller.stream == nil)"
    }

    private var visibleBlocks: [TranscriptBlock] {
        guard !query.isEmpty else { return controller.blocks }
        return controller.blocks.filter { $0.contains(query) }
    }

    /// How many people wrote the messages in the transcript.
    private static func authors(in blocks: [TranscriptBlock]) -> Int {
        var names = Set<String>()
        for block in blocks {
            if case .row(let row) = block, case .user(_, let author) = row.kind, let author { names.insert(author) }
        }
        return names.count
    }

    /// The model of each strand that names one, by strand id.
    private static func models(of lines: [StrandLine]) -> [String: String] {
        var models: [String: String] = [:]
        for line in lines {
            if let model = line.model { models[line.id] = model }
        }
        return models
    }

    /// One row of the lazy stack: a whole block, or one markdown block of a long reply.
    private enum Item: Identifiable {
        case block(TranscriptBlock)
        case answerPart(id: String, part: MarkdownRun, text: String, isFirst: Bool)

        var id: String {
            switch self {
            case .block(let block): return block.id
            case .answerPart(let id, _, _, _): return id
            }
        }
    }

    /// A reply with more runs of blocks than this is laid out a run per row.
    ///
    /// A lazy stack lays out a whole row once any of it is on screen, and estimates
    /// the rows it has not built. A long report as one row was ten thousand points
    /// tall: scrolling into it laid out all of it at once, and the stack's estimate
    /// of the transcript swung between a sixth and three times the real height,
    /// which left the view over rows it had not drawn. The live tail already lays
    /// a streaming reply out this way.
    private static let splitAbove = 6

    private var items: [Item] {
        visibleBlocks.flatMap { block -> [Item] in
            guard case .row(let row) = block, case .assistant(let text) = row.kind else { return [.block(block)] }
            let parts = MarkdownView.parsed(text)
            guard parts.count > Self.splitAbove else { return [.block(block)] }
            return parts.enumerated().map { index, part in
                .answerPart(id: index == 0 ? block.id : "\(block.id)#\(index)", part: part, text: text, isFirst: index == 0)
            }
        }
    }

    var body: some View {
        ScrollView {
            // One lazy stack holds everything. Building the newest block eagerly in a
            // second stack below it stopped an empty page from drawing, but a reply
            // streaming into that stack then moved the lazy stack above it on every
            // pass, the bottom anchor moved the offset, and layout never settled:
            // the app stopped responding while memory grew.
            LazyVStack(alignment: .leading, spacing: 18) {
                if controller.hasOlder, query.isEmpty {
                    Button(controller.isLoadingOlder ? "Loading…" : "Load Older Turns") {
                        controller.loadOlder()
                    }
                    .buttonStyle(.link)
                    .frame(maxWidth: .infinity)

                    // The button is built only once the reader scrolls to it, so
                    // its appearing is the request, and each page that lands
                    // changes the first block and asks for the next while it shows.
                    .task(id: controller.blocks.first?.id) { controller.loadOlder() }
                } else if controller.isAdopted, query.isEmpty, !controller.blocks.isEmpty {
                    Text("Beginning of the conversation")
                        .font(Theme.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(items) { item in
                    Group {
                        switch item {
                        case .block(let block):
                            BlockView(block: block, controller: controller)
                        case .answerPart(_, let part, let text, let isFirst):
                            AnswerPart(part: part, text: text, isFirst: isFirst)
                        }
                    }
                    .id(item.id)
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
            .environment(\.transcriptShowsAuthors, Self.authors(in: controller.blocks) > 1)
            .environment(\.strandModels, Self.models(of: controller.strandLines))
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
        .onScrollPhaseChange { _, phase, context in
            guard phase == .idle else { return }
            let geometry = context.geometry
            isFollowing = geometry.visibleRect.maxY >= geometry.contentSize.height - 40
        }

        // When a reply settles, the lazy stack replaces the tail with rows of other
        // heights and can leave the viewport over rows it has not built, which draws
        // an empty page. A reader who was following is put back at the end.
        .onChange(of: tailKey) {
            guard isFollowing else { return }
            Task { @MainActor in position.scrollTo(edge: .bottom) }
        }
        #if DEBUG
        .onChange(of: model.debugScrollToTop) {
            isFollowing = false
            position.scrollTo(edge: .top)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            sweep.contentHeight = height
        }
        .onScrollGeometryChange(for: String.self) { g in
            "content=\(Int(g.contentSize.height)) offset=\(Int(g.contentOffset.y)) visible=\(Int(g.visibleRect.minY))..\(Int(g.visibleRect.maxY)) container=\(Int(g.containerSize.height))"
        } action: { _, text in
            TranscriptDebug.geometry = text
        }

        // A steady scroll from the top to the end at 1,500 points a second, one step
        // a frame, so frame gaps can be measured while the transcript moves.
        .task(id: model.debugScrollSweep) {
            guard model.debugScrollSweep > 0 else { return }
            isFollowing = false
            position.scrollTo(edge: .top)
            try? await Task.sleep(for: .milliseconds(500))
            var offset: CGFloat = 0
            while offset < sweep.contentHeight, !Task.isCancelled {
                offset += 1500.0 / 60.0
                position.scrollTo(y: offset)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        #endif

        // Opening the inspector or resizing the window changes every row's height
        // at once, so a reader following the end is put back at it.
        //
        // A reader partway up keeps the offset. Keeping them on the same row needs
        // the stack to report which rows are visible (`scrollTargetLayout` with
        // `onScrollTargetVisibilityChange`), and with that in place a session
        // switching profile crashed AppKit with a constraint-update loop.
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { next in
            let changed = width != 0 && abs(width - next) > 1
            width = next
            guard changed, isFollowing else { return }
            Task { @MainActor in position.scrollTo(edge: .bottom) }
        }
        // Layout geometry excludes the toolbar and composer insets, and it reports at
        // once, before anything has scrolled.
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { viewport = $0 }
        .overlay(alignment: .bottom) {
            if !isAtBottom {
                Button {
                    isFollowing = true
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
            case .spawned(let child, let purpose):
                return search(child) || search(purpose)
            case .agentReport(let child, _, let report):
                return search(child) || search(report)
            case .decision(let tool, let summary, _):
                return search(tool) || search(summary)
            case .memory(_, let text):
                return search(text)
            case .peer(let session, let strand, let text):
                return search(session) || search(strand) || search(text)
            case .sibling(let strand, let text, let trailer):
                return search(strand) || search(text) || search(trailer ?? "")
            case .advisor(let frame, let body):
                return search(frame.label) || search(body)
            }
        }
        switch self {
        case .row(let row): return search(row)
        case .fold(let fold): return fold.rows.contains(where: search)
        }
    }
}

#if DEBUG
/// The content's height, for the debug scroll sweep. A plain class, so writing it
/// invalidates nothing: as state, every size change re-ran the transcript, which
/// placed the lazy rows again and changed the size again.
private final class SweepNotes {
    var contentHeight: CGFloat = 0
}
#endif

/// One run of markdown blocks of a long reply, as its own row. The first carries the
/// reply's copy control; the rest close the stack's spacing to the reply's own.
private struct AnswerPart: View {
    let part: MarkdownRun
    let text: String
    let isFirst: Bool
    @State private var isHovering = false

    var body: some View {
        MarkdownView(source: "").view(forRun: part)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, isFirst ? 0 : -8)
            .overlay(alignment: .topTrailing) {
                if isFirst {
                    CopyButton(text: text, label: "Copy reply")
                        .opacity(isHovering ? 1 : 0)
                }
            }
            .onHover { isHovering = $0 }
    }
}

private struct BlockView: View {
    let block: TranscriptBlock
    let controller: SessionController

    var body: some View {
        switch block {
        case .row(let row):
            RowView(row: row)
        case .fold(let fold):
            FoldView(fold: fold, tails: controller.toolTails, summaries: controller.summaries)
        }
    }
}

struct RowView: View {
    let row: TranscriptRow
    @State private var isHovering = false
    @Environment(\.transcriptShowsAuthors) private var showsAuthors

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
                    if row.images > 0 {
                        Label("\(row.images) image\(row.images == 1 ? "" : "s")", systemImage: "photo")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                        PictureStrip(pictures: row.pictures)
                    }
                    // Who wrote it is said only once more than one person has written
                    // in the session; with one, every message would carry the same name.
                    if let author, showsAuthors {
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
            ReasoningRow(text: text, tookMs: row.tookMs, summary: nil)
        case .tool:
            StepRow(row: row, tail: nil)
        case .spawned(let child, let purpose):
            SpawnedLine(child: child, purpose: purpose)
        case .agentReport(let child, let outcome, let report):
            AgentReportLine(child: child, outcome: outcome, report: report)
        case .decision(let tool, let summary, let outcome):
            DecisionLine(tool: tool, summary: summary, outcome: outcome)
        case .memory(let lines, let text):
            MemoryRow(lines: lines, text: text)
        case .peer(let session, let strand, let text):
            PeerCard(session: session, strand: strand, text: text)
        case .sibling(let strand, let text, let trailer):
            SiblingCard(strand: strand, text: text, trailer: trailer)
        case .advisor(let frame, let body):
            AdvisorLine(frame: frame, text: body)
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

// MARK: Composer

/// Everything that floats over the transcript. It shares one glass container, since
/// glass cannot sample other glass and nearby pieces must be drawn together.
private struct ComposerStack: View {
    let controller: SessionController

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                if !controller.isLive {
                    HStack(alignment: .top, spacing: 8) {
                        ProgressView().controlSize(.mini)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Disconnected. Reconnecting. What you see may be out of date.")
                            if let ended = controller.ended {
                                Text(ended.headline + " " + ended.advice).foregroundStyle(.secondary)
                            }
                        }
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
                PanelDock(controller: controller)
                ComposerStatus(controller: controller)
                if let error = controller.lastError {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.failure)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }
                if controller.isObserver {
                    Text("You are watching this session. An observer cannot send messages or answer requests.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radiusFloating))
                } else {
                    Composer(controller: controller)
                }
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

// MARK: Approvals

/// The consent surface.
///
/// The layout carries the rules of protocol section 5.10: the tool is always
/// named, the model-authored preview sits in its own bounded block with controls
/// escaped, the screen says it is a sample of a larger action, and the requested
/// authority is listed literally.
struct ApprovalCard: View {
    @State private var cardWidth: CGFloat = 1000
    let record: Escalation
    let controller: SessionController
    @State private var isArmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Who is asking and what for, in a sentence, before the authority.
            Text(record.sentence(asker: StrandName.display(record.strand.isEmpty ? "A strand" : record.strand)))
                .font(.system(size: 13))
                .accessibilityLabel(record.sentence(asker: StrandName.display(record.strand.isEmpty ? "A strand" : record.strand)))
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
                        Text(record.question).font(.system(size: 13, weight: .semibold))
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

            // The buttons keep their size, since they are the one thing that must stay
            // whole, and a column too narrow for the sentence beside them stacks the two.
            // This reads the width rather than measuring both layouts, because a card
            // that measures itself in the composer's bar pushes the window's content up.
            let layout = cardWidth < 460 ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                sampleNote
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) { answers }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { cardWidth = $0 }
        // A card that appears under a person's hands must not take the Return or
        // click they meant for something else, so its buttons wait 600 ms.
        .task(id: record.id) {
            isArmed = false
            try? await Task.sleep(for: .milliseconds(600))
            isArmed = true
        }
        .padding(13)
        .background(Theme.attention.opacity(0.09), in: .rect(cornerRadius: Theme.radiusFloating))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusFloating).strokeBorder(Theme.attention.opacity(0.4), lineWidth: 1))
    }

    private var sampleNote: some View {
        Text("A sample of the call, written by the model. Allowing covers the whole action.")
            .font(Theme.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var answers: some View {
        if !isArmed {
            Text("Arming…").font(Theme.caption).foregroundStyle(.tertiary).fixedSize()
        }
        ApprovalButtons(record: record, controller: controller, isArmed: isArmed)
            .fixedSize()
    }
}

/// The answers to a request, the same wherever one is shown. Remembering a grant
/// widens it past this one call, so that choice sits behind the menu rather than
/// beside a single click.
struct ApprovalButtons: View {
    let record: Escalation
    let controller: SessionController
    var isArmed = true

    var body: some View {
        if controller.isObserver {
            Text("Only an operator can answer.").font(Theme.caption).foregroundStyle(.secondary)
        } else {
            buttons
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Deny") { controller.deny(record) }
            .buttonStyle(.bordered)
            .disabled(!isArmed)
            .help("Deny (⇧⌘D)")
        Button("Allow") { controller.approve(record) }
            .buttonStyle(.borderedProminent)
            .tint(Theme.grant)
            .disabled(!record.canApprove || !isArmed)
            .help("Allow once (⇧⌘A)")
        if record.canRemember, controller.role == "owner" {
            Menu {
                Button("Allow for This Session") { controller.approve(record, remember: true) }
                    .help(record.rememberedAuthority)
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

    /// Four tabs. The strand's notes and its evolution candidates are sections
    /// of the Session tab, which already held the session's other boards.
    enum Tab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case agents = "Strands"
        case trace = "Programs"
        case details = "Session"
        var id: Self { self }

        /// The symbol drawn when the column is too narrow for titled segments.
        var symbol: String {
            switch self {
            case .changes: return "plusminus"
            case .agents: return "person.2"
            case .trace: return "curlybraces"
            case .details: return "info.circle"
            }
        }
    }

    @SceneStorage("inspectorTab") private var tab = Tab.changes

    var body: some View {
        VStack(spacing: 0) {
            // Segments never shrink below their contents, so six titled ones once
            // held the column at about 540 points however narrow it was dragged.
            // The tabs are titled segments when they fit the width offered, then
            // segments of symbols, which keep their titles for VoiceOver and as
            // tooltips, and a pop-up menu only below that.
            ViewThatFits(in: .horizontal) {
                Picker("Inspector", selection: $tab) { tabLabels(.titleOnly) }
                    .pickerStyle(.segmented)
                    .fixedSize()
                Picker("Inspector", selection: $tab) { tabLabels(.iconOnly) }
                    .pickerStyle(.segmented)
                    .fixedSize()
                Picker("Inspector", selection: $tab) { tabLabels(.titleOnly) }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollView {
                Group {
                    switch tab {
                    case .changes: ChangesPane(controller: controller)
                    case .agents: StrandsPane(controller: controller)
                    case .details: DetailsPane(record: record, controller: controller, placement: placement)
                    case .trace: TracePane(controller: controller)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func tabLabels<S: LabelStyle>(_ style: S) -> some View {
        ForEach(Tab.allCases) { tab in
            let title = tab == .agents ? controller.strandsTabTitle : tab.rawValue
            Label(title, systemImage: tab.symbol)
                .labelStyle(style)
                .help(title)
                .tag(tab)
        }
    }
}

/// The worktree's changes, as the daemon observes them on the machine with the
/// checkout. It reads again whenever a tool run in this session settles.
private struct ChangesPane: View {
    let controller: SessionController

    private var settledTools: Int {
        controller.blocks.reduce(0) { total, block in
            if case .fold(let fold) = block { return total + fold.rows.count }
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
                if board["extent"]?.string == "limited" {
                    Text("The diff was cut by the display limit, so some patches are partial.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
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

    /// The status as one of a few fixed words, from the two porcelain letters.
    private var statusWord: String {
        switch (entry["index_status"]?.string ?? "", entry["worktree_status"]?.string ?? "") {
        case ("?", _): return "new"
        case (_, "D"), ("D", _): return "deleted"
        case ("A", _): return "added"
        default: return "modified"
        }
    }

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
                    Text(statusWord).font(Theme.caption).foregroundStyle(.tertiary)
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
            .accessibilityLabel("\(path), \(summary.added) added, \(summary.removed) removed, \(statusWord)")

            if isOpen {
                DiffView(summary: summary, language: Syntax.language(forPath: path))
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
                row("Estimated cost", UsageWords.figure(usage: controller.usage))
            }
            SessionExtras(controller: controller)
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
                CoreStatusSection(controller: controller)
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

#if DEBUG
/// The transcript's last scroll geometry, for the UI driver's snapshot.
@MainActor
enum TranscriptDebug {
    static var geometry = ""
}
#endif

extension EnvironmentValues {
    /// Whether a message names its author, which it does once more than one
    /// person has written in the transcript.
    @Entry var transcriptShowsAuthors = true

    /// The model each strand runs on, by strand id, so a row that names a
    /// strand can say what it runs on.
    @Entry var strandModels: [String: String] = [:]
}
