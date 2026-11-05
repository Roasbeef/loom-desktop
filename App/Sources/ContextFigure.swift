import LoomKit
import SwiftUI

/// The `ctx ~41%` figure in the composer's meta row, and the breakdown behind it.
///
/// The figure reads the daemon's `context` observation for the focused strand.
/// A read is asked for when the strand changes, when its run ends and when a
/// new entry lands, debounced so a run's calls cost one read. The web page
/// hides the dash before the main strand's first turn, because a dash there
/// reads as missing data, and this does the same.
struct ContextFigure: View {
    let controller: SessionController
    @State private var isOpen = false

    /// What makes the figure stale. The caller attaches the read to a view that
    /// is always drawn, because a task on a group with nothing to draw yet never
    /// runs, and the figure would never get its first board.
    struct Trigger: Equatable {
        let strand: String
        let isBusy: Bool
        let blocks: Int
    }

    var body: some View {
        let board = controller.context
        Group {
            if let board {
                button(board.footer)
            } else {
                // A failed or missing reading leaves a dash, so the figure never vanishes.
                button("ctx —")
            }
        }
    }

    private func button(_ words: String) -> some View {
        Button { isOpen.toggle() } label: {
            Text(words)
        }
        .buttonStyle(.plain)
        .help("Estimated context use of the strand shown. Open for the breakdown.")
        .accessibilityLabel("Context window")
        .accessibilityValue(words)
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            ContextPanel(controller: controller)
        }
    }
}

/// The breakdown: a stacked bar of where the window goes, the words for how the
/// figure was reached, the room left before the session compacts itself, and the
/// largest items. It can compact the session, which only an operator may do.
struct ContextPanel: View {
    let controller: SessionController
    @State private var compactMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Refresh") { refresh() }
                    .controlSize(.small)
                    .help("Read the context again from the session")
                Button("Compact Now") { compact() }
                    .controlSize(.small)
                    .disabled(controller.isBusy)
                    .help("Summarise older messages now, as /compact does")
                Spacer()
            }
            if let compactMessage {
                Quiet(compactMessage)
            }
            if let board = controller.context {
                BoardView(controller: controller, board: board, remote: controller.remoteUsage)
            } else {
                Quiet(controller.contextNotice.map { "Context unavailable: \(PanelWords.oneLine($0))" } ?? "Reading the context.")
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { refresh() }
    }

    private func refresh() {
        controller.read("context", body: ["strand": .string(controller.focusedStrand)])
    }

    /// Compaction is asked for by name on the focused strand. A refusal because
    /// there is nothing to compact is an answer, so it is worded and not shown
    /// as a failure.
    private func compact() {
        compactMessage = nil
        let strand = controller.focusedStrand
        Task {
            do {
                _ = try await controller.exchange("compact", body: ["strand": .string(strand)])
                compactMessage = "Compacting. The figure updates when it finishes."
            } catch {
                compactMessage = error.localizedDescription
            }
        }
    }
}

private struct BoardView: View {
    let controller: SessionController
    let board: ContextBoard
    let remote: [RemoteUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SessionFigures(controller: controller)
            Divider()
            Text(board.headline).font(.system(size: 13, weight: .semibold))
            Quiet(board.basisWords)
            StackedBar(board: board)
            Legend(board: board)
            Text(board.untilCompaction).font(Theme.caption)
            Quiet("The rows are estimated one by one, so they need not add up to the figure above. Hooks and text not yet sent are not counted.")
            Inventory(board: board)
            if !remote.isEmpty {
                Divider()
                Text("Children on other orchestrators").font(Theme.label)
                ForEach(remote) { entry in
                    Text(entry.words).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            Quiet("\(PanelWords.oneLine(board.model)) · strand \(PanelWords.oneLine(board.strand)) · observed at durable sequence \(board.asOf).")
        }
    }
}

/// The session's model, tokens, speed and cost, which the composer's bar used to
/// carry. They are read here, behind the context figure, so the bar holds one
/// figure and the input stays the widest thing in the composer.
private struct SessionFigures: View {
    let controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let model = controller.strand?.model {
                row("Model", model, label: "Model")
            }
            if let tokens = controller.totalTokens, tokens > 0 {
                row("Tokens", "\(tokens.formatted(.number.notation(.compactName))) tokens", label: "Tokens")
            }
            if let rate = controller.outputRate {
                row("Speed", "\(rate) tok/s", label: "Output speed")
            }
            let cost = UsageWords.estimate(usage: controller.usage)
            if !cost.hasSuffix("—") {
                row("Cost", cost, label: "Estimated cost")
            }
        }
        .font(Theme.caption)
    }

    private func row(_ name: String, _ value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        // The value is in the label: a combined static row does not report its value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// One segment per part that holds tokens, each as wide as its share of the
/// window, and the legend beneath names every segment. The three parts a person
/// can act on (the system prompt, the tools and the messages) each have a hue;
/// what is not itemised and the compaction reserve stay grey. Amber and red are
/// left out, because elsewhere they mean waiting and failed.
private struct StackedBar: View {
    let board: ContextBoard

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(board.parts) { part in
                    Rectangle()
                        .fill(Self.fill(part.kind))
                        .frame(width: max(2, proxy.size.width * CGFloat(part.tokens) / CGFloat(board.window)))
                }
                Spacer(minLength: 0)
            }
            .clipShape(.rect(cornerRadius: 3))
        }
        .frame(height: 10)
        .background(Theme.tint, in: .rect(cornerRadius: 3))
        .accessibilityElement()
        .accessibilityLabel("How the context window is used")
        .accessibilityValue(board.footer)
    }

    static func fill(_ kind: ContextBoard.Part.Kind) -> Color {
        switch kind {
        case .system: return Theme.adaptive(light: 0x2F6FDB, dark: 0x5B9BF7)
        case .tools: return Theme.adaptive(light: 0x12867A, dark: 0x3CCBB8)
        case .messages: return Theme.adaptive(light: 0x7A4FD6, dark: 0xA88BF5)
        case .unattributed: return Color.primary.opacity(0.18)
        case .reserve: return Color.primary.opacity(0.09)
        case .free: return Color.clear
        }
    }
}

private struct Legend: View {
    let board: ContextBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(board.parts) { part in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(StackedBar.fill(part.kind))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.hairline, lineWidth: 0.5))
                        .frame(width: 9, height: 9)
                    Text(part.name).font(Theme.caption)
                    Spacer(minLength: 6)
                    Text(PanelWords.count(part.tokens)).font(Theme.meta)
                    Text(board.share(part)).font(Theme.meta).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The tools by name and the messages by kind, largest first and bounded, with a
/// line saying how many rows the observation left out. The figures above count
/// the omitted ones.
private struct Inventory: View {
    let board: ContextBoard
    private let shown = 8

    var body: some View {
        DisclosureGroup("What is in the context") {
            VStack(alignment: .leading, spacing: 8) {
                group("Tools", board.tools)
                group("Messages", board.messageKinds)
                if board.omitted > 0 {
                    Quiet("\(board.omitted) items are left out of this list by the observation's size limit; the figures above count them.")
                }
            }
            .padding(.top, 4)
        }
        .font(Theme.label)
    }

    @ViewBuilder
    private func group(_ title: String, _ rows: [ContextBoard.Group]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.caption).foregroundStyle(.secondary)
                ForEach(rows.prefix(shown)) { row in
                    HStack {
                        Text(row.label + (row.count > 1 ? " ×\(row.count)" : "")).font(Theme.meta).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("~" + PanelWords.count(row.tokens)).font(Theme.meta).foregroundStyle(.secondary)
                    }
                }
                if rows.count > shown {
                    Quiet("\(rows.count - shown) more")
                }
            }
        }
    }
}
