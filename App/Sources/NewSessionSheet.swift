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

    /// The models and profiles of a configuration as the daemon judges them,
    /// which works for a daemon on another machine and says which models read
    /// images. A daemon without `models.list`, or a failed read, falls back to
    /// the local file's headers, which name the same keys but nothing about images.
    func modelCatalogue(configuration: String) async -> ModelCatalogue {
        if let control, !configuration.isEmpty, let catalogue = try? await control.listModels(configuration: configuration) {
            return catalogue
        }
        return ModelCatalogue(file: configurationChoices)
    }
}

/// Starts a session: what it should do first, where, with which models, and whether
/// others can join it. The prompt comes first because it is why a person opened the
/// form, and the place defaults to the last choice so a repeat takes one keystroke.
///
/// The folder is a chip under the prompt that opens a popover (`FolderPickerPopover`):
/// a search over recent folders, projects and any folder below the home directory,
/// so a person who has worked in a folder once, or never, finds it by a few letters.
/// The form judges the chosen folder while it is shown, so a mistake is named
/// before any request is made.
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
    @State private var visionKey = ""
    @State private var catalogue = ModelCatalogue()
    @State private var isShareable = false
    @State private var worktreeChoice = WorktreeChoice.folder
    @State private var worktreeBase = ""
    @State private var projects: [ProjectRef] = []
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

    /// The configuration the session will load: this Mac's own for a local
    /// daemon, otherwise the path typed for that machine.
    private var configurationPath: String {
        daemon?.localRoot?.appendingPathComponent("loom.toml").path ?? configuration
    }

    /// A typed local folder is judged here. A remote daemon's folders and an
    /// executor's registered names mean nothing on this machine, so the daemon
    /// judges those.
    private var folderJudgement: FolderCheck {
        guard placement == .local, daemon?.isRemote != true else { return workspace.isEmpty ? .empty : .ok(workspace) }
        return FolderCheck.judge(workspace)
    }

    /// What the worktree choice is worth on this form: the request to send, and
    /// the sentence that says why it cannot be sent, if there is one. The
    /// choice applies to a folder on the agent's machine and not to an executor's
    /// workspace, which chooses its own mode in the executor's table.
    private var worktreeJudgement: (request: WorktreeRequest?, problem: String?) {
        guard worktreeChoice == .ownTree, placement == .local else { return (nil, nil) }
        if let problem = WorktreeWords.problem(withBase: worktreeBase) { return (nil, problem) }
        if isLocalDisk, !workspace.isEmpty, case .ok(let path) = folderJudgement, let problem = WorktreeWords.judge(folder: path) {
            return (nil, problem)
        }
        return (WorktreeRequest(base: worktreeBase), nil)
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

            folderRow

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
                TextField("Name", text: $name, prompt: Text("The first line of your message"))
                    .accessibilityLabel("Session name")
                if !catalogue.profiles.isEmpty {
                    ChoicePicker(title: "Model profile", selection: $profile, options: [("Default", "")] + catalogue.profiles.map { ($0, $0) })
                }
                if !catalogue.models.isEmpty {
                    ChoicePicker(title: "Main model", selection: $modelKey, options: [(profile.isEmpty ? "Default" : "From profile", "")] + catalogue.models.map { ($0.key, $0.key) })
                }

                // Only the daemon can say which models read images, so the choice
                // appears only when it answered and named at least one.
                if !catalogue.imageReaders.isEmpty {
                    ChoicePicker(title: "Vision model", selection: $visionKey, options: [(profile.isEmpty ? "Default" : "From profile", "")] + catalogue.imageReaders.map { ($0.key, $0.key) })
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
                    .disabled(isSending || createdID != nil || workspace.isEmpty || prompt.isEmpty || worktreeJudgement.problem != nil || (!folderJudgement.isUsable && placement == .local && daemon?.isRemote != true))
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
            visionKey = ""
            requestKey = UUID().uuidString
        }
        .onChange(of: placement) {
            // Changing where it runs changes what the workspace field means.
            workspace = ""
            requestKey = UUID().uuidString
        }
        #if DEBUG
        .onChange(of: model.debugPlacement) {
            if let option = options.first(where: { describe($0).hasPrefix(model.debugPlacement) }) {
                placement = option.choice
            }
        }
        #endif
        .onChange(of: profile) { requestKey = UUID().uuidString }
        .onChange(of: modelKey) { requestKey = UUID().uuidString }
        .onChange(of: visionKey) { requestKey = UUID().uuidString }
        .task(id: "\(daemonID)|\(configurationPath)") {
            guard let daemon else { return }
            catalogue = await daemon.modelCatalogue(configuration: configurationPath)

            // A remembered choice the configuration no longer offers is dropped.
            if !catalogue.models.contains(where: { $0.key == modelKey }) { modelKey = "" }
            if !catalogue.imageReaders.contains(where: { $0.key == visionKey }) { visionKey = "" }
        }
        .onChange(of: isShareable) { requestKey = UUID().uuidString }
        .onChange(of: worktreeChoice) { requestKey = UUID().uuidString }
        .onChange(of: worktreeBase) { requestKey = UUID().uuidString }
        .task(id: daemonID) {
            // Projects fill the picker while the form is being read, so the popover
            // has them by the time it opens. A daemon slow to answer leaves the
            // list empty and holds up nothing else.
            projects = []
            guard let daemon else { return }
            projects = await daemon.pickerProjects()
        }
        .task(id: placement) {
            remoteWorkspaces = []
            if case .executor(let name) = placement, let daemon {
                remoteWorkspaces = await daemon.workspaces(onExecutor: name)
                workspace = remoteWorkspaces.first ?? ""
            }
        }
    }

    // MARK: Folder

    /// The places already used for this placement: used folders for a local
    /// session, or the executor's registered names.
    private var places: [String] {
        switch placement {
        case .local: daemon.map { model.recentPlaces(on: $0, forgotten: forgotten) } ?? []
        case .executor: remoteWorkspaces
        case .pool: []
        }
    }

    /// What the picker says when it has no row and nothing is typed.
    private var pickerEmptyNote: String {
        switch placement {
        case .pool: "Type the workspace name the pool serves."
        case .local, .executor: "No folders yet. Type a path."
        }
    }

    private var isLocalDisk: Bool { placement == .local && daemon?.isRemote != true }

    /// The chip, and under it the daemon-independent judgement of a typed folder.
    private var folderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                FolderPickerChip(
                    folder: $workspace,
                    placeholder: placement == .local ? "Choose folder" : "Choose workspace",
                    recent: places,
                    projects: placement == .local ? projects : [],
                    roots: model.pickerRoots,
                    canBrowseDisk: isLocalDisk,
                    canForget: placement == .local,
                    recentTitle: placement == .local ? "Recent" : "Registered workspaces",
                    emptyNote: pickerEmptyNote,
                    forgotten: forgotten,
                    onForget: { forgottenText = forgotten.union([$0]).sorted().joined(separator: "\n") }
                )
                if !workspace.isEmpty {
                    Text(FolderPicker.abbreviate((workspace as NSString).deletingLastPathComponent))
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if placement == .local {
                    WorktreeToggle(choice: $worktreeChoice)
                }
                Spacer(minLength: 0)
            }
            if worktreeChoice == .ownTree, placement == .local {
                WorktreeBaseField(base: $worktreeBase)
            }
            if let words = folderJudgement.words {
                Text(words).font(Theme.caption).foregroundStyle(Theme.failure)
            } else if let words = worktreeJudgement.problem {
                Text(words).font(Theme.caption).foregroundStyle(Theme.failure)
            }
            if placement == .local, daemon?.isRemote == true, workspace.isEmpty {
                Text("A folder on that machine.").font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    /// Says why the button is disabled, rather than leaving a person to guess.
    private var dispatchHint: String {
        if prompt.isEmpty { return "Describe the work to dispatch." }
        if workspace.isEmpty { return "Choose a folder to dispatch (⌘O)." }
        if let words = folderJudgement.words { return words }
        if let words = worktreeJudgement.problem { return words }
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
            isShareable: isShareable,
            pins: visionKey.isEmpty ? [:] : ["vision": visionKey],
            worktree: worktreeJudgement.request
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
            } catch let refused as WorktreeNotHonoured {
                // That session was removed, so the same key must not recover it.
                requestKey = UUID().uuidString
                self.error = refused.localizedDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Where a new session works: in the folder itself, or in a Git worktree of it
/// on a branch of its own. Two cases named for the domain, so the form and the
/// request carry no bare flag.
enum WorktreeChoice {
    case folder
    case ownTree
}

/// The chip beside the folder that puts the session in its own worktree. Off
/// unless a person turns it on, since the usual session works in the folder.
private struct WorktreeToggle: View {
    @Binding var choice: WorktreeChoice

    var body: some View {
        Toggle(isOn: Binding(get: { choice == .ownTree }, set: { choice = $0 ? .ownTree : .folder })) {
            Label("Worktree", systemImage: "arrow.triangle.branch")
                .font(Theme.label)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help("Work in a Git worktree of this folder, on a branch of its own, so the changes stay out of the folder")
        .accessibilityLabel("Worktree")
    }
}

/// The base a worktree's branch starts from, behind a disclosure because the
/// default, the folder's current commit, is what most sessions want.
private struct WorktreeBaseField: View {
    @Binding var base: String
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup("Base", isExpanded: $isOpen) {
            TextField("Base", text: $base, prompt: Text("HEAD"))
                .font(.system(size: 12).monospaced())
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Worktree base")
        }
        .font(Theme.caption)
        .foregroundStyle(.secondary)
    }
}

/// A choice among a few options, drawn as segments so every option is visible at
/// once, and as a pop-up menu once there are too many to fit.
private struct ChoicePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(title: String, value: Value)]

    /// Segments never shrink below their titles, so long titles such as a machine
    /// with its platform and state would widen the sheet past its edges. Up to about
    /// this many characters in all, three segments fit the form's value column.
    private static var segmentCharacters: Int { 42 }

    private var fitsAsSegments: Bool {
        options.count <= 3 && options.reduce(0) { $0 + $1.title.count } <= Self.segmentCharacters
    }

    var body: some View {
        if fitsAsSegments {
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
