import LoomKit
import SwiftUI

/// The figures at the end of the composer's meta row: how full the model's
/// window is, what the session has cost, the connection and the side question.
///
/// The cost is an estimate, worded with its rate basis and coverage, and it is
/// left out of the bar while it is only a dash, because two dashes read as
/// missing data. The Session tab keeps its dash.
struct ComposerFigures: View {
    let controller: SessionController

    var body: some View {
        ContextFigure(controller: controller)
        let cost = UsageWords.estimate(usage: controller.usage)
        if !cost.hasSuffix("—") {
            Text(cost)
                .help("Estimated cost of the session, across strands")
                .accessibilityLabel("Estimated cost")
                .accessibilityValue(cost)
        }
        Text(controller.isLive ? "Connected" : "Disconnected")
            .foregroundStyle(controller.isLive ? Color.secondary : Theme.attention)
            .accessibilityLabel("Connection")
            .accessibilityValue(controller.isLive ? "Connected" : "Disconnected")
            .debouncedTask(id: ContextFigure.Trigger(strand: controller.focusedStrand, isBusy: controller.isBusy, blocks: controller.blocks.count)) {
                controller.read("context", body: ["strand": .string(controller.focusedStrand)])
            }
        Button {
            controller.showsSideQuestion.toggle()
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
        }
        .buttonStyle(.plain)
        .help("Ask a question on the side while the agent keeps working")
        .accessibilityLabel("Side Question")
    }
}

extension SessionController {
    /// The Strands tab's title, with the number of strands waiting on a person.
    var strandsTabTitle: String {
        let waiting = strandLines.reduce(0) { $0 + $1.approvals }
        return waiting > 0 ? "Strands (\(waiting))" : "Strands"
    }
}
