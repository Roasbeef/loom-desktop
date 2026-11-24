import LoomKit
import MissionKit
import SwiftUI

// The two forms on a project's page: the request composer, which posts work to the
// router, and the settings, which are read from the daemon and saved back at the
// revision that was read.

/// The request composer. A request is posted with an id made when it was composed
/// and kept until the daemon accepts it, so a retry after a lost reply cannot post
/// it twice.
struct ProjectComposer: View {
    @Environment(AppModel.self) private var model
    let project: String
    @State private var isSending = false
    @State private var result: TicketResult?

    private var key: String { "post/\(project)" }
    private var idKey: String { "postid/\(project)" }

    /// The text of the request. Changing it makes it a new request, so it drops the id
    /// that an earlier attempt of the old text may still hold.
    private var text: Binding<String> {
        Binding(get: { model.projectFields[key] ?? "" }, set: { model.projectFields[key] = $0; model.projectFields[idKey] = nil })
    }

    /// The id of the request being composed. It is kept beside the text, on the model, so
    /// a sheet or pane that is closed and opened again after a reply was lost still sends
    /// the same id, and the daemon posts the request once.
    private func requestID() -> String {
        if let held = model.projectFields[idKey] { return held }
        let made = ProjectPost.requestID(UUID())
        model.projectFields[idKey] = made
        return made
    }

    var body: some View {
        PaneSection("Request work") {
            TextField("What should the router do?", text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...8)
                .disabled(isSending)
                .accessibilityLabel("Request text")
            if let problem = ProjectPost.problem(text.wrappedValue) {
                Text(verbatim: problem).font(Theme.caption).foregroundStyle(Theme.failure)
            }
            HStack {
                Button(isSending ? "Posting…" : "Post Request") { post() }
                    .buttonStyle(.bordered)
                    .disabled(isSending || ProjectPost.text(text.wrappedValue) == nil)
                if let result {
                    Text(verbatim: result.words).font(Theme.caption).foregroundStyle(result.isRefusal ? Theme.failure : .secondary)
                        .accessibilityIdentifier("post-result")
                }
            }
        }
    }

    private func post() {
        guard let words = ProjectPost.text(text.wrappedValue), let daemon = model.daemon(holdingProject: project),
              let control = daemon.control else { return }
        let id = requestID()
        isSending = true
        result = nil
        Task {
            defer { isSending = false }
            do {
                let receipt = try await control.postToProject(project, requestID: id, text: words)
                result = TicketResult(words: ProjectPost.receiptWords(receipt), isRefusal: false)
                model.projectFields[key] = nil
                model.projectFields[idKey] = nil
                await daemon.readProjectsNow()
            } catch LoomError.server(let code, let message, _) {
                result = TicketResult(words: ProjectPost.refusal(code: code, message: message), isRefusal: true)

                // A refusal means nothing was posted, so the next attempt is a new request.
                model.projectFields[idKey] = nil
            } catch {
                // The id is kept: the request may have been taken, and sending it
                // again with the same id changes nothing if it was.
                result = TicketResult(words: "No reply arrived, so it may have been posted. Press Post Request again to be sure; it cannot post twice.", isRefusal: true)
            }
        }
    }
}

/// A project's settings: each key with its value in force and where that value comes
/// from, editable, saved as only the keys that changed.
struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    let project: String
    @State private var read: ProjectSettings?
    @State private var draft = SettingsDraft()

    /// The form as the last read gave it, which says which fields the owner has touched.
    @State private var base = SettingsDraft()
    @State private var isSaving = false
    @State private var result: TicketResult?

    private var daemon: DaemonConnection? { model.daemon(holdingProject: project) }

    var body: some View {
        PaneSection("Settings") {
            if let read {
                form(read)
            } else {
                Text("The settings have not been read.").font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        // Read again whenever the project's ledger moves, so a change made elsewhere, or
        // by the new-project sheet, is not shown as the old value.
        .task(id: "\(project)/\(model.projectStates.first { $0.id == project }?.page?.revision ?? -1)") { await load() }
    }

    private func load() async {
        guard let control = daemon?.control, let settings = try? await control.projectSettings(project) else { return }
        // A field the owner has edited keeps what was typed; every other field takes what
        // is in force now, so a save never sends back another writer's change.
        let fresh = ProjectSetup.draft(settings)
        draft = ProjectSetup.rebase(draft, from: base, onto: fresh)
        base = fresh
        read = settings
    }

    private func source(_ key: String) -> String {
        read?.setting(key).map { ProjectSetup.sourceWords($0.source) } ?? ""
    }

    private func row(_ key: String, _ field: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(ProjectSetup.title(key)).font(Theme.label)
                Text(verbatim: source(key)).font(Theme.caption).foregroundStyle(.secondary)
            }
            TextField(ProjectSetup.title(key), text: field, axis: .vertical)
                .textFieldStyle(.roundedBorder).font(Theme.code).lineLimit(1...4)
                .accessibilityLabel("\(ProjectSetup.title(key)) setting")
        }
    }

    private func fieldBinding(_ keyPath: WritableKeyPath<SettingsDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 })
    }

    private func form(_ settings: ProjectSettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row("check", fieldBinding(\.check))
            row("setup", fieldBinding(\.setup))
            row("max_workers", fieldBinding(\.maxWorkers))
            row("protected_paths", fieldBinding(\.protectedPaths))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(ProjectSetup.title("publish")).font(Theme.label)
                    Text(verbatim: source("publish")).font(Theme.caption).foregroundStyle(.secondary)
                }
                Picker("Publish", selection: $draft.publish) {
                    ForEach(PublishMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().accessibilityLabel("Publish mode")
                if draft.publish == .pullRequest {
                    Text(verbatim: settings.publishURL.map { "The host will push branches to \($0) and open pull requests, never merge." }
                        ?? SettingsRefusal.noRemote.words).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(isSaving ? "Saving…" : "Save Settings") { save(settings) }
                    .buttonStyle(.bordered).disabled(isSaving)
                if let result {
                    Text(verbatim: result.words).font(Theme.caption).foregroundStyle(result.isRefusal ? Theme.failure : .secondary)
                        .accessibilityIdentifier("settings-result")
                }
            }
        }
    }

    private func save(_ settings: ProjectSettings) {
        switch ProjectSetup.plan(settings, draft: draft) {
        case .failure(let refusal):
            result = TicketResult(words: refusal.words, isRefusal: true)
        case .success(let plan) where plan.changes.isEmpty:
            result = TicketResult(words: "Nothing changed.", isRefusal: false)
        case .success(let plan):
            guard let control = daemon?.control else { return }
            isSaving = true
            result = nil
            Task {
                defer { isSaving = false }
                do {
                    let now = try await control.setProjectSettings(
                        project, revision: settings.revision, changes: plan.changes, publishTo: plan.publishTo
                    )
                    read = now
                    base = ProjectSetup.draft(now)
                    draft = base
                    result = TicketResult(words: "Saved. A changed check or setup takes effect with no restart.", isRefusal: false)
                } catch LoomError.server(let code, let message, _) {
                    result = TicketResult(words: ProjectSetup.refusal(code: code, message: message), isRefusal: true)

                    // A stale revision is read again, so the next save is made against what is there now.
                    if code == "conflict" { await load() }
                } catch {
                    result = TicketResult(words: error.localizedDescription, isRefusal: true)
                }
            }
        }
    }
}
