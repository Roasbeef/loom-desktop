import LoomKit
import SwiftUI

/// The Evolution tab: candidates a session proposed to extend itself, the
/// evidence for each, what is published, and the decisions made.
///
/// The board is read when the tab opens, when the daemon says it changed, and on
/// Read Again. Approving or revoking a candidate asks first, since an approved
/// candidate can be selected into the running agent. Reading the core's status
/// is a separate read, and core upgrades are run from the terminal.
struct EvolutionPane: View {
    let controller: SessionController
    @State private var board: EvolutionBoard?
    @State private var core: CoreStatus?
    @State private var failure: String?
    @State private var asking: Question?

    private struct Question: Identifiable {
        let id = UUID()
        let title: String
        let confirm: String
        let action: String
        let arguments: [String: JSONValue]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Evolution").font(.headline)
                if let board, board.awaitingApproval > 0 {
                    Text("\(board.awaitingApproval)").font(Theme.meta).foregroundStyle(Theme.attention)
                        .accessibilityLabel("\(board.awaitingApproval) candidates awaiting approval")
                }
                Spacer()
                Button("Read Again") { Task { await read() } }
                    .controlSize(.small)
            }
            if let failure { Quiet("Evolution is not available here: \(failure)") }
            if let board {
                if board.candidates.isEmpty {
                    Quiet("No candidates yet. A session proposes one when it writes an extension, a program or a prompt.")
                }
                if !board.selections.isEmpty {
                    PanelSection("Published") {
                        ForEach(board.selections) { row in
                            Text("\(row.name) · generation \(row.generation) · \(row.scope)" + (row.isLive ? "" : " · not live"))
                                .font(Theme.caption)
                        }
                    }
                }
                ForEach(board.candidates) { candidate in
                    card(candidate)
                }
                if board.omittedCandidates > 0 { Quiet("\(board.omittedCandidates) more candidates are not shown.") }
                if !board.history.isEmpty {
                    PanelSection("History") {
                        ForEach(board.history) { event in
                            Text("\(event.decision) \(event.name)" + (event.principal.isEmpty ? "" : " · \(event.principal)")
                                 + (event.reason.isEmpty ? "" : " · \(event.reason)"))
                                .font(Theme.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if failure == nil {
                Quiet("Reading the evolution board…")
            }
            PanelSection("Core") {
                Quiet("Core upgrades run from the terminal: loom evolution core_upgrade.")
                Button("Read Core Status") { Task { await readCore() } }.controlSize(.small)
                if let core {
                    ForEach(Array(core.rows.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.name).font(Theme.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(row.value).font(Theme.meta).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .task(id: controller.signals["evolution_changed"] ?? 0) { await read() }
        .confirmationDialog(
            asking?.title ?? "",
            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
        ) {
            if let question = asking {
                Button(question.confirm, role: question.action == "revoke" ? .destructive : nil) {
                    Task { await send(question.action, question.arguments) }
                }
            }
        }
    }

    private func card(_ candidate: EvolutionBoard.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.name).font(.system(size: 12, weight: .semibold).monospaced())
                Text(candidate.kindWords).font(Theme.caption).foregroundStyle(.secondary)
                Spacer()
                if !candidate.isCurrent { Text("outdated").font(Theme.caption).foregroundStyle(Theme.attention) }
            }
            Quiet("For \(candidate.scope)")
            if !candidate.description.isEmpty { Text(candidate.description).font(Theme.caption) }
            ForEach(candidate.evidence) { evidence in
                Text("\(evidence.verdict) · \(evidence.purposeWords)" + (evidence.isCurrent ? "" : " · outdated")
                     + (evidence.reason.isEmpty ? "" : " · \(evidence.reason)"))
                    .font(Theme.caption)
                    .foregroundStyle(evidence.verdict == "failed" ? Theme.failure : Color.secondary)
            }
            HStack {
                if let by = candidate.approvedBy {
                    Text("Approved by \(by)").font(Theme.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revoke") {
                        asking = Question(title: "Revoke \(candidate.name)?", confirm: "Revoke", action: "revoke",
                                          arguments: ["candidate_id": .string(candidate.id), "reason": "revoked from Loom Desktop"])
                    }
                    .accessibilityLabel("Revoke \(candidate.name)")
                } else if let evidence = candidate.approvable {
                    Spacer()
                    Button("Approve…") {
                        asking = Question(title: "Approve \(candidate.name)?", confirm: "Approve Candidate", action: "approve",
                                          arguments: ["candidate_id": .string(candidate.id), "evidence_id": .string(evidence.id)])
                    }
                    .accessibilityLabel("Approve \(candidate.name)")
                } else {
                    Quiet("No passing, current evidence yet, so it cannot be approved.")
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }

    private func read() async {
        do {
            let reply = try await controller.exchange("evolution", body: ["action": "board", "arguments": .object([:])])
            board = EvolutionBoard(reply.body["board"])
            failure = board == nil ? "the board was not readable" : nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func readCore() async {
        if let reply = try? await controller.exchange("evolution", body: ["action": "core_status", "arguments": .object([:])]) {
            core = CoreStatus(reply.body["board"])
        }
    }

    private func send(_ action: String, _ arguments: [String: JSONValue]) async {
        do {
            _ = try await controller.exchange("evolution", body: ["action": .string(action), "arguments": .object(arguments)])
            await read()
        } catch {
            failure = error.localizedDescription
        }
    }
}
