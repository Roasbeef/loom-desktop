import LoomKit
import MissionKit
import SwiftUI

/// Which machine a detail sheet is about, as one daemon sees it.
struct MachineRef: Identifiable, Equatable {
    let daemonID: String
    let node: DeploymentNode
    var id: String { "\(daemonID)/\(node.id)" }
}

/// One machine in full: its state and declaration, the sessions that depend on it,
/// its scopes, the moves in flight and the commands an operator runs to enroll,
/// renew or revoke it. The commands are shown and never run, because the key that
/// authorizes them belongs on another machine.
struct MachineDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let machine: MachineRef

    @State private var detail: DeploymentNode?
    @State private var abandoning: MoveInFlight?
    @State private var error: String?

    private var daemon: DaemonConnection? { model.daemons.first { $0.id == machine.daemonID } }
    private var node: DeploymentNode { detail ?? machine.node }

    private var dependents: [SessionRecord] {
        guard let daemon else { return [] }
        return daemon.sessions.filter { record in
            machine.node.isSelf || record.executor == machine.node.name || record.executorNode == machine.node.id
        }
    }

    /// A node's own long lists come from a read that names it, which only an
    /// executor or another orchestrator allows; this daemon's own node is whole
    /// already.
    private var canReadDetail: Bool { !machine.node.isSelf }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(machine.node.isSelf ? (daemon?.label ?? machine.node.name) : machine.node.name).font(.headline)
                Text(machine.node.roles.joined(separator: " + ")).font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overview
                    sessions
                    scopes
                    moves
                    access
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.failure).padding(12)
            }
        }
        .frame(width: 560, height: 560)
        .task { await load() }
        .confirmationDialog(
            "Abandon the move of “\(title(of: abandoning?.sessionID))”?",
            isPresented: Binding(get: { abandoning != nil }, set: { if !$0 { abandoning = nil } }),
            titleVisibility: .visible,
            presenting: abandoning
        ) { move in
            Button("Abandon Move", role: .destructive) { abandon(move) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The session stays where it is. Work the destination already copied is discarded.")
        }
    }

    private func title(of sessionID: String?) -> String {
        daemon?.sessions.first { $0.id == sessionID }?.title ?? sessionID ?? ""
    }

    // MARK: Parts

    private var overview: some View {
        part("Overview") {
            fact("State", node.state)
            ForEach(node.reasons, id: \.self) { Text($0).foregroundStyle(Theme.attention) }
            if let version = node.buildVersion { fact("Build", version) }
            if let uptime = node.uptimeMs { fact("Up for", Duration.milliseconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))) }
            if let platform = node.platform { fact("Platform", platform) }
            if let enforcement = node.enforcement { fact("Enforcement", enforcement) }
            if node.roles.contains("executor") {
                // The executor's own report against what this daemon declares for it.
                if let contradiction = node.contradiction {
                    Text(contradiction).foregroundStyle(Theme.attention)
                } else {
                    Text("Its report agrees with the declaration.").foregroundStyle(.secondary)
                }
            }
            if let bytes = node.ledgerBytes, let limit = node.ledgerLimit {
                fact("Ledger", "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))")
            }
            if let link = linkWords { Text(link).foregroundStyle(Theme.attention) }
        }
    }

    /// Whether this daemon reaches the node over its own link, which decides if
    /// anything it says about the node is current.
    private var linkWords: String? {
        guard let edge = daemon?.deployment?.edges.first(where: { $0.to == machine.node.id }), edge.link != "connected" else { return nil }
        return "Not linked from here: \(edge.link)."
    }

    private var sessions: some View {
        part("Sessions") {
            if dependents.isEmpty {
                Text("No session depends on this machine.").foregroundStyle(.secondary)
            }
            ForEach(dependents) { record in
                Button {
                    model.destination = .session(record.id)
                    dismiss()
                } label: {
                    HStack {
                        StatusDot(liveness: Mission.liveness(session: record, activity: daemon?.activity[record.id]))
                        Text(record.title).lineLimit(1)
                        Spacer()
                        Text(record.state.label).font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var scopes: some View {
        if node.roles.contains("executor") {
            part("Scopes") {
                if let open = node.openScopes, let limit = node.scopeLimit {
                    fact("Open", "\(open) of \(limit)")
                }
                if node.unclean.isEmpty {
                    Text("Every closed scope ended cleanly.").foregroundStyle(.secondary)
                }
                ForEach(node.unclean) { scope in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(title(of: scope.sessionID)) · \(scope.state == "closing" ? "still closing" : "did not close cleanly")")
                        Text("It cannot reopen until the scope is released.").font(Theme.caption).foregroundStyle(.secondary)
                        commandBox("Release scope", OperatorCommands.release(session: scope.sessionID))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var moves: some View {
        let moves = daemon?.deployment?.moves ?? []
        if !moves.isEmpty, machine.node.isSelf {
            part("Moves in flight") {
                ForEach(moves) { move in
                    HStack {
                        Text("\(title(of: move.sessionID)) → \(move.destination)")
                        Text(move.reason ?? move.phase).font(Theme.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Abandon…") { abandoning = move }
                            .accessibilityLabel("Abandon move of \(title(of: move.sessionID))")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var access: some View {
        if !machine.node.isSelf {
            part("Access") {
                Text("These run in a terminal on the machine that holds the authority key. The app runs none of them.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                commandBox("Renew its certificate", OperatorCommands.renew(machine.node.name))
                commandBox("Revoke it", OperatorCommands.revoke(machine.node.name))
                if linkWords != nil, let role = machine.node.roles.first(where: { $0 == "executor" || $0 == "orchestrator" }) {
                    commandBox("Enroll it", OperatorCommands.enroll(machine.node.name, node: machine.node.id, role: role, links: daemon?.deployment?.selfName ?? ""))
                }
            }
        }
    }

    // MARK: Pieces

    private func part<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.label)
            content()
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value)
        }
    }

    private func commandBox(_ title: String, _ command: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
            if let command {
                HStack {
                    Text(command).font(Theme.code).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .accessibilityLabel("Copy command: \(title)")
                }
            } else {
                Text("The daemon did not give a name this command could use.").font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Commands

    private func load() async {
        guard canReadDetail, let control = daemon?.control else { return }
        detail = try? await control.deployment(node: machine.node.name).nodes.first
    }

    private func abandon(_ move: MoveInFlight) {
        guard let daemon else { return }
        Task {
            do {
                try await daemon.abandonMove(move.sessionID)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
