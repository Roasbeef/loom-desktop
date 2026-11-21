import LoomKit
import SwiftUI

/// A standing rule a model suggested, waiting for a person.
///
/// Nothing is written until a person approves, and what an approval writes is
/// `loom-rules.md`, which later sessions carry in their system prompt. The
/// sentence names the kind of change and the target, and the rule's text is
/// shown in full so the decision is about what will be written.
struct ProposalCard: View {
    let row: ProposalBoard.Row
    let controller: SessionController
    let compact: Bool
    @State private var confirms = false
    @State private var isExpanded = false

    /// A compact card always clips the change to a few lines, so the dock above
    /// the composer keeps its height. Opening it shows every line, why it was
    /// proposed and where from, in a popover that scrolls past its own height.
    /// Growing the dock in place instead pushed the composer out of the window
    /// for a long change.
    private var isClipped: Bool { compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "text.badge.plus").foregroundStyle(.secondary)
                Text("A strand proposes a \(row.kindWords)")
                    .font(Theme.label)
                Text("for \(row.target)").font(Theme.meta).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                if compact {
                    Button { isExpanded.toggle() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help(isExpanded ? "Show less" : "Show the whole change")
                    .accessibilityLabel(isExpanded ? "Collapse \(row.kindWords)" : "Expand \(row.kindWords)")
                    .popover(isPresented: $isExpanded, arrowEdge: .top) {
                        ProposalDetail(row: row)
                    }
                }
                if row.canDecide {
                    Button("Reject") { decide("reject") }
                        .accessibilityLabel("Reject \(row.kindWords)")
                    Button("Approve…") { confirms = true }
                        .accessibilityLabel("Approve \(row.kindWords)")
                } else if !row.isKnownKind {
                    Text("unknown kind").font(Theme.caption).foregroundStyle(Theme.attention)
                } else {
                    Text(row.state).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView(isClipped ? [] : .vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    if !row.old.isEmpty {
                        Text(row.old).font(Theme.code).foregroundStyle(Theme.removedText)
                            .lineLimit(isClipped ? 2 : nil)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(row.new).font(Theme.code).foregroundStyle(row.old.isEmpty ? Color.primary : Theme.addedText)
                        .lineLimit(isClipped ? 3 : nil)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: isClipped ? nil : 360)
            .fixedSize(horizontal: false, vertical: isClipped)
            if !isClipped, !row.rationale.isEmpty {
                Quiet("Why: " + PanelWords.oneLine(row.rationale))
            }
            if !isClipped {
                Quiet("From session \(row.session.prefix(8))" + (row.entry.map { ", entry \($0.prefix(8))" } ?? ""))
            }
        }
        .controlSize(.small)
        .padding(10)
        .surface(fill: Theme.tint)
        .confirmationDialog("Approve this \(row.kindWords)?", isPresented: $confirms) {
            Button("Approve and Write") { decide("approve") }
        } message: {
            Text(row.kind == "config"
                 ? "The configuration changes and the session reopens with it."
                 : "It is written to the rules file and reaches sessions opened afterwards, not this one.")
        }
    }

    private func decide(_ decision: String) {
        controller.run("proposal_decide", body: ["id": .string(row.id), "decision": .string(decision)])
    }
}

/// The whole of a proposed change, shown in a popover from the dock's card.
private struct ProposalDetail: View {
    let row: ProposalBoard.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(row.kindWords.capitalized) for \(row.target)").font(Theme.label)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !row.old.isEmpty {
                        Text(row.old).font(Theme.code).foregroundStyle(Theme.removedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(row.new).font(Theme.code).foregroundStyle(row.old.isEmpty ? Color.primary : Theme.addedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .textSelection(.enabled)
            }
            .frame(height: 300)
            if !row.rationale.isEmpty {
                Quiet("Why: " + PanelWords.oneLine(row.rationale))
            }
            Quiet("From session \(row.session.prefix(8))" + (row.entry.map { ", entry \($0.prefix(8))" } ?? ""))
        }
        .padding(14)
        .frame(width: 520)
    }
}

/// The Session tab's proposals section: what waits, and what was decided.
struct ProposalsSection: View {
    let board: ProposalBoard?
    let controller: SessionController

    var body: some View {
        Collapsing(isEmpty: board?.rows.isEmpty == true) {
            PanelSection("Proposals", trailing: {
                if let board, board.pending > 0 {
                    Text("\(board.pending)").font(Theme.meta).foregroundStyle(Theme.attention)
                        .accessibilityLabel("\(board.pending) proposals waiting")
                }
            }) {
                if let board {
                    if board.rows.isEmpty {
                        Quiet("No rules are proposed. A strand suggests one with its propose tool.")
                    }
                    ForEach(board.pendingRows) { ProposalCard(row: $0, controller: controller, compact: false) }
                    if !board.decidedRows.isEmpty {
                        DisclosureGroup("Decided (\(board.decidedRows.count))") {
                            ForEach(board.decidedRows) { ProposalCard(row: $0, controller: controller, compact: true) }
                        }
                        .font(Theme.label)
                    }
                    if board.omitted > 0 {
                        Quiet("\(board.omitted) older proposals are not shown.")
                    }
                } else if let error = controller.readFailures["proposals_get"] {
                    Quiet("Proposals are not available here: \(error)")
                } else {
                    Quiet("Not read yet.")
                }
            }
        }
    }
}
