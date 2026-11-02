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
        NavigationSplitView {
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
            .buttonStyle(.glassProminent)
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
                Section(section.title) {
                    ForEach(section.sessions) { record in
                        SessionRow(record: record, activity: model.activity[record.id], placement: model.placement(of: record))
                            .tag(Destination.session(record.id))
                            .sessionContextMenu(record: record)
                    }
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
            if record.state.isResident {
                Divider()
                Button("Stop Session") {
                    Task { try? await model.daemon(holding: record.id)?.stop(record.id) }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let record: SessionRecord
    let activity: SessionActivity?
    let placement: Placement?

    private var liveness: AgentCard.Liveness {
        Mission.liveness(session: record, activity: activity)
    }

    private var preview: String? {
        guard let line = activity?.lastMessage ?? record.subtitle, line != record.title else { return nil }
        return Markdown.plainPreview(line)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(liveness: liveness)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(record.title).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(record.createdAt.compactAge)
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                if let preview {
                    Text(preview)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let placement, placement.isSplit {
                    Label(placement.hands, systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let movingTo = record.movingTo {
                    Text("Moving to \(movingTo)").font(Theme.meta).foregroundStyle(Theme.attention)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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
                        Text(model.daemons.count > 1 ? daemon.label : "\(daemon.status?.resident ?? 0) of \(daemon.status?.capacity ?? 0) running")
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
        .font(Theme.meta)
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

// MARK: Dispatch

/// The new-agent form. The prompt comes first because it is why a person opened it,
/// and where it runs defaults to the last choice so a repeat takes one keystroke.
///
/// With executors configured, a person also chooses where the tools run, and the
/// workspace becomes a name that machine registered, since a path here means
/// nothing on that machine.
struct DispatchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastWorkspace") private var lastWorkspace = ""
    @State private var daemonID = "local"
    @State private var placement = PlacementChoice.local
    @State private var workspace = ""
    @State private var remoteWorkspaces: [String] = []
    @State private var configuration = ""
    @State private var prompt = ""
    @State private var error: String?
    @State private var isSending = false
    @FocusState private var isPromptFocused: Bool

    // Held across attempts so a retry after a lost reply recovers the session
    // the first attempt made rather than creating a second one.
    @State private var requestKey = UUID().uuidString

    private var daemon: DaemonConnection? {
        model.daemons.first { $0.id == daemonID } ?? model.daemons.first
    }

    private var options: [PlacementOption] {
        (daemon?.deployment?.executors ?? []) + (daemon?.deployment?.pools ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("What should this agent do?", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(4...14)
                .focused($isPromptFocused)
                .padding(18)
                .accessibilityLabel("Prompt")

            Divider()

            Form {
                if model.daemons.count > 1 {
                    Picker("Agent runs on", selection: $daemonID) {
                        ForEach(model.daemons) { Text($0.label).tag($0.id) }
                    }
                }
                if !options.isEmpty {
                    Picker("Tools run on", selection: $placement) {
                        Text(daemon?.label ?? "This machine").tag(PlacementChoice.local)
                        ForEach(options) { option in
                            Text(describe(option))
                                .tag(option.choice)
                                .selectionDisabled(option.state == "down" || option.state == "full")
                        }
                    }
                }
                workspaceField
                if daemon?.isRemote == true {
                    // A configuration path is read on the machine holding the session.
                    TextField("Configuration", text: $configuration, prompt: Text("Path on that machine"))
                        .font(.system(size: 12).monospaced())
                }
            }
            .formStyle(.columns)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if let error {
                Text(error)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.failure)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Text("⌘↩ to dispatch").font(Theme.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSending ? "Dispatching…" : "Dispatch", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.glassProminent)
                    .disabled(isSending || workspace.isEmpty || prompt.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 580)
        .onAppear {
            isPromptFocused = true
            workspace = lastWorkspace
        }
        .onChange(of: daemonID) {
            placement = .local
            workspace = ""
            requestKey = UUID().uuidString
        }
        .onChange(of: placement) {
            // Changing where it runs changes what the workspace field means.
            workspace = ""
            requestKey = UUID().uuidString
        }
        .task(id: placement) {
            remoteWorkspaces = []
            if case .executor(let name) = placement, let daemon {
                remoteWorkspaces = await daemon.workspaces(onExecutor: name)
                workspace = remoteWorkspaces.first ?? ""
            }
        }
    }

    @ViewBuilder
    private var workspaceField: some View {
        switch placement {
        case .local:
            LabeledContent("Workspace") {
                HStack(spacing: 6) {
                    TextField("Workspace", text: $workspace, prompt: Text("/path/to/project"))
                        .labelsHidden()
                        .font(.system(size: 12).monospaced())
                    if let daemon, !model.knownWorkspaces(on: daemon).isEmpty {
                        Menu {
                            ForEach(model.knownWorkspaces(on: daemon), id: \.self) { path in
                                Button(path) { workspace = path }
                            }
                        } label: {
                            Image(systemName: "clock")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Recent workspaces")
                        .accessibilityLabel("Recent workspaces")
                    }
                    if daemon?.isRemote != true {
                        Button("Choose…", action: choose)
                    }
                }
            }
        case .executor where !remoteWorkspaces.isEmpty:
            Picker("Workspace", selection: $workspace) {
                ForEach(remoteWorkspaces, id: \.self) { Text($0).tag($0) }
            }
        case .executor, .pool:
            TextField("Workspace", text: $workspace, prompt: Text("Name registered on that machine"))
                .font(.system(size: 12).monospaced())
        }
    }

    private func describe(_ option: PlacementOption) -> String {
        var parts = [option.name]
        if case .pool = option.choice { parts.append("pool") }
        if let platform = option.platform { parts.append(platform) }
        if let free = option.freeScopes, option.state == "ready" { parts.append("\(free) free") }
        if option.state != "ready" { parts.append(option.state) }
        return parts.joined(separator: " · ")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            workspace = url.path
        }
    }

    private func send() {
        guard let daemon, !workspace.isEmpty, !prompt.isEmpty else { return }
        isSending = true
        error = nil
        let firstLine = prompt.split(separator: "\n").first.map { String($0.prefix(60)) } ?? ""

        // The same configuration the terminal falls back to with no --config.
        let path = daemon.localRoot?.appendingPathComponent("loom.toml").path ?? configuration
        Task {
            defer { isSending = false }
            do {
                let id = try await daemon.dispatch(
                    workspace: workspace,
                    name: firstLine,
                    prompt: prompt,
                    placement: placement,
                    configuration: path,
                    requestKey: requestKey
                )
                if placement == .local { lastWorkspace = workspace }
                model.destination = .session(id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
