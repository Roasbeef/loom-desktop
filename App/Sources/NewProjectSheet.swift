import LoomKit
import MissionKit
import SwiftUI

// Making a project takes two steps because `projects.propose` reads a project's
// repository, so the project has to exist first. Step one chooses a folder and a
// name and makes the project, which is safe to repeat: the id is a function of the
// canonical folder, so making it twice answers the first. Step two shows what the
// daemon suggests for the check and the setup (it runs nothing), lets the owner
// edit both, and saves them, or skips them.

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case folder
        case settings(project: String)
    }

    @State private var step = Step.folder
    @State private var isWorking = false
    @State private var problem: String?
    @State private var settings: ProjectSettings?
    @State private var proposal: ProjectProposal?

    /// The daemon the project was made on, kept from the create so step two writes to
    /// the same daemon even if the list of daemons changes under the sheet.
    @State private var made: DaemonConnection?

    /// Whether the folder already had a project when the create answered.
    @State private var existed = false

    private var daemon: DaemonConnection? { made ?? model.projectDaemon }

    private func field(_ key: String) -> Binding<String> {
        Binding(get: { model.projectFields[key] ?? "" }, set: { model.projectFields[key] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project").font(.title2.weight(.semibold))
            switch step {
            case .folder: folderStep
            case .settings: settingsStep
            }
            if let problem {
                Text(verbatim: problem).font(Theme.caption).foregroundStyle(Theme.failure)
                    .accessibilityIdentifier("new-project-problem")
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            model.projectFields["new/folder"] = ""
            model.projectFields["new/name"] = ""
        }
    }

    // MARK: Step one

    private var judged: FolderCheck { FolderCheck.judge(model.projectFields["new/folder"] ?? "") }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A project runs one router for a repository and a worker for each ticket. Choose the repository's folder on the daemon's machine.")
                .font(Theme.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Folder", text: field("new/folder")).textFieldStyle(.roundedBorder).accessibilityLabel("Project folder")
                Button("Choose…") { if let path = FolderChoice.choose() { model.projectFields["new/folder"] = path } }
                    .accessibilityLabel("Choose Folder")
            }
            if let words = judged.words { Text(words).font(Theme.caption).foregroundStyle(Theme.failure) }
            TextField("Name (the folder's name if empty)", text: field("new/name")).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Project name")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                Button(isWorking ? "Making…" : "Create Project") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!judged.isUsable || isWorking || daemon == nil)
            }
        }
    }

    private func create() {
        guard case .ok(let folder) = judged, let daemon, let control = daemon.control else { return }
        let name = ProjectSetup.projectName(typed: model.projectFields["new/name"] ?? "", folder: folder)
        isWorking = true
        problem = nil
        Task {
            defer { isWorking = false }
            do {
                let created = try await control.createProject(workspace: folder, name: name)
                existed = daemon.projects.contains { $0.id == created.project }
                made = daemon
                await daemon.readProjectsNow()
                model.projectSelection = .project(created.project)

                // The proposal and the settings are reads. A daemon that cannot give
                // them still made the project, so the sheet then closes.
                let read = try? await control.projectSettings(created.project)
                proposal = try? await control.proposeProject(created.project)
                guard let read else { dismiss(); return }
                settings = read
                let draft = ProjectSetup.draft(read, proposal: proposal)
                model.projectFields["new/check"] = draft.check
                model.projectFields["new/setup"] = draft.setup
                step = .settings(project: created.project)
            } catch LoomError.server(let code, let message, _) {
                problem = ProjectSetup.createRefusal(code: code, message: message)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: Step two

    @ViewBuilder
    private var settingsStep: some View {
        if case .settings(let project) = step {
            VStack(alignment: .leading, spacing: 12) {
                Text(existed
                    ? "This folder already has a project; these are its settings. The daemon suggests nothing over a command that is set."
                    : "The project is made. The daemon read its repository and suggests the check and setup below. Nothing has run.")
                    .font(Theme.caption).foregroundStyle(.secondary)
                if model.daemons.count > 1, let daemon {
                    Text(verbatim: "On \(daemon.label)").font(Theme.meta).foregroundStyle(.secondary)
                }
                if let proposal {
                    ForEach(Array(ProjectSetup.proposalWords(proposal).enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line).font(Theme.meta).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                TextField("Check command", text: field("new/check")).textFieldStyle(.roundedBorder).font(Theme.code)
                    .accessibilityLabel("Check command")
                TextField("Setup command", text: field("new/setup")).textFieldStyle(.roundedBorder).font(Theme.code)
                    .accessibilityLabel("Setup command")
                HStack {
                    Spacer()
                    Button("Skip") { dismiss() }
                    Button(isWorking ? "Saving…" : "Save Check and Setup") { save(project) }
                        .keyboardShortcut(.defaultAction).disabled(isWorking)
                }
            }
        }
    }

    private func save(_ project: String) {
        guard let settings, let control = daemon?.control else { return }
        // Every other field is what is in force, so a save here changes only these two.
        var draft = ProjectSetup.draft(settings)
        draft.check = model.projectFields["new/check"] ?? ""
        draft.setup = model.projectFields["new/setup"] ?? ""
        guard case .success(let plan) = ProjectSetup.plan(settings, draft: draft) else { return }
        guard !plan.changes.isEmpty else { dismiss(); return }
        isWorking = true
        problem = nil
        Task {
            defer { isWorking = false }
            do {
                _ = try await control.setProjectSettings(project, revision: settings.revision, changes: plan.changes)
                await daemon?.readProjectsNow()
                dismiss()
            } catch LoomError.server(let code, let message, _) {
                problem = ProjectSetup.refusal(code: code, message: message)

                // The settings are read again, so the next save is made against what is there
                // now, and the fields the owner typed are left as they are.
                if code == "conflict", let fresh = try? await control.projectSettings(project) { self.settings = fresh }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
