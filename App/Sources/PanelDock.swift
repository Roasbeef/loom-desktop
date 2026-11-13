import LoomKit
import SwiftUI

/// What sits above the composer besides approvals: the todo board, the pinned
/// goal, proposals waiting on a person and the side question.
///
/// It is its own view so that a goal or board changing redraws this and not the
/// composer around it, and it reads only what it draws. The goal and proposal
/// boards are read when the session attaches and again whenever the daemon says
/// they changed, which is the whole of their freshness: neither polls.
struct PanelDock: View {
    let controller: SessionController

    var body: some View {
        VStack(spacing: 10) {
            if let goal = GoalBoard(controller.surfaces["goal"]?["board"]), goal.isPinned {
                GoalDock(board: goal, controller: controller)
            }
            if let proposals = ProposalBoard(controller.surfaces["proposals"]?["board"]), let first = proposals.pendingRows.first {
                ProposalCard(row: first, controller: controller, compact: true)
                    .glassEffect(.regular, in: .rect(cornerRadius: Theme.radius))
                if proposals.pending > 1 {
                    Quiet("\(proposals.pending - 1) more proposals wait in the Session tab.")
                }
            }
            if let todo = controller.todo, !todo.isEmpty {
                TodoDock(board: todo)
            }
            if controller.showsSideQuestion {
                SideQuestionPanel(controller: controller)
            }
        }
        // The reads hang off a view that is always present, because a task
        // attached to an empty stack would never run.
        .background(
            Color.clear
                .task(id: controller.signals["goal_changed"] ?? 0) { controller.read("goal_get") }
                .task(id: controller.signals["proposals_changed"] ?? 0) { controller.read("proposals_get") }
        )
    }
}
