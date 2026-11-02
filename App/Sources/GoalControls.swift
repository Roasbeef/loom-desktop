import LoomKit
import SwiftUI

/// The pinned goal, in the dock above the composer.
///
/// A goal makes the agent keep working against an objective and a token budget
/// until a reviewer judges it complete. This line says where it stands and
/// carries the three controls: Pause holds it, Resume continues a paused or
/// budget-limited one, and Clear discards it. The daemon answers each with the
/// fresh board, so the line never shows a state the daemon did not confirm.
struct GoalDock: View {
    let board: GoalBoard
    let controller: SessionController
    @State private var confirmsClear = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(PanelWords.clip(PanelWords.oneLine(board.objective), 90))
                    .font(Theme.label)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("Goal \(board.statusWord)" + (board.causeWord.map { " (\($0))" } ?? ""))
                        .foregroundStyle(board.status == .active ? Color.secondary : Theme.attention)
                    Text("· \(PanelWords.count(board.tokensUsed)) of \(PanelWords.count(board.tokenBudget)) tokens")
                        .foregroundStyle(.secondary)
                }
                .font(Theme.caption)
            }
            Spacer(minLength: 8)
            if board.canPause {
                Button("Pause") { controller.run("goal_pause") }
                    .accessibilityLabel("Pause Goal")
            }
            if board.canResume {
                Button("Resume") { controller.run("goal_resume") }
                    .accessibilityLabel("Resume Goal")
            }
            Button("Clear") { confirmsClear = true }
                .accessibilityLabel("Clear Goal")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radius))
        .accessibilityElement(children: .contain)
        .confirmationDialog("Clear this goal?", isPresented: $confirmsClear) {
            Button("Discard Goal", role: .destructive) { controller.run("goal_clear") }
        } message: {
            Text("The agent stops working toward it, and its spend so far is no longer tracked.")
        }
    }
}

/// The Session tab's goal section: the row, the spend, the last check, and a
/// form to pin a goal when none is pinned.
struct GoalSection: View {
    let board: GoalBoard?
    let controller: SessionController
    @State private var objective = ""
    @State private var budget = "400000"

    var body: some View {
        PanelSection("Goal") {
            if let board, board.isPinned {
                Text(board.row).font(Theme.caption).textSelection(.enabled)
                if !board.because.isEmpty, board.status != .active {
                    Quiet(board.because)
                }
                Quiet(board.spend)
                Quiet(board.ages)
                if let check = board.check {
                    Quiet("check: " + PanelWords.oneLine(check) + (board.lastCheck == nil ? " (not run yet)" : ""))
                }
                if let run = board.lastCheck {
                    Quiet("last run: " + run.result)
                }
                if let note = board.reviewerNote {
                    Quiet("reviewer: " + PanelWords.oneLine(note))
                }
            } else {
                Quiet("No goal is pinned. Pin one to keep the agent working until a reviewer judges it done.")
                TextField("Objective", text: $objective, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityLabel("Goal objective")
                HStack {
                    TextField("Token budget", text: $budget)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .accessibilityLabel("Goal token budget")
                    Spacer()
                    Button("Pin Goal") { pin() }
                        .disabled(!canPin)
                }
                if let error = controller.readFailures["goal_get"] {
                    Quiet(error)
                }
            }
        }
    }

    private var canPin: Bool {
        !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (Int(budget) ?? 0) > 0
    }

    private func pin() {
        controller.run("goal_set", body: [
            "objective": .string(objective.trimmingCharacters(in: .whitespacesAndNewlines)),
            "token_budget": .int(Int64(budget) ?? 0),
        ])
        objective = ""
    }
}
