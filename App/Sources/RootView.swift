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
            case .session(let id): SessionScreen(sessionID: id).id(id)
            case .mission, nil: MissionControlView()
            }
        }
        .sheet(isPresented: $model.isDispatching) {
            DispatchSheet()
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private var groups: [(workspace: String, sessions: [SessionRecord])] {
        let visible = model.sessions.filter { record in
            if case .reserved(let failure) = record.state { return failure != nil }
            return true
        }
        return Dictionary(grouping: visible, by: \.workspaceName)
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
            }

            ForEach(groups, id: \.workspace) { group in
                Section(group.workspace) {
                    ForEach(group.sessions) { record in
                        SessionRow(record: record, activity: model.activity[record.id])
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

    private var liveness: AgentCard.Liveness {
        switch activity?.state {
        case .needsYou: return .needsYou
        case .working: return .working
        case .idle, .unknown: return .idle
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
            }
        }
    }
}

/// What the daemon itself is doing, which no per-session view can say.
private struct DaemonFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.connection {
            case .connected:
                if let status = model.status {
                    HStack(spacing: 6) {
                        CapacityMeter(used: status.resident, capacity: status.capacity)
                        Text("\(status.resident)/\(status.capacity) running")
                    }
                }
                HStack(spacing: 6) {
                    Text("loomd \(model.hello?.buildVersion ?? "")")
                    Text(model.substrateOnline ? "· substrate" : "")
                }
            case .connecting:
                Text("Connecting to loomd…")
            case .unavailable(let reason):
                Text("loomd unavailable").foregroundStyle(Theme.failure)
                Text(reason).lineLimit(2)
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
private struct DispatchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = ""
    @State private var name = ""
    @State private var prompt = ""
    @State private var error: String?
    @State private var isSending = false

    // Held across attempts so a retry after a lost reply recovers the session
    // the first attempt made rather than creating a second one.
    @State private var requestKey = UUID().uuidString

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dispatch an agent").font(.headline)

            HStack {
                TextField("Workspace path", text: $workspace)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if !model.knownWorkspaces.isEmpty {
                    Menu("Recent") {
                        ForEach(model.knownWorkspaces, id: \.self) { path in
                            Button(path) { workspace = path }
                        }
                    }
                    .fixedSize()
                }
                Button("Choose…", action: choose)
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
        isSending = true
        error = nil
        Task {
            defer { isSending = false }
            do {
                try await model.dispatch(workspace: workspace, name: name, prompt: prompt, requestKey: requestKey)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
