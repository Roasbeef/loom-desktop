import LoomKit
import MissionKit
import SwiftUI

/// Every machine each connected daemon knows of, and what depends on it.
///
/// Each statement is as seen from the daemon that answered, so the view is
/// grouped by that daemon rather than presenting one merged truth.
struct MachinesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(model.daemons) { daemon in
                    DaemonSection(daemon: daemon)
                }
                let elsewhere = model.elsewhere
                if !elsewhere.isEmpty {
                    ElsewhereSection(groups: elsewhere)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Machines")
        .toolbar {
            ToolbarItem {
                Button {
                    model.daemonSuggestion = nil
                    model.isAddingDaemon = true
                } label: {
                    Label("Connect a daemon", systemImage: "plus")
                }
                .help("Connect to a daemon on another machine (⇧⌘N)")
            }
        }
    }
}

private struct DaemonSection: View {
    @Environment(AppModel.self) private var model
    let daemon: DaemonConnection

    @ViewBuilder
    private func nodeGroup(_ title: String, _ nodes: [DeploymentNode]) -> some View {
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Theme.label).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(nodes) { node in
                        NodeCard(node: node, daemon: daemon)
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(daemon.label).font(.headline)
                Text(daemon.isRemote ? "connected daemon" : "this Mac's daemon")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if daemon.isRemote {
                    Button("Disconnect") { model.removeDaemon(daemon) }
                        .buttonStyle(.link)
                }
            }

            switch daemon.state {
            case .connecting:
                ProgressView().controlSize(.small)
            case .unavailable(let reason):
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(Theme.failure)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surface(fill: Theme.failure.opacity(0.08))
            case .connected:
                if let deployment = daemon.deployment {
                    if !deployment.omitted.isEmpty {
                        Text("Some detail was left out to fit one reply: \(deployment.omitted.joined(separator: ", ")).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Orchestrators decide and executors act, so they read as two groups.
                    let orchestrators = deployment.nodes.filter { $0.roles.contains("orchestrator") || $0.roles.isEmpty }
                    let executors = deployment.nodes.filter { $0.roles.contains("executor") && !$0.roles.contains("orchestrator") }
                    nodeGroup("Orchestrators", orchestrators)
                    nodeGroup("Executors", executors)
                    if !deployment.pools.isEmpty {
                        PoolsGroup(pools: deployment.pools)
                    }
                } else {
                    Text("This daemon does not report a deployment.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct NodeCard: View {
    @Environment(AppModel.self) private var model
    let node: DeploymentNode
    let daemon: DaemonConnection

    /// The sessions whose tools or conversation this machine carries.
    private var dependents: [SessionRecord] {
        daemon.sessions.filter { record in
            if node.isSelf { return true }
            return record.executor == node.name || record.executorNode == node.id
        }
    }

    private var color: Color {
        switch node.state {
        case "ok": return .secondary
        case "degraded": return Theme.attention
        default: return Theme.failure
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(node.isSelf ? daemon.label : node.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(rolesLabel).font(Theme.caption).foregroundStyle(.secondary)
            }

            // A healthy machine shows no words about its health.
            if node.state != "ok" {
                Text(node.reasons.isEmpty ? node.state : node.reasons.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(color)
            }

            if let edge = daemon.deployment?.edges.first(where: { $0.to == node.id }), edge.link != "connected" {
                Text("Not linked from here: \(edge.link)").font(.callout).foregroundStyle(Theme.attention)
            }

            let facts = [node.platform, node.enforcement, node.buildVersion.map { "build \($0)" }].compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · ")).font(Theme.meta).foregroundStyle(.secondary).lineLimit(1)
            }

            if let resident = node.resident, let capacity = node.capacity {
                meter(label: "\(resident) of \(capacity) session slots", used: resident, capacity: capacity)
            }
            if let open = node.openScopes, let limit = node.scopeLimit {
                meter(label: "\(open) of \(limit) scopes", used: open, capacity: limit)
            }

            Button("Details") { model.actions.machine = MachineRef(daemonID: daemon.id, node: node) }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityLabel("Details for \(node.isSelf ? daemon.label : node.name)")

            if !dependents.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(dependents.prefix(5)) { record in
                        Button {
                            model.destination = .session(record.id)
                        } label: {
                            HStack(spacing: 6) {
                                StatusDot(liveness: Mission.liveness(session: record, activity: daemon.activity[record.id]))
                                Text(record.title).lineLimit(1)
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.plain)
                    }
                    if dependents.count > 5 {
                        Button("\(dependents.count - 5) more") { model.destination = .mission }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(fill: node.state == "ok" ? Theme.tint : color.opacity(0.07))
    }

    private var rolesLabel: String {
        node.roles.isEmpty ? "standalone" : node.roles.joined(separator: " + ")
    }

    private func meter(label: String, used: Int, capacity: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule()
                        .fill(Color.secondary)
                        .frame(width: capacity > 0 ? geometry.size.width * min(1, Double(used) / Double(capacity)) : 0)
                }
            }
            .frame(height: 3)
            Text(used >= capacity ? "\(label), full" : label).font(Theme.caption).foregroundStyle(.secondary)
        }
    }
}

/// The pools a session may be placed in, with the state each reports.
private struct PoolsGroup: View {
    let pools: [PlacementOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pools").font(Theme.label).foregroundStyle(.secondary)
            ForEach(pools) { pool in
                HStack(spacing: 8) {
                    Text(pool.name).font(.system(size: 13, weight: .semibold))
                    Text(pool.state).font(Theme.caption).foregroundStyle(pool.state == "ready" ? Color.secondary : Theme.attention)
                    if let platform = pool.platform { Text(platform).font(Theme.meta).foregroundStyle(.secondary) }
                    if let free = pool.freeScopes { Text("\(free) free").font(Theme.caption).foregroundStyle(.secondary) }
                    if !pool.members.isEmpty { Text(pool.members.joined(separator: ", ")).font(Theme.meta).foregroundStyle(.secondary) }
                    Spacer()
                }
                .padding(12)
                .surface()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pool \(pool.name), \(pool.state)")
            }
        }
    }
}

/// Sessions held by orchestrators this app has no connection to.
///
/// Driving one takes a connection and a credential for its own daemon, since the
/// daemon that listed it does not forward a client.
private struct ElsewhereSection: View {
    @Environment(AppModel.self) private var model
    let groups: [ElsewhereGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On other orchestrators").font(.headline)
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(group.name).font(.system(size: 13, weight: .semibold))
                        Text(group.node).font(Theme.meta).foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect…") {
                            model.daemonSuggestion = (group.name, group.address ?? "")
                            model.isAddingDaemon = true
                        }
                        .buttonStyle(.link)
                    }

                    // Silent is never the same as having no sessions.
                    if !group.answered {
                        Text("Did not answer, so its sessions are unknown.")
                            .font(.callout)
                            .foregroundStyle(Theme.attention)
                    } else if group.sessions.isEmpty {
                        Text("No sessions.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(group.sessions) { record in
                        HStack(spacing: 8) {
                            Text(record.title).lineLimit(1)
                            Text(record.state.label).font(Theme.meta).foregroundStyle(.secondary)
                            if let executor = record.executorNode ?? record.executor {
                                Text("→ \(executor)").font(Theme.meta).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            let launch = LaunchWords.line(address: group.address, session: record.id)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(launch, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .help("Copy: \(launch)")
                            .accessibilityLabel("Copy launch command for \(record.title)")
                        }
                        .font(.callout)
                    }
                    if group.hasMore {
                        Text("More sessions are listed on that machine.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface()
            }
        }
    }
}

/// Connects a daemon on another machine.
struct AddDaemonSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var token = ""
    @State private var error: String?
    @State private var isClaiming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect a daemon").font(.headline)
            Text("A daemon listens on its own loopback address, so reach it through Tailscale Serve, a TLS proxy or an SSH tunnel.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name, such as box", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Daemon name")
            TextField("wss://box.example.ts.net or ws://127.0.0.1:7441", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Daemon address")
            SecureField("Credential or claim token for that daemon", text: $token)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Credential")
            Text(Claim.isClaimToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
                 ? "A claim token is exchanged once for a credential that only this app holds."
                 : "The credential is kept in your login keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error {
                Text(error).font(.callout).foregroundStyle(Theme.failure)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isClaiming ? "Claiming…" : "Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(name.isEmpty || address.isEmpty || token.isEmpty || isClaiming)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let suggestion = model.daemonSuggestion {
                name = suggestion.name
                address = suggestion.address
            }
        }
    }

    private func connect() {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Claim.isClaimToken(given) else {
            do {
                try model.addDaemon(name: name, address: address, token: given)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            return
        }

        // The credential is drawn here and kept before the daemon hears its digest,
        // so a reply that never arrives can be recovered by claiming again.
        let credential = Claim.newCredential()
        isClaiming = true
        error = nil
        Task {
            defer { isClaiming = false }
            do {
                try await model.claimDaemon(name: name, address: address, claim: given, credential: credential)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
