import LoomKit
import MissionKit
import SwiftUI

/// What a person can do to a session's life: name it, stop it, archive it, delete
/// it. Each is an owner command on the daemon holding the session. Stopping a run
/// that is mid-turn, archiving and deleting ask first in a native dialog, because
/// the first discards work in flight and the others remove the session from view
/// or from disk. Stopping an idle run and renaming do not ask, since neither loses
/// anything the person cannot get back by one more action.
@MainActor
@Observable
final class SessionActions {
    /// A question waiting for an answer.
    enum Pending: Identifiable, Equatable {
        case stop(SessionRecord)
        case archive(SessionRecord, isRunning: Bool, isMidTurn: Bool)
        case delete(SessionRecord)

        var id: String {
            switch self {
            case .stop(let record): return "stop-\(record.id)"
            case .archive(let record, _, _): return "archive-\(record.id)"
            case .delete(let record): return "delete-\(record.id)"
            }
        }

        var record: SessionRecord {
            switch self {
            case .stop(let record), .archive(let record, _, _), .delete(let record): return record
            }
        }

        var title: String {
            switch self {
            case .stop(let record): return "Stop “\(record.title)” while it is working?"
            case .archive(let record, true, _): return "Stop and archive “\(record.title)”?"
            case .archive(let record, false, _): return "Archive “\(record.title)”?"
            case .delete(let record): return "Delete “\(record.title)” for good?"
            }
        }

        var message: String {
            switch self {
            case .stop:
                return "It is partway through a turn. Stopping ends that turn. The conversation is kept and you can open the session again."
            case .archive(_, true, true):
                return "It is partway through a turn, which stopping ends. The archived conversation is kept and leaves the list."
            case .archive(_, true, false):
                return "It will be stopped first. The conversation is kept and leaves the list."
            case .archive:
                return "It leaves the list. The conversation is kept."
            case .delete:
                return "This removes its conversation from this machine. It cannot be undone."
            }
        }

        var confirmLabel: String {
            switch self {
            case .stop: return "Stop Session"
            case .archive(_, true, _): return "Stop and Archive"
            case .archive: return "Archive"
            case .delete: return "Delete Session"
            }
        }
    }

    var pending: Pending?
    var renaming: SessionRecord?
    var moving: SessionRecord?

    /// A folder the next new-session form starts with, set by a project heading.
    var newSessionFolder: String?

    /// The last refusal, in words, until a person dismisses it.
    var error: String?

    /// A short word for tests and the status line: what is being asked.
    var summary: String {
        switch pending {
        case .stop(let record)?: return "stop:\(record.id)"
        case .archive(let record, let running, let mid)?: return "archive:\(record.id):\(running ? "running" : "saved"):\(mid ? "midturn" : "quiet")"
        case .delete(let record)?: return "delete:\(record.id)"
        case nil: return renaming.map { "rename:\($0.id)" } ?? ""
        }
    }
}

extension AppModel {
    /// The session the main window shows, as the catalogue lists it. The menu bar
    /// acts on this, because a saved session has no controller to ask.
    var currentRecord: SessionRecord? {
        guard case .session(let id) = destination else { return nil }
        return sessions.first { $0.id == id }
    }

    func isMidTurn(_ record: SessionRecord) -> Bool {
        guard let state = activity[record.id]?.state else { return false }
        return state == .working || state == .needsYou
    }

    func askToRename(_ record: SessionRecord) {
        actions.renaming = record
    }

    /// Stops a running session at once when it is idle, and asks when it is not.
    func askToStop(_ record: SessionRecord) {
        guard record.state.isResident else { return }
        if isMidTurn(record) {
            actions.pending = .stop(record)
        } else {
            perform(.stop(record))
        }
    }

    func askToArchive(_ record: SessionRecord) {
        actions.pending = .archive(record, isRunning: record.state.isResident, isMidTurn: isMidTurn(record))
    }

    func askToDelete(_ record: SessionRecord) {
        guard !record.state.isResident else { return }
        actions.pending = .delete(record)
    }

    /// Opens the new-session form on a folder, which a project heading and the
    /// Session menu both do. A session on an executor has no folder here.
    func startSession(inFolderOf record: SessionRecord) {
        guard record.executor == nil, record.pool == nil else { return }
        actions.newSessionFolder = record.workspace
        isDispatching = true
    }

    func askToMove(_ record: SessionRecord) {
        actions.moving = record
    }

    /// Carries out an answered question and reports a refusal in words.
    func perform(_ pending: SessionActions.Pending) {
        actions.pending = nil
        let record = pending.record
        guard let daemon = daemon(holding: record.id) else { return }
        Task {
            do {
                switch pending {
                case .stop: try await daemon.stop(record.id)
                case .archive: try await daemon.archive(record.id)
                case .delete:
                    try await daemon.delete(record.id)
                    if case .session(record.id) = destination { destination = .mission }
                }
            } catch {
                actions.error = error.localizedDescription
            }
        }
    }

    func rename(_ record: SessionRecord, to name: String) async {
        guard let daemon = daemon(holding: record.id) else { return }
        do {
            try await daemon.rename(record.id, to: name)
            actions.renaming = nil
        } catch {
            actions.error = error.localizedDescription
        }
    }
}

extension DaemonConnection {
    func rename(_ sessionID: String, to name: String) async throws {
        guard let control else { throw LoomError.closed("\(label) is not connected.") }
        try await control.renameSession(sessionID: sessionID, name: name)
        try await refresh(control)
    }

    /// Stops the session first when it is resident, because the daemon refuses to
    /// archive a live runtime, and waits for it to be saved.
    func archive(_ sessionID: String) async throws {
        guard let control else { throw LoomError.closed("\(label) is not connected.") }
        if sessions.first(where: { $0.id == sessionID })?.state.isResident == true {
            try await stop(sessionID)
            try await waitUntilSaved(sessionID, control: control)
        }
        try await control.archiveSession(sessionID: sessionID)
        try await refresh(control)
    }

    func delete(_ sessionID: String) async throws {
        guard let control else { throw LoomError.closed("\(label) is not connected.") }
        try await control.deleteSession(sessionID: sessionID)
        try await refresh(control)
    }

    /// A stop is asked for and finishes later, so a follow-up that needs the
    /// session saved polls the catalogue until it is.
    private func waitUntilSaved(_ sessionID: String, control: ControlClient) async throws {
        for _ in 0..<50 {
            let records = try await control.listSessions()
            if let record = records.first(where: { $0.id == sessionID }), case .saved = record.state { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LoomError.closed("The session did not stop in time.")
    }
}

// MARK: Views

/// Attaches the confirmation dialog, the rename sheet and the refusal alert to the
/// main window.
struct SessionActionPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var actions = model.actions
        content
            .confirmationDialog(
                actions.pending?.title ?? "",
                isPresented: Binding(get: { actions.pending != nil }, set: { if !$0 { actions.pending = nil } }),
                titleVisibility: .visible,
                presenting: actions.pending
            ) { pending in
                Button(pending.confirmLabel, role: .destructive) { model.perform(pending) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(pending.message)
            }
            .sheet(item: $actions.renaming) { record in
                RenameSheet(record: record)
            }
            .sheet(item: $actions.moving) { record in
                MoveSheet(record: record)
            }
            .alert(
                "That didn’t work",
                isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actions.error ?? "")
            }
    }
}

/// A name for the session, in a sheet because it takes typing and a native text
/// field gives the person the system's editing for free.
struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: SessionRecord
    @State private var name: String
    @FocusState private var isFocused: Bool

    init(record: SessionRecord) {
        self.record = record
        _name = State(initialValue: record.title)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename session").font(.headline)
            TextField("Session name", text: $name)
                .focused($isFocused)
                .onSubmit(save)
                .accessibilityLabel("Session name")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || trimmed == record.title)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        Task { await model.rename(record, to: trimmed) }
    }
}

/// The Session menu's life-cycle items. They act on the session in the window, so
/// a test or a keyboard reaches what the sidebar's context menu offers.
struct SessionLifecycleMenuItems: View {
    let model: AppModel

    var body: some View {
        Button("New Session in This Folder…") {
            if let record = model.currentRecord { model.startSession(inFolderOf: record) }
        }
        Button("Rename Session…") {
            if let record = model.currentRecord { model.askToRename(record) }
        }
        Button("Stop Session") {
            if let record = model.currentRecord { model.askToStop(record) }
        }
        Button("Archive Session…") {
            if let record = model.currentRecord { model.askToArchive(record) }
        }
        Button("Delete Session…") {
            if let record = model.currentRecord { model.askToDelete(record) }
        }
        Button("Move Session…") {
            if let record = model.currentRecord { model.askToMove(record) }
        }
    }
}
