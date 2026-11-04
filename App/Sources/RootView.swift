import LoomKit
import Markup
import MissionKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 380)
        } detail: {
            detail
        }
        .overlay {
            if model.isPaletteOpen {
                CommandPalette()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.smooth(duration: 0.14), value: model.isPaletteOpen)
        #if DEBUG
        // Draws controls as a frontmost window does, so a capture can check them
        // without taking focus from whatever a person is doing.
        .environment(\.appearsActive, ProcessInfo.processInfo.environment["LOOM_FORCE_ACTIVE"] != nil ? true : appearsActive)
        .environment(\.controlActiveState, ProcessInfo.processInfo.environment["LOOM_FORCE_ACTIVE"] != nil ? .key : controlActiveState)
        #endif
        .modifier(SessionActionPresenter())
        .sheet(isPresented: $model.isDispatching) {
            DispatchSheet()
        }
        .sheet(isPresented: $model.isAddingDaemon) {
            AddDaemonSheet()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.isDaemonMissing {
            DaemonMissingView()
        } else {
            switch model.destination {
            case .inbox: InboxView()
            case .machines: MachinesView()
            case .session(let id): SessionScreen(sessionID: id).id(id)
            case .mission, nil: MissionControlView()
            }
        }
    }
}

/// The first thing a new person sees when no daemon is running, so it says what to
/// do and offers to do it. Starting the daemon goes through the installed client.
private struct DaemonMissingView: View {
    @Environment(AppModel.self) private var model
    @State private var isStarting = false
    @State private var error: String?

    var body: some View {
        ContentUnavailableView {
            Label("loomd isn't running", systemImage: "bolt.slash")
        } description: {
            VStack(spacing: 6) {
                Text("Loom needs its daemon to run agents. Your sessions are saved and will come back with it.")
                if case .unavailable(let reason)? = model.daemons.first?.state {
                    Text(reason).font(Theme.meta).foregroundStyle(.tertiary)
                }
                if let error {
                    Text(error).foregroundStyle(Theme.failure)
                }
            }
        } actions: {
            Button(isStarting ? "Starting…" : "Start loomd") {
                isStarting = true
                error = nil
                Task {
                    defer { isStarting = false }
                    do {
                        try await model.startDaemon()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isStarting)
        }
    }
}

// MARK: Sidebar

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarGrouping") private var grouping = SidebarGrouping.status
    @AppStorage("sidebarMachine") private var machineFilter = ""
    @AppStorage("sidebarSavedOpen") private var showsSaved = false

    /// A filter for a machine that no longer holds sessions would hide everything.
    private var filter: String? {
        machineFilter.isEmpty || !model.machineCounts.contains { $0.name == machineFilter } ? nil : machineFilter
    }

    private var sections: [SidebarSection] {
        model.sidebarSections(grouping: grouping, machineFilter: filter)
    }

    private var saved: [SidebarRow] {
        model.sidebarSaved(machineFilter: filter)
    }

    private var groupings: [SidebarGrouping] {
        model.isMultiMachine ? SidebarGrouping.allCases : [.status, .project]
    }

    /// A project heading carries a button that starts a session in that folder.
    @ViewBuilder
    private func sectionHeader(_ section: SidebarSection) -> some View {
        let title = section.title
        let folder = section.rows
            .compactMap { row in model.sessions.first { $0.id == row.id } }
            .first { $0.executor == nil && $0.pool == nil }?.workspace
        HStack {
            Text(title)
            Text("\(section.count)").font(Theme.caption).foregroundStyle(.tertiary)
            if grouping == .project, let folder {
                Spacer()
                Button {
                    model.actions.newSessionFolder = folder
                    model.isDispatching = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New session in \(title)")
                .accessibilityLabel("New session in \(title)")
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.destination) {
            Section {
                Label("Inbox", systemImage: "tray")
                    .badge(model.attention.count)
                    .tag(Destination.inbox)
                Label("Mission Control", systemImage: "square.grid.2x2")
                    .tag(Destination.mission)
                if model.isMultiMachine {
                    Label("Machines", systemImage: "server.rack")
                        .tag(Destination.machines)
                }
            }

            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.rows) { row in
                        SessionRow(
                            row: row,
                            activity: model.activity[row.id],
                            placement: model.sessions.first { $0.id == row.id }.flatMap { model.placement(of: $0) },
                            ask: model.controller(for: row.id)?.escalations.first?.authorityLines.first,
                            changed: model.daemon(holding: row.id)?.lastChanged[row.id],
                            isUnseen: model.hasUnseenReply(row.id),
                            groupsByStatus: grouping == .status
                        )
                            .tag(Destination.session(row.id))
                            .sessionContextMenu(id: row.id)
                    }
                } header: {
                    sectionHeader(section)
                }
            }

            if !saved.isEmpty {
                Section("\(saved.count) saved", isExpanded: $showsSaved) {
                    ForEach(saved) { row in
                        SessionRow(row: row, activity: nil, placement: model.sessions.first { $0.id == row.id }.flatMap { model.placement(of: $0) })
                            .tag(Destination.session(row.id))
                            .sessionContextMenu(id: row.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                // An active filter is always on screen, so a shorter list is never
                // mistaken for fewer sessions.
                if let filter {
                    Button {
                        machineFilter = ""
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.split(separator: "@").first.map(String.init) ?? filter)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                        }
                        .font(Theme.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.tintStrong, in: .rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Showing \(filter) only. Click to show every machine.")
                    .accessibilityLabel("Clear machine filter \(filter)")
                }
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    DaemonFooter()
                    SidebarFilterMenu(
                        groupings: groupings,
                        grouping: $grouping,
                        machines: model.isMultiMachine && model.machineCounts.count > 1 ? model.machineCounts : [],
                        total: model.sessions.count,
                        machineFilter: $machineFilter
                    )
                    Button {
                        model.actions.showsPeople = true
                    } label: {
                        Image(systemName: "person.2")
                            .font(Theme.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("The people who can use this daemon, and their sign-ins")
                    .accessibilityLabel("Open People")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .padding(.top, 6)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isDispatching = true
                } label: {
                    Label("New Agent", systemImage: "plus")
                }
                .help("Dispatch a new agent (⌘N)")
            }
        }
    }
}

extension View {
    func sessionContextMenu(id: String) -> some View {
        modifier(SessionContextMenu(id: id))
    }
}

private struct SessionContextMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let id: String

    func body(content: Content) -> some View {
        if let record = model.sessions.first(where: { $0.id == id }) {
            content.contextMenu { menu(for: record) }
        } else {
            content
        }
    }

    @ViewBuilder
    private func menu(for record: SessionRecord) -> some View {
        Group {
            Button("Open in New Window") {
                openWindow(id: "session", value: record.id)
            }
            if record.executor == nil, record.pool == nil {
                Button("Reveal Workspace in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: record.workspace)
                }
            }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.id, forType: .string)
            }
            Divider()
            Button("Rename…") { model.askToRename(record) }
            if record.state.isResident {
                Button("Stop Session") { model.askToStop(record) }
            }
            Button("Archive…") { model.askToArchive(record) }
            if !record.state.isResident {
                Button("Delete…", role: .destructive) { model.askToDelete(record) }
            }
            Button("Share…") { model.actions.sharing = record }
            Button("Move…") { model.askToMove(record) }
        }
    }
}

private struct SessionRow: View {
    let row: SidebarRow
    let activity: SessionActivity?
    let placement: Placement?
    var ask: String?
    var changed: Date?
    var isUnseen = false
    var groupsByStatus = true

    @Environment(AppModel.self) private var model

    private var liveness: AgentCard.Liveness {
        guard let record = model.sessions.first(where: { $0.id == row.id }) else { return .off }
        return Mission.liveness(session: record, activity: activity)
    }

    /// What the row should say first: the question if it has one, or else the
    /// latest word from the agent.
    private var preview: (text: String, isAsk: Bool)? {
        if let ask {
            return (ask, true)
        }
        guard let line = activity?.lastMessage, line != row.title else { return nil }
        return (Markdown.plainPreview(line), false)
    }

    /// Whether where the session stands is worth a word: always when it is failed,
    /// moving or needs attention, and otherwise only when the section heading does
    /// not already say it.
    private var showsStanding: Bool {
        isNotable || !groupsByStatus
    }

    private var isNotable: Bool {
        row.standing.hasPrefix("moving") || row.standing.hasPrefix("failed") || row.standing == "needs attention"
    }

    /// The quiet line: the worktree, and where the session stands when that says
    /// something the heading and the age beside the title do not.
    private var quiet: String {
        [row.worktree, showsStanding ? row.standing : nil].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(liveness: liveness)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title)
                        .lineLimit(1)
                        .fontWeight(isUnseen ? .semibold : .regular)
                    Spacer(minLength: 2)
                    if let changed {
                        Text(changed.compactAge)
                            .font(Theme.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let preview {
                        Text(preview.text)
                            .font(Theme.caption)
                            .foregroundStyle(preview.isAsk ? AnyShapeStyle(Theme.attention) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .truncationMode(preview.isAsk ? .middle : .tail)
                    } else if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let placement, placement.isSplit {
                        Text("→ \(placement.hands)")
                            .font(Theme.meta)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if !quiet.isEmpty {
                    Text(quiet)
                        .font(Theme.caption)
                        .foregroundStyle(isNotable
                            ? AnyShapeStyle(row.standing.hasPrefix("failed") ? Theme.failure : Theme.attention)
                            : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnseen ? "New reply" : "")
    }
}

extension Date {
    /// "4m", "2h", "3d": a sidebar has no room for more, and no need.
    var compactAge: String {
        let seconds = Int(-timeIntervalSinceNow)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

/// How the sidebar groups and which machine it shows, behind one button beside
/// the daemon line. Both are set rarely, so they cost no rows of their own; an
/// active machine filter is shown above the button as a removable chip.
private struct SidebarFilterMenu: View {
    let groupings: [SidebarGrouping]
    @Binding var grouping: SidebarGrouping
    let machines: [(name: String, count: Int)]
    let total: Int
    @Binding var machineFilter: String

    var body: some View {
        Menu {
            Picker("Group By", selection: $grouping) {
                ForEach(groupings) { Text($0.rawValue).tag($0) }
            }
            if !machines.isEmpty {
                Picker("Machine", selection: $machineFilter) {
                    Text("All Machines (\(total))").tag("")
                    ForEach(machines, id: \.name) { machine in
                        Text("\(machine.name.split(separator: "@").first.map(String.init) ?? machine.name) (\(machine.count))")
                            .tag(machine.name)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(Theme.caption)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Group and filter the sessions")
        .accessibilityLabel("Group and Filter")
    }
}

/// What each daemon itself is doing, which no per-session view can say.
private struct DaemonFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(model.daemons) { daemon in
                switch daemon.state {
                case .connected:
                    HStack(spacing: 6) {
                        if let status = daemon.status {
                            CapacityMeter(used: status.resident, capacity: status.capacity)
                        }
                        Text(model.daemons.count > 1 ? daemon.label : "\(daemon.status?.resident ?? 0) of \(daemon.status?.capacity ?? 0) slots")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let deployment = daemon.deployment, deployment.isDistributed, deployment.state != "ok" {
                            Text(deployment.state).foregroundStyle(Theme.attention)
                        }
                    }
                case .connecting:
                    Text("Connecting to \(daemon.label)…")
                case .unavailable:
                    Text("\(daemon.label) unavailable").foregroundStyle(Theme.failure).lineLimit(1)
                }
            }
        }
        .font(Theme.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CapacityMeter: View {
    let used: Int
    let capacity: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<min(max(capacity, 0), 16), id: \.self) { slot in
                RoundedRectangle(cornerRadius: 1)
                    .fill(slot < used ? Color.primary.opacity(0.65) : Color.primary.opacity(0.12))
                    .frame(width: 4, height: 9)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(used) of \(capacity) session slots in use")
    }
}
