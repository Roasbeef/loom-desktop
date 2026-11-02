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
    @State private var showsSaved = false

    private var visible: [SessionRecord] {
        model.sessions.filter { record in
            if case .reserved(let failure) = record.state { return failure != nil }
            return true
        }
    }

    private func liveness(_ record: SessionRecord) -> AgentCard.Liveness {
        Mission.liveness(session: record, activity: model.activity[record.id])
    }

    /// Sessions in groups by what they need, by project or by machine. Status is
    /// the default because a person returning to the app asks what needs them.
    private var sections: [(title: String, sessions: [SessionRecord])] {
        switch grouping {
        case .status:
            let order: [(AgentCard.Liveness, String)] = [(.needsYou, "Needs You"), (.working, "Working"), (.idle, "Idle"), (.unknown, "Not Answering")]
            return order.compactMap { state, title in
                let rows = visible.filter { liveness($0) == state }
                return rows.isEmpty ? nil : (title, rows)
            }
        case .project, .machine:
            let key: (SessionRecord) -> String = { record in
                grouping == .project
                    ? record.workspaceName
                    : model.placement(of: record)?.hands ?? "This machine"
            }
            return Dictionary(grouping: visible.filter { liveness($0) != .off }, by: key)
                .map { ($0.key, $0.value) }
                .sorted { $0.title < $1.title }
        }
    }

    private var saved: [SessionRecord] {
        visible.filter { liveness($0) == .off }
    }

    private var groupings: [SidebarGrouping] {
        model.isMultiMachine ? SidebarGrouping.allCases : [.status, .project]
    }

    /// A project heading carries a button that starts a session in that folder.
    @ViewBuilder
    private func sectionHeader(_ title: String, sessions: [SessionRecord]) -> some View {
        let folder = sessions.first { $0.executor == nil && $0.pool == nil }?.workspace
        HStack {
            Text(title)
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
                    ForEach(section.sessions) { record in
                        SessionRow(
                            record: record,
                            activity: model.activity[record.id],
                            placement: model.placement(of: record),
                            ask: model.controller(for: record.id)?.escalations.first?.authorityLines.first,
                            changed: model.daemon(holding: record.id)?.lastChanged[record.id],
                            isUnseen: model.hasUnseenReply(record.id)
                        )
                            .tag(Destination.session(record.id))
                            .sessionContextMenu(record: record)
                    }
                } header: {
                    sectionHeader(section.title, sessions: section.sessions)
                }
            }

            if !saved.isEmpty {
                Section("Saved", isExpanded: $showsSaved) {
                    ForEach(saved) { record in
                        SessionRow(record: record, activity: nil, placement: model.placement(of: record))
                            .tag(Destination.session(record.id))
                            .sessionContextMenu(record: record)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Group by", selection: $grouping) {
                    ForEach(groupings) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                DaemonFooter()
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
    func sessionContextMenu(record: SessionRecord) -> some View {
        modifier(SessionContextMenu(record: record))
    }
}

private struct SessionContextMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let record: SessionRecord

    func body(content: Content) -> some View {
        content.contextMenu {
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
    let record: SessionRecord
    let activity: SessionActivity?
    let placement: Placement?
    var ask: String?
    var changed: Date?
    var isUnseen = false

    private var liveness: AgentCard.Liveness {
        Mission.liveness(session: record, activity: activity)
    }

    /// What the row should say first: the question if it has one, or else the
    /// latest word from the agent.
    private var preview: (text: String, isAsk: Bool)? {
        if let ask {
            return (ask, true)
        }
        guard let line = activity?.lastMessage ?? record.subtitle, line != record.title else { return nil }
        return (Markdown.plainPreview(line), false)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(liveness: liveness)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(record.title)
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
                if let movingTo = record.movingTo {
                    Text("Moving to \(movingTo)").font(Theme.caption).foregroundStyle(Theme.attention)
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
