import LoomKit
import Markup
import MissionKit
import SwiftUI

/// The fleet at a glance, laid out as flight strips rather than cards: one line per
/// agent, in fixed columns, so a person compares many by scanning down. What needs
/// them leads and can be answered in place, and a healthy fleet stays quiet.
struct MissionControlView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("missionShowsSaved") private var showsSaved = false

    private func cards(_ state: AgentCard.Liveness) -> [AgentCard] {
        model.cards.filter { $0.liveness == state }
    }

    var body: some View {
        @Bindable var model = model
        let allCards = model.cards
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                let waiting = model.attention
                if !waiting.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Needs You", count: waiting.count)
                        VStack(spacing: 8) {
                            ForEach(waiting.prefix(6)) { item in
                                NeedsYouRow(item: item)
                            }
                        }
                        if waiting.count > 6 {
                            Button("\(waiting.count - 6) more in the Inbox") { model.destination = .inbox }
                                .buttonStyle(.link)
                        }
                    }
                }

                // Sessions another orchestrator holds are not on this board, so a strip
                // says they exist and where to read them.
                let elsewhere = model.elsewhere.reduce(0) { $0 + $1.sessions.count }
                if elsewhere > 0 {
                    HStack(spacing: 8) {
                        Text("\(elsewhere) on other orchestrators").font(.callout).foregroundStyle(.secondary)
                        Button("Machines") { model.destination = .machines }
                            .buttonStyle(.link)
                    }
                }

                if allCards.isEmpty {
                    ContentUnavailableView {
                        Label("No agents yet", systemImage: "sparkles")
                    } description: {
                        Text("Dispatch one to start working. It keeps running here if you close this window.")
                    } actions: {
                        Button("New Agent") { model.isDispatching = true }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    stripSection("Working", cards(.working))
                    stripSection("Idle", cards(.idle))
                    stripSection("Not Answering", cards(.unknown))
                    if !cards(.off).isEmpty {
                        DisclosureGroup(isExpanded: $showsSaved) {
                            strips(cards(.off)).padding(.top, 8)
                        } label: {
                            SectionTitle("Saved", count: cards(.off).count)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Mission Control")
    }

    @ViewBuilder
    private func stripSection(_ title: String, _ rows: [AgentCard]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title, count: rows.count)
                strips(rows)
            }
        }
    }

    private func strips(_ rows: [AgentCard]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, card in
                if index > 0 { Divider().padding(.leading, 12) }
                AgentStrip(card: card)
            }
        }
        .surface()
    }
}

private struct SectionTitle: View {
    let title: String
    let count: Int

    init(_ title: String, count: Int) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// An item waiting on a person. An approval can be answered right here, because
/// sending someone elsewhere to press one button is the interruption this avoids.
private struct NeedsYouRow: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem

    private var escalation: (record: Escalation, controller: SessionController)? {
        if case .session(let id, let record?) = item.source, let controller = model.controller(for: id) {
            return (record, controller)
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(liveness: .needsYou)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.agent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(item.kind.title).font(Theme.caption).foregroundStyle(Theme.attention)
                }
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let escalation {
                ApprovalButtons(record: escalation.record, controller: escalation.controller)
            }
            Button {
                open()
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Open")
            .accessibilityLabel("Open \(item.agent)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .surface(fill: Theme.attention.opacity(0.08))
        .contentShape(.rect)
        .onTapGesture(perform: open)
    }

    private var summary: String {
        if let escalation {
            return escalation.record.authorityLines.first ?? item.title
        }
        return item.title
    }

    private func open() {
        switch item.source {
        case .session(let id, _): model.destination = .session(id)
        case .machine: model.destination = .machines
        }
    }
}

/// One agent on one line: state, name and latest word, where it runs, and its model.
private struct AgentStrip: View {
    @Environment(AppModel.self) private var model
    let card: AgentCard
    @State private var isHovering = false
    @State private var isSteering = false
    @State private var steer = ""

    private var digest: String {
        let line = Markdown.plainPreview(card.lines.first?.text.isEmpty == false ? card.lines[0].text : card.digest)
        return line == card.name ? "" : line
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(liveness: card.liveness)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                    .font(.system(size: 13, weight: model.hasUnseenReply(card.sessionID) ? .semibold : .regular))
                    .lineLimit(1)
                if !digest.isEmpty {
                    Text(digest).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if card.liveness == .working {
                HeartbeatTrace(liveness: card.liveness)
            }

            Text(model.daemon(holding: card.sessionID)?.lastChanged[card.sessionID]?.compactAge ?? "")
                .font(Theme.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)

            Text(card.placement?.label ?? card.context)
                .font(Theme.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 190, alignment: .trailing)

            Text(card.model ?? "")
                .font(Theme.meta)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 92, alignment: .trailing)

            Button {
                isSteering = true
            } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering && card.liveness != .off ? 1 : 0)
            .disabled(card.liveness == .off)
            .help("Message this agent")
            .accessibilityLabel("Message \(card.name)")
            .popover(isPresented: $isSteering, arrowEdge: .bottom) {
                TextField("Message \(card.name)…", text: $steer)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .frame(width: 340)
                    .padding(12)
                    .onSubmit(send)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovering ? Theme.tint : .clear)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture { model.destination = .session(card.sessionID) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(card.name), \(card.liveness.label)")
    }

    private func send() {
        let text = steer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        steer = ""
        isSteering = false
        let id = card.sessionID
        Task {
            guard let controller = model.daemon(holding: id)?.attach(id) else { return }
            await controller.waitUntilAdopted()
            controller.send(text: text)
        }
    }
}

// MARK: Inbox

/// What the inbox has selected: one of the rule's threads, or a machine that is not
/// healthy, which only this app lists.
private enum InboxSelection: Hashable {
    case thread(InboxSubject)
    case machine(String)
}

/// The attention inbox: a rail of folders with counts, a list of what needs a
/// person grouped by need, and a pane that reads the selected thread. The grouping
/// is `InboxRule`, which mirrors the web view's rule, so a session sits in the same
/// group on both. The list keeps focus, so a person can move down it with the arrow
/// keys and answer an approval with the keyboard.
///
/// The pane is `InboxPane` (InboxThreads.swift). It draws an approval's live card under
/// its evidence, so an approval is decided here as well as on the session's page
/// (HM-21).
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var folder: InboxFolder = .everything
    @State private var selection: InboxSelection?
    /// A draft for each thread, so a message half written survives a move down the
    /// list.
    @State private var drafts: [String: String] = [:]

    var body: some View {
        // Ages are counted from the time the list was drawn, so it redraws each
        // half minute even when nothing the daemon says has changed.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: Int(context.date.timeIntervalSince1970 * 1000))
        }
        .navigationTitle("Inbox")
        .navigationSubtitle(model.attention.isEmpty ? "" : "\(model.attention.count) waiting")
    }

    private func content(now: Int) -> some View {
        let threads = model.inboxThreads
        let feed = model.attentionRows
        let rows = InboxRule.rows(threads: threads, feed: feed, raised: model.approvalRaised, reviewing: model.reviewing, now: now)
        let all = InboxRule.sections(rows)
        let shown = InboxRule.shownFolder(chosen: folder, sections: all)
        let sections = InboxRule.visible(all, in: shown)
        let machines = model.attention.filter { $0.kind == .machine }
        let tally = model.inboxTally(threads: threads)
        let note = InboxRule.countNote(running: threads.filter { $0.activity != nil }.count, fromCatalogue: tally.fromCatalogue)
        let headline = InboxRule.headline(tally)

        return HStack(spacing: 0) {
            FolderRail(entries: InboxRule.folderEntries(all), shown: shown, note: note) { folder = $0 }
                .frame(width: 168)

            Divider()

            if sections.isEmpty && machines.isEmpty {
                ContentUnavailableView {
                    // Saved sessions are counted and not listed, so something can wait on the
                    // owner under a list with no row, and then the title says so.
                    Label(InboxRule.lead(tally), systemImage: tally.needing == 0 ? "checkmark.circle" : "tray")
                        .symbolRenderingMode(.hierarchical)
                } description: {
                    if tally.needing == 0 {
                        Text("Approvals, asks, failed runs and unhealthy machines will appear here. \(note)")
                    } else {
                        Text("\(headline). The saved sessions' counts are the catalogue's summary; resume one to read what it holds.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                InboxList(sections: sections, machines: machines, headline: headline, selection: $selection)
                    .frame(width: 330)

                Divider()

                pane(sections: sections, machines: machines)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func pane(sections: [InboxSection], machines: [AttentionItem]) -> some View {
        // A selection that is no longer listed falls back to the first thread, so
        // the pane is never empty while the list is not.
        let chosen: InboxSubject? = if case .thread(let subject)? = selection { subject } else { nil }
        let subject = InboxRule.selection(sections, chosen: chosen)
        if case .machine(let id)? = selection, let item = machines.first(where: { $0.id == id }) {
            AttentionDetail(items: [item], row: nil).id(item.id)
        } else if let subject, let row = sections.flatMap(\.rows).first(where: { $0.subject == subject }) {
            InboxPane(
                row: row,
                items: model.attention.filter { item in
                    if case .session(let id, _) = item.source { return id == subject.sessionID && item.kind != .machine }
                    return false
                },
                draft: Binding(get: { drafts[row.id] ?? "" }, set: { drafts[row.id] = $0 })
            ).id(row.id)
        } else if let item = machines.first {
            AttentionDetail(items: [item], row: nil).id(item.id)
        }
    }
}

/// The folders of the rail, each with the number of rows its band draws, and the
/// note that says what the counts read.
private struct FolderRail: View {
    let entries: [(folder: InboxFolder, count: Int?)]
    let shown: InboxFolder
    let note: String
    let pick: (InboxFolder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entries, id: \.folder) { entry in
                Button { pick(entry.folder) } label: {
                    HStack {
                        Text(entry.folder.title).font(Theme.body)
                        Spacer(minLength: 4)
                        if let count = entry.count {
                            Text("\(count)")
                                .font(Theme.caption.monospacedDigit())
                                .foregroundStyle(entry.folder == .needing ? Theme.attention : .secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(entry.folder == shown ? Theme.tintStrong : .clear, in: .rect(cornerRadius: Theme.radiusInner))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Folder \(entry.folder.title)")
                .accessibilityAddTraits(entry.folder == shown ? .isSelected : [])
            }
            Spacer()
            Text(note).font(Theme.caption).foregroundStyle(.secondary).padding(8)
        }
        .padding(8)
    }
}

/// The list: a band for each group with its count and its gloss, and under it one
/// row for each thread. The quiet sessions are folded into one line of names, since
/// there is nothing to read in them.
private struct InboxList: View {
    let sections: [InboxSection]
    let machines: [AttentionItem]
    let headline: String
    @Binding var selection: InboxSelection?

    var body: some View {
        List(selection: $selection) {
            Text(headline).font(Theme.caption).foregroundStyle(.secondary).selectionDisabled()
            ForEach(sections, id: \.group) { section in
                if section.group == .quiet {
                    Section {
                        Text(section.rows.map(\.name).joined(separator: " \u{00B7} "))
                            .font(Theme.caption).foregroundStyle(.secondary).selectionDisabled()
                    } header: { band(section) }
                } else {
                    Section {
                        ForEach(section.rows) { row in
                            InboxRowView(row: row).tag(InboxSelection.thread(row.subject))
                        }
                    } header: { band(section) }
                }
            }
            if !machines.isEmpty {
                Section("Machines") {
                    ForEach(machines) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.agent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(item.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 3)
                        .tag(InboxSelection.machine(item.id))
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func band(_ section: InboxSection) -> some View {
        HStack {
            Text(section.group == .quiet ? section.title : "\(section.title) \u{00B7} \(section.count)")
                .foregroundStyle(section.group == .needsYou ? Theme.attention : .secondary)
            Spacer()
            Text(section.gloss).font(Theme.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

/// One thread's row. The first line is the session's name and how long the thread
/// has waited, marked when it is an hour or more. The second is the kind's chip and
/// one line of what the thread says, which is model text drawn as plain text.
private struct InboxRowView: View {
    let row: InboxRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: row.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                if let age = row.age {
                    Text(age.words).font(Theme.caption.monospacedDigit())
                        .foregroundStyle(age.isOverdue ? Theme.attention : .secondary)
                }
            }
            HStack(spacing: 6) {
                Text(row.kind.chip)
                    .font(Theme.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.tintStrong, in: .rect(cornerRadius: 4))
                Text(verbatim: row.head).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(row.id)
    }
}

/// The pane of an unhealthy machine, which only this app lists. Every session thread
/// is drawn by `InboxPane`.
private struct AttentionDetail: View {
    @Environment(AppModel.self) private var model
    /// What `Mission.attention` holds for the session: its pending approvals, or its
    /// failed run. A machine's is the machine.
    let items: [AttentionItem]
    let row: InboxRow?

    private var sessionID: String? { row?.sessionID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let row {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.kind.chip).font(Theme.caption).foregroundStyle(Theme.attention)
                        Text(verbatim: row.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        HStack(spacing: 8) {
                            if let record = model.sessions.first(where: { $0.id == row.sessionID }),
                               let placement = model.placement(of: record) {
                                Text(placement.label)
                            }
                            if let age = row.age { Text("waiting \(age.words)") }
                        }
                        .font(Theme.meta)
                        .foregroundStyle(.secondary)
                    }
                    if items.isEmpty || !row.isOwnSession {
                        // The thread's own words, drawn as text, never as markup.
                        Text(verbatim: row.head).font(Theme.body).textSelection(.enabled)
                    }
                }

                ForEach(items) { item in
                    AttentionItemBody(item: item)
                }

                if let sessionID {
                    Button("Open Session") { model.destination = .session(sessionID) }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension InboxRow {
    /// Whether the row is a session's own thread, as against an item of its feed.
    fileprivate var isOwnSession: Bool {
        if case .session = subject { return true }
        return false
    }
}

/// One item of `Mission.attention` in the pane: a pending approval with its live
/// card, a failed run's last words, or a sick machine.
struct AttentionItemBody: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem

    var body: some View {
        switch item.source {
        case .session(let sessionID, let escalation):
            if let escalation, let controller = model.controller(for: sessionID) {
                ApprovalCard(record: escalation, controller: controller)
            } else if !item.detail.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(Theme.label)
                    MarkdownView(source: item.detail)
                }
            }
        case .machine:
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.title3.weight(.semibold))
                Text(item.detail).font(Theme.body).textSelection(.enabled)
                Button("Open Machines") { model.destination = .machines }
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: Command palette

/// ⌘K: go anywhere and do anything by typing a few letters. It is the fastest route
/// through the app and the one thing a keyboard user reaches for first.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFocused: Bool

    struct Command: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let liveness: AgentCard.Liveness?
        let hint: String?
        let action: @MainActor () -> Void
    }

    private var commands: [Command] {
        var all: [Command] = [
            .init(id: "new", title: "New Agent", subtitle: "Dispatch work to a new session", icon: "plus", liveness: nil, hint: "⌘N") { model.isDispatching = true },
            .init(id: "inbox", title: "Inbox", subtitle: "\(model.attention.count) waiting", icon: "tray", liveness: nil, hint: "⌘1") { model.destination = .inbox },
            .init(id: "mission", title: "Mission Control", subtitle: "The whole fleet", icon: "square.grid.2x2", liveness: nil, hint: "⌘2") { model.destination = .mission },
            .init(id: "machines", title: "Machines", subtitle: "Where everything runs", icon: "server.rack", liveness: nil, hint: "⌘3") { model.destination = .machines },
            .init(id: "connect", title: "Connect a Daemon", subtitle: "Reach a daemon on another machine", icon: "network", liveness: nil, hint: "⇧⌘N") {
                model.daemonSuggestion = nil
                model.isAddingDaemon = true
            },
            .init(id: "settings", title: "Settings", subtitle: "Daemons and notifications", icon: "gearshape", liveness: nil, hint: "⌘,") { openSettings() },
        ]
        for record in model.sessions {
            let state = Mission.liveness(session: record, activity: model.activity[record.id])
            all.append(.init(
                id: "session/\(record.id)",
                title: record.title,
                subtitle: {
                    if let placement = model.placement(of: record), placement.isSplit { return placement.label }
                    return record.workspaceName
                }(),
                icon: "text.bubble",
                liveness: state,
                hint: nil
            ) { model.destination = .session(record.id) })
        }
        return all
    }

    /// Fuzzy matches, best first. With no query, sessions needing attention lead
    /// and the commands follow, since that is usually why the palette was opened.
    private var results: [Command] {
        guard !query.isEmpty else {
            let rank: (Command) -> Int = { command in
                switch command.liveness {
                case .needsYou?: return 0
                case .working?: return 1
                case nil: return 2
                default: return 3
                }
            }
            return commands.enumerated()
                .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
                .map(\.element)
        }
        return commands
            .compactMap { command -> (Command, Int)? in
                let title = Fuzzy.score(query: query, candidate: command.title)
                let subtitle = Fuzzy.score(query: query, candidate: command.subtitle).map { $0 / 2 }
                guard let score = [title, subtitle].compactMap({ $0 }).max() else { return nil }
                return (command, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        let results = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search sessions and commands", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($isFocused)
                        .onSubmit { run(results) }
                        .accessibilityLabel("Search sessions and commands")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                Divider()

                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.prefix(40).enumerated()), id: \.element.id) { index, command in
                                PaletteRow(command: command, isHighlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture {
                                        highlighted = index
                                        run(results)
                                    }
                            }
                            if results.isEmpty {
                                Text("No matches").foregroundStyle(.secondary).padding(20)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: highlighted) { _, next in reader.scrollTo(next) }
                }
            }
            .frame(width: 580)
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(.top, 72)
        }
        .onAppear { isFocused = true }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlighted = min(max(results.count, 1) - 1, highlighted + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    private func run(_ results: [Command]) {
        guard results.indices.contains(highlighted) else { return }
        let command = results[highlighted]
        close()
        command.action()
    }

    private func close() {
        model.isPaletteOpen = false
    }
}

private struct PaletteRow: View {
    let command: CommandPalette.Command
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let liveness = command.liveness {
                    StatusDot(liveness: liveness)
                } else {
                    Image(systemName: command.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            Text(command.title).font(.system(size: 13)).lineLimit(1)
            Text(command.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if let hint = command.hint {
                Text(hint).font(Theme.meta).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHighlighted ? Color.primary.opacity(0.1) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}
