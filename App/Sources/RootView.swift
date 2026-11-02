import LoomKit
import MissionKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            switch model.destination {
            case .inbox: InboxView()
            case .machines: MachinesView()
            case .session(let id): SessionScreen(sessionID: id).id(id)
            case .mission, nil: MissionControlView()
            }
        }
        .sheet(isPresented: $model.isDispatching) {
            DispatchSheet()
        }
        .sheet(isPresented: $model.isAddingDaemon) {
            AddDaemonSheet()
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarGrouping") private var grouping = SidebarGrouping.project

    private func groupName(_ record: SessionRecord) -> String {
        switch grouping {
        case .project: return record.workspaceName
        case .machine: return model.placement(of: record)?.hands ?? record.workspaceName
        }
    }

    private var groups: [(workspace: String, sessions: [SessionRecord])] {
        let visible = model.sessions.filter { record in
            if case .reserved(let failure) = record.state { return failure != nil }
            return true
        }
        return Dictionary(grouping: visible, by: groupName)
            .map { ($0.key, $0.value) }
            .sorted { lhs, rhs in
                (lhs.sessions.first?.createdAt ?? .distantPast) > (rhs.sessions.first?.createdAt ?? .distantPast)
            }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.destination) {
            Section {
                Label {
                    HStack {
                        Text("Inbox")
                        Spacer()
                        let count = model.attention.count
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(Theme.attention)
                        }
                    }
                } icon: {
                    Image(systemName: "tray")
                }
                .tag(Destination.inbox)

                Label("Mission Control", systemImage: "square.grid.2x2")
                    .tag(Destination.mission)

                // A person on one machine has no use for this page.
                if model.isMultiMachine {
                    Label("Machines", systemImage: "server.rack")
                        .tag(Destination.machines)
                }
            }

            if model.isMultiMachine {
                Picker("Group by", selection: $grouping) {
                    ForEach(SidebarGrouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowSeparator(.hidden)
            }

            ForEach(groups, id: \.workspace) { group in
                Section(group.workspace) {
                    ForEach(group.sessions) { record in
                        SessionRow(
                            record: record,
                            activity: model.activity[record.id],
                            placement: model.placement(of: record)
                        )
                            .tag(Destination.session(record.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { DaemonFooter() }
        .toolbar {
            ToolbarItem {
                Button {
                    model.isDispatching = true
                } label: {
                    Label("Dispatch Agent", systemImage: "square.and.pencil")
                }
                .help("Dispatch an agent (⌘N)")
            }
        }
    }
}

private struct SessionRow: View {
    let record: SessionRecord
    let activity: SessionActivity?
    let placement: Placement?

    private var liveness: AgentCard.Liveness {
        switch activity?.state {
        case .needsYou: return .needsYou
        case .working: return .working
        case .idle: return .idle
        case .unknown: return .unknown
        case nil: return record.state.isResident ? .idle : .off
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(liveness: liveness)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title).lineLimit(1)
                if let line = activity?.lastMessage ?? record.subtitle, line != record.title {
                    // Markdown markers are noise in a one-line preview.
                    Text(line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let placement, placement.isSplit {
                    Text(placement.label)
                        .font(Theme.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let movingTo = record.movingTo {
                    Text("Moving to \(movingTo)").font(Theme.meta).foregroundStyle(Theme.attention)
                }
            }
        }
    }
}

/// What each daemon itself is doing, which no per-session view can say.
private struct DaemonFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.daemons) { daemon in
                VStack(alignment: .leading, spacing: 3) {
                    switch daemon.state {
                    case .connected:
                        HStack(spacing: 6) {
                            if let status = daemon.status {
                                CapacityMeter(used: status.resident, capacity: status.capacity)
                            }
                            Text(model.daemons.count > 1 ? daemon.label : "\(daemon.status?.resident ?? 0)/\(daemon.status?.capacity ?? 0) running")
                                .lineLimit(1)
                        }
                        if let deployment = daemon.deployment, deployment.isDistributed, deployment.state != "ok" {
                            Text("Deployment \(deployment.state)").foregroundStyle(Theme.attention)
                        }
                    case .connecting:
                        Text("Connecting to \(daemon.label)…")
                    case .unavailable(let reason):
                        Text("\(daemon.label) unavailable").foregroundStyle(Theme.failure)
                        Text(reason).lineLimit(2)
                    }
                }
            }
            HStack(spacing: 6) {
                Text("loomd \(model.daemons.first?.hello?.buildVersion ?? "")")
            }
        }
        .font(Theme.meta)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

struct CapacityMeter: View {
    let used: Int
    let capacity: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<max(capacity, 0), id: \.self) { slot in
                RoundedRectangle(cornerRadius: 1)
                    .fill(slot < used ? Theme.working : Theme.hairline)
                    .frame(width: 5, height: 9)
            }
        }
        .accessibilityLabel("\(used) of \(capacity) session slots in use")
    }
}

/// The new-agent form: where to run and what to do, and nothing more.
///
/// A person on one machine sees a path and a prompt. With executors configured,
/// they also choose where the tools run, and the workspace becomes a name that
/// machine registered, since a path here means nothing on that machine.
private struct DispatchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var daemonID = "local"
    @State private var placement = PlacementChoice.local
    @State private var workspace = ""
    @State private var remoteWorkspaces: [String] = []
    @State private var configuration = ""
    @State private var name = ""
    @State private var prompt = ""
    @State private var error: String?
    @State private var isSending = false

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
        VStack(alignment: .leading, spacing: 14) {
            Text("Dispatch an agent").font(.headline)

            if model.daemons.count > 1 {
                LabeledContent("Agent runs on") {
                    Picker("Agent runs on", selection: $daemonID) {
                        ForEach(model.daemons) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                }
            }

            if !options.isEmpty {
                LabeledContent("Tools run on") {
                    Picker("Tools run on", selection: $placement) {
                        Text(daemon?.label ?? "This machine").tag(PlacementChoice.local)
                        ForEach(options) { option in
                            Text(describe(option))
                                .tag(option.choice)
                                .selectionDisabled(option.state == "down" || option.state == "full")
                        }
                    }
                    .labelsHidden()
                }
            }

            workspaceField

            if daemon?.isRemote == true {
                // A configuration path is read on the machine that holds the session.
                TextField("Configuration path on that machine", text: $configuration)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 120)
                .surface()
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("What should this agent do?")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            if let error {
                Text(error).font(.callout).foregroundStyle(Theme.failure)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSending ? "Dispatching…" : "Dispatch", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending || workspace.isEmpty || prompt.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: daemonID) {
            placement = .local
            workspace = ""
            requestKey = UUID().uuidString
        }
        .task(id: placement) {
            // Changing where it runs changes what the workspace field means.
            workspace = ""
            requestKey = UUID().uuidString
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
            HStack {
                TextField("Workspace path", text: $workspace)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let daemon, !model.knownWorkspaces(on: daemon).isEmpty {
                    Menu("Recent") {
                        ForEach(model.knownWorkspaces(on: daemon), id: \.self) { path in
                            Button(path) { workspace = path }
                        }
                    }
                    .fixedSize()
                }
                if daemon?.isRemote != true {
                    Button("Choose…", action: choose)
                }
            }
        case .executor where !remoteWorkspaces.isEmpty:
            LabeledContent("Workspace") {
                Picker("Workspace", selection: $workspace) {
                    ForEach(remoteWorkspaces, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
        case .executor, .pool:
            TextField("Workspace name registered on that machine", text: $workspace)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func describe(_ option: PlacementOption) -> String {
        var parts = [option.name]
        if case .pool = option.choice { parts.append("pool") }
        if let platform = option.platform { parts.append(platform) }
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
        guard let daemon else { return }
        isSending = true
        error = nil

        // The same configuration the terminal falls back to with no --config.
        let path = daemon.localRoot?.appendingPathComponent("loom.toml").path ?? configuration
        Task {
            defer { isSending = false }
            do {
                let id = try await daemon.dispatch(
                    workspace: workspace,
                    name: name,
                    prompt: prompt,
                    placement: placement,
                    configuration: path,
                    requestKey: requestKey
                )
                model.destination = .session(id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
