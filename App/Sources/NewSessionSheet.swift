import LoomKit
import SwiftUI

extension AppModel {
    /// Folders this daemon's local sessions used, newest first, minus any a person
    /// asked to forget. Forgetting hides the folder from this list only; the
    /// sessions that used it stay.
    func recentPlaces(on daemon: DaemonConnection, forgotten: Set<String>) -> [String] {
        var newest: [String: Date] = [:]
        for record in daemon.sessions where record.executor == nil && record.pool == nil {
            newest[record.workspace] = max(newest[record.workspace] ?? .distantPast, record.createdAt)
        }
        return newest.sorted { $0.value > $1.value }.map(\.key).filter { !forgotten.contains($0) }
    }
}

extension DaemonConnection {
    /// The profiles and models this daemon's configuration defines, which only a
    /// local daemon's file can be read for.
    var configurationChoices: ConfigurationChoices {
        guard let root = localRoot else { return ConfigurationChoices() }
        return ConfigurationChoices.read(at: root.appendingPathComponent("loom.toml"))
    }
}

/// Starts a session: what it should do first, where, with which models, and whether
/// others can join it. The prompt comes first because it is why a person opened the
/// form, and the place defaults to the last choice so a repeat takes one keystroke.
///
/// The folder field doubles as a search over the places already used, since a person
/// who has worked in a folder once usually wants it again. The form judges a typed
/// folder while it is typed, so a mistake is named before any request is made.
struct DispatchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastWorkspace") private var lastWorkspace = ""
    @AppStorage("forgottenFolders") private var forgottenText = ""
    @State private var daemonID = "local"
    @State private var placement = PlacementChoice.local
    @State private var workspace = ""
    @State private var remoteWorkspaces: [String] = []
    @State private var configuration = ""
    @State private var prompt = ""
    @State private var name = ""
    @State private var profile = ""
    @State private var modelKey = ""
    @State private var isShareable = false
    @State private var error: String?
    @State private var createdID: String?
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

    private var forgotten: Set<String> {
        Set(forgottenText.split(separator: "\n").map(String.init))
    }

    private var choices: ConfigurationChoices {
        daemon?.configurationChoices ?? ConfigurationChoices()
    }

    /// A typed local folder is judged here. A remote daemon's folders and an
    /// executor's registered names mean nothing on this machine, so the daemon
    /// judges those.
    private var folderJudgement: FolderCheck {
        guard placement == .local, daemon?.isRemote != true else { return workspace.isEmpty ? .empty : .ok(workspace) }
        return FolderCheck.judge(workspace)
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
                    ChoicePicker(
                        title: "Agent runs on",
                        selection: $daemonID,
                        options: model.daemons.map { (describe($0), $0.id) }
                    )
                }
                if !options.isEmpty {
                    ChoicePicker(
                        title: "Tools run on",
                        selection: $placement,
                        options: [(daemon?.isRemote == true ? daemon?.label ?? "That machine" : "This Mac", PlacementChoice.local)]
                            + options.map { (describe($0), $0.choice) }
                    )
                    if case .executor(let name) = placement, let option = options.first(where: { $0.choice == .executor(name) }), option.state == "down" {
                        // A down machine may still be chosen: the session waits for it.
                        Text("\(name) is down. The session will wait until it is back.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.attention)
                    }
                }
                workspaceField
                TextField("Name", text: $name, prompt: Text("The first line of your message"))
                    .accessibilityLabel("Session name")
                if !choices.profiles.isEmpty {
                    ChoicePicker(title: "Model profile", selection: $profile, options: [("Default", "")] + choices.profiles.map { ($0, $0) })
                }
                if !choices.models.isEmpty {
                    ChoicePicker(title: "Main model", selection: $modelKey, options: [(profile.isEmpty ? "Default" : "From profile", "")] + choices.models.map { ($0, $0) })
                }
                Toggle("Shareable", isOn: $isShareable)
                    .accessibilityLabel("Shareable")
                Text(isShareable
                     ? "People you invite can read this session. Its memory stays inside it."
                     : "Private. To invite someone later you have to make it shareable, which shares what is already said.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                if daemon?.isRemote == true {
                    // A configuration path is read on the machine holding the session.
                    TextField("Configuration", text: $configuration, prompt: Text("Path on that machine"))
                        .font(.system(size: 12).monospaced())
                        .accessibilityLabel("Configuration")
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
                    .textSelection(.enabled)
            }
            if let createdID {
                Button("Open the session") {
                    model.destination = .session(createdID)
                    dismiss()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Text(dispatchHint).font(Theme.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSending ? "Dispatching…" : "Dispatch", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending || createdID != nil || workspace.isEmpty || prompt.isEmpty || (!folderJudgement.isUsable && placement == .local && daemon?.isRemote != true))
            }
            .padding(14)
        }
        .frame(width: 580)
        .onAppear {
            isPromptFocused = true
            // A remembered folder that has since gone away is a mistake to avoid
            // offering, so it is dropped rather than shown with an error.
            workspace = model.actions.newSessionFolder ?? (FolderCheck.judge(lastWorkspace).isUsable ? lastWorkspace : "")
            model.actions.newSessionFolder = nil
        }
        .onChange(of: daemonID) {
            placement = .local
            workspace = ""
            profile = ""
            modelKey = ""
            requestKey = UUID().uuidString
        }
        .onChange(of: placement) {
            // Changing where it runs changes what the workspace field means.
            workspace = ""
            requestKey = UUID().uuidString
        }
        .onChange(of: profile) { requestKey = UUID().uuidString }
        .onChange(of: modelKey) { requestKey = UUID().uuidString }
        .onChange(of: isShareable) { requestKey = UUID().uuidString }
        .task(id: placement) {
            remoteWorkspaces = []
            if case .executor(let name) = placement, let daemon {
                remoteWorkspaces = await daemon.workspaces(onExecutor: name)
                workspace = remoteWorkspaces.first ?? ""
            }
        }
    }

    // MARK: Folder

    /// The places the typed text could mean: used folders for a local session, or
    /// the executor's registered names. With nothing typed, all of them.
    private var suggestions: [String] {
        let all: [String]
        switch placement {
        case .local: all = daemon.map { model.recentPlaces(on: $0, forgotten: forgotten) } ?? []
        case .executor: all = remoteWorkspaces
        case .pool: all = []
        }
        let query = workspace.trimmingCharacters(in: .whitespaces)

        // A field that already holds one of the places shows all of them, so a
        // remembered default does not hide the alternatives.
        if query.isEmpty || all.contains(query) { return Array(all.prefix(6)) }
        return Array(all.filter { $0 != workspace && $0.localizedCaseInsensitiveContains(query) }.prefix(6))
    }

    @ViewBuilder
    private var workspaceField: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(placement == .local ? "Folder" : "Workspace") {
                HStack(spacing: 6) {
                    TextField("Folder", text: $workspace, prompt: Text(placement == .local ? "Search places or type a path" : "Name registered on that machine"))
                        .labelsHidden()
                        .font(.system(size: 12).monospaced())
                        .accessibilityLabel("Folder")
                    if placement == .local, daemon?.isRemote != true {
                        Button("Choose…", action: choose)
                    }
                }
            }
            if let words = folderJudgement.words {
                Text(words).font(Theme.caption).foregroundStyle(Theme.failure)
            }
            if placement == .local, daemon?.isRemote == true, workspace.isEmpty {
                Text("A folder on that machine.").font(Theme.caption).foregroundStyle(.secondary)
            }
            ForEach(suggestions, id: \.self) { place in
                HStack(spacing: 6) {
                    Button {
                        workspace = place
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text((place as NSString).lastPathComponent)
                            Text(place).font(Theme.meta).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Use folder \(place)")
                    if placement == .local {
                        Button {
                            forgottenText = (forgotten.union([place])).sorted().joined(separator: "\n")
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Forget this folder")
                        .accessibilityLabel("Forget folder \(place)")
                    }
                }
                .padding(.leading, 80)
            }
        }
    }

    /// Says why the button is disabled, rather than leaving a person to guess.
    private var dispatchHint: String {
        if prompt.isEmpty { return "Describe the work to dispatch." }
        if workspace.isEmpty { return "Choose a folder to dispatch." }
        if let words = folderJudgement.words { return words }
        return "⌘↩ to dispatch"
    }

    /// A daemon's name with its state when it cannot take work yet, so the choice
    /// says so before a request fails.
    private func describe(_ daemon: DaemonConnection) -> String {
        switch daemon.state {
        case .connected: return daemon.label
        case .connecting: return "\(daemon.label) · checking"
        case .unavailable: return "\(daemon.label) · unavailable"
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
        let chosenName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // The same configuration the terminal falls back to with no --config.
        let path = daemon.localRoot?.appendingPathComponent("loom.toml").path ?? configuration
        let creation = CreationOptions(
            profile: profile.isEmpty ? nil : profile,
            model: modelKey.isEmpty ? nil : modelKey,
            isShareable: isShareable
        )
        let typed = (workspace as NSString).expandingTildeInPath
        Task {
            defer { isSending = false }
            do {
                let id = try await daemon.dispatch(
                    workspace: placement == .local && !daemon.isRemote ? typed : workspace,
                    name: chosenName.isEmpty ? firstLine : chosenName,
                    prompt: prompt,
                    placement: placement,
                    configuration: path,
                    requestKey: requestKey,
                    options: creation
                )
                if placement == .local { lastWorkspace = workspace }
                model.destination = .session(id)
                dismiss()
            } catch let partial as CreatedButUnsent {
                // Sending again would create a second session, so the form offers
                // the one that exists instead.
                self.createdID = partial.sessionID
                self.error = partial.localizedDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A choice among a few options, drawn as segments so every option is visible at
/// once, and as a pop-up menu once there are too many to fit.
private struct ChoicePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]

    var body: some View {
        if options.count <= 3 {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.title) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(title)
        } else {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.title) { Text($0.title).tag($0.value) }
            }
            .accessibilityLabel(title)
        }
    }
}
