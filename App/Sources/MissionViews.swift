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
        .toolbar {
            ToolbarItem(placement: .status) {
                HStack(spacing: 10) {
                    ForEach(model.daemons) { daemon in
                        if let status = daemon.status {
                            HStack(spacing: 6) {
                                CapacityMeter(used: status.resident, capacity: status.capacity)
                                Text(model.daemons.count > 1 ? "\(daemon.label) \(status.resident)/\(status.capacity)" : "\(status.resident) of \(status.capacity) slots")
                                    .font(Theme.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
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

/// One place to answer everything, grouped by what each item needs. The list keeps
/// focus, so a person can move down it and answer with the keyboard.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AttentionItem.ID?

    var body: some View {
        let items = model.attention
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing needs you", systemImage: "checkmark.circle")
                        .symbolRenderingMode(.hierarchical)
                } description: {
                    Text("Approvals, failed runs and unhealthy machines will appear here.")
                }
            } else {
                HStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(AttentionItem.Kind.allCases, id: \.self) { kind in
                            let group = items.filter { $0.kind == kind }
                            if !group.isEmpty {
                                Section(kind.title) {
                                    ForEach(group) { item in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.agent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text(item.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        .padding(.vertical, 3)
                                        .tag(item.id)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(width: 320)

                    Divider()

                    if let item = items.first(where: { $0.id == selection }) ?? items.first {
                        AttentionDetail(item: item)
                            .id(item.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Inbox")
        .navigationSubtitle(items.isEmpty ? "" : "\(items.count) waiting")
    }
}

private struct AttentionDetail: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem

    private var sessionRecord: SessionRecord? {
        if case .session(let id, _) = item.source {
            return model.sessions.first { $0.id == id }
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.kind.title).font(Theme.caption).foregroundStyle(Theme.attention)
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(item.agent)
                        if let record = sessionRecord, let placement = model.placement(of: record) {
                            Text("· \(placement.label)")
                        }
                    }
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                }

                switch item.source {
                case .session(let sessionID, let escalation):
                    if let escalation, let controller = model.controller(for: sessionID) {
                        ApprovalCard(record: escalation, controller: controller)
                    } else if !item.detail.isEmpty {
                        MarkdownView(source: item.detail)
                    }
                    Button("Open Session") { model.destination = .session(sessionID) }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.return, modifiers: .command)
                case .machine:
                    Text(item.detail).font(Theme.body).textSelection(.enabled)
                    Button("Open Machines") { model.destination = .machines }
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
