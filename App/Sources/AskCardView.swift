import LoomKit
import MissionKit
import SwiftUI

// The card a session page draws above its composer for each open ask that waits on
// the owner, and the "Ask" mark the transcript puts on the turn that raised it.
//
// An ask ends the agent's turn, and the owner reads and types in the transcript, so
// the question has to be there. It was drawn only in the Inbox and in the Inspector's
// rail, which starts hidden, and an owner who saw neither typed "continue", which the
// agent took as no answer. The card shows whether or not the Inspector is open.
//
// Which asks show and in what order is `MissionKit.AskCardRule`. The form is
// `AskAnswering`, the one the Inbox pane and the rail draw, so an ask is answered one
// way wherever it is read; an observer gets the same view with the words in place of
// the controls. Nothing here takes keyboard focus: a card that appeared while the
// owner was typing a message must not move the caret.
//
// ## Flow
//
// `AskCardView` reads the ask's record through the page's `RailModel`, which also
// reads the feed row about every five seconds. Sending an answer reads the feed row
// again, the ask is no longer in it, and `ComposerStack` stops drawing the card.

/// One open ask: its head, then its questions and Send.
struct AskCardView: View {
    @Environment(AppModel.self) private var model
    let card: AskCard
    let controller: SessionController
    let rail: RailModel

    /// The questions' height, so a long ask scrolls inside the card instead of
    /// pushing the transcript off the page.
    @State private var contentHeight: CGFloat = 120

    private static let tallest: CGFloat = 300

    private var control: ControlClient? { model.daemon(holding: rail.sessionID)?.control }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.attention)
                Text(AskCardRule.header(card, strand: StrandName.display(card.strand)))
                    .font(Theme.label)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            ScrollView {
                questions
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, Self.tallest))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radiusFloating))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask from \(StrandName.display(card.strand))")

        // The record holds the questions, which the feed row does not. A read that
        // fails is tried again, since the page would otherwise show a head and no way
        // to answer it.
        .task(id: card.id) {
            while !Task.isCancelled, rail.askRecords[card.id] == nil {
                if await rail.readAsk(id: card.id, control: control) { break }
                try? await Task.sleep(for: RailModel.refreshEvery)
            }
        }
    }

    @ViewBuilder
    private var questions: some View {
        if let record = rail.askRecords[card.id], case .ask(let ask) = record.detail {
            AskAnswering(
                sessionID: rail.sessionID,
                name: model.sessions.first { $0.id == rail.sessionID }?.title ?? "the session",
                record: record, ask: ask, isObserver: controller.isObserver,
                reread: { await rail.rereadAsk(id: card.id, control: control) }
            )
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: card.head).font(Theme.body).textSelection(.enabled)
                Text(verbatim: rail.askWords[card.id] ?? "Reading the ask\u{2026}")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The word on a transcript row or fold that raised an ask, so a reader scrolling the
/// transcript sees the turn put a question to them.
struct AskMark: View {
    var body: some View {
        Label("Ask", systemImage: "questionmark.bubble")
            .font(Theme.label)
            .foregroundStyle(Theme.attention)
            .accessibilityLabel("Ask")
    }
}

extension EnvironmentValues {
    /// The ids of the transcript blocks that raised an ask, from `AskCardRule`.
    @Entry var askingBlocks: Set<String> = []
}
