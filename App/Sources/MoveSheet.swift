import LoomKit
import SwiftUI

/// Moving a session hands it, with its executor, to another orchestrator. Only a
/// session on an executor can move, because a local session's checkout is a folder
/// on this machine and does not travel. The sheet says that when it applies, lists
/// every other orchestrator with the first reason it cannot take the session, and
/// lets a move already under way be abandoned.
struct MoveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: SessionRecord
    @State private var choice: String?
    @State private var isAbandoning = false
    @State private var error: String?
    @State private var isWorking = false

    private var daemon: DaemonConnection? { model.daemon(holding: record.id) }

    /// The executor's node name, which the destination's report lists.
    private var executorNode: String? {
        record.executorNode ?? daemon?.deployment?.executors.first { $0.choice == .executor(record.executor ?? "") }?.node
    }

    private var candidates: [MoveCandidate] {
        guard let deployment = daemon?.deployment else { return [] }
        return MoveCandidate.choose(from: deployment, executorNode: executorNode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move “\(record.title)”").font(.headline)
            content
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.failure)
            }
            HStack {
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if record.movingTo == nil, record.executor != nil {
                    Button("Move", action: move)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(choice == nil || isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .confirmationDialog("Abandon the move to “\(record.movingTo ?? "")”?", isPresented: $isAbandoning, titleVisibility: .visible) {
            Button("Abandon Move", role: .destructive, action: abandon)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The session stays where it is. Work the destination already copied is discarded.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let target = record.movingTo {
            Text("Moving to \(target).").foregroundStyle(Theme.attention)
            Button("Abandon Move…") { isAbandoning = true }
        } else if record.executor == nil {
            Text(MoveCandidate.noExecutorWords).foregroundStyle(.secondary)
        } else if candidates.isEmpty {
            Text("No other orchestrator is configured, so there is nowhere to move it.").foregroundStyle(.secondary)
        } else {
            Text("Choose the orchestrator that takes over this session.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(candidates) { candidate in
                    Button {
                        choice = candidate.name
                    } label: {
                        HStack {
                            Image(systemName: choice == candidate.name ? "largecircle.fill.circle" : "circle")
                            Text(candidate.name)
                            if let refusal = candidate.refusal {
                                Text(refusal).font(Theme.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!candidate.isEligible)
                    .accessibilityLabel("Move to \(candidate.name)")
                }
            }
        }
    }

    private func move() {
        guard let choice, let daemon else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await daemon.move(record.id, to: choice)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func abandon() {
        guard let daemon else { return }
        Task {
            do {
                try await daemon.abandonMove(record.id)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension DaemonConnection {
    func move(_ sessionID: String, to orchestrator: String) async throws {
        guard let control else { throw LoomError.closed("\(label) is not connected.") }
        try await control.moveSession(sessionID: sessionID, to: orchestrator)
        try await refresh(control)
    }

    func abandonMove(_ sessionID: String) async throws {
        guard let control else { throw LoomError.closed("\(label) is not connected.") }
        try await control.abandonMove(sessionID: sessionID)
        try await refresh(control)
    }
}
