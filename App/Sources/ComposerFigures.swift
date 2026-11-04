import LoomKit
import SwiftUI

/// The figures in the composer's bar: how full the model's window is, the
/// cache outlook when it applies, and the connection when it is lost. The
/// model, tokens, speed and cost are behind the context figure, and the side
/// question is on the Session menu and `/btw`.
struct ComposerFigures: View {
    let controller: SessionController

    var body: some View {
        ContextFigure(controller: controller)
        CacheOutlookFigure(controller: controller)
        // Being connected is the normal state, so the bar spends words only on losing it.
        Text(controller.isLive ? "" : "Disconnected")
            .foregroundStyle(Theme.attention)
            .accessibilityLabel("Connection")
            .accessibilityValue(controller.isLive ? "Connected" : "Disconnected")
            .debouncedTask(id: ContextFigure.Trigger(strand: controller.focusedStrand, isBusy: controller.isBusy, blocks: controller.blocks.count)) {
                controller.read("context", body: ["strand": .string(controller.focusedStrand)])
            }
    }
}

/// How long the addressed strand has sat idle since a request that held a cached
/// prefix. It redraws on a slow clock, because the label only changes by the minute.
struct CacheOutlookFigure: View {
    let controller: SessionController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let label = controller.cacheOutlook(at: context.date) {
                Text(label)
                    .help("How long the provider's prompt cache has gone unused. It may have expired.")
                    .accessibilityLabel("Cache outlook")
                    .accessibilityValue(label)
            }
        }
    }
}

extension SessionController {
    /// The outlook label at a moment, from the daemon's record of the last request.
    func cacheOutlook(at date: Date) -> String? {
        let now = Int(date.timeIntervalSince1970 * 1000)
        return CacheWatch.outlook(last: cacheStamp?.use, lastAt: cacheStamp?.at, now: now)
    }

    /// Who this window acts as and in what role, from the attachment the session
    /// listed for this connection: `Loom Desktop · owner`.
    var who: String? {
        guard !role.isEmpty else { return nil }
        let name = peers.first { $0.id == connectionID }?.name
        return [name, role].compactMap { $0 }.joined(separator: " · ")
    }

    /// The Strands tab's title, with the number of strands waiting on a person.
    var strandsTabTitle: String {
        let waiting = strandLines.reduce(0) { $0 + $1.approvals }
        return waiting > 0 ? "Strands (\(waiting))" : "Strands"
    }
}
