import LoomKit
import MissionKit
import SwiftUI

// The Inbox's Updates group as cards, and the "Watch all" board of the same cards.
// An update is a session that is working and asks nothing of the owner, so its card
// shows what a person watching would look for: the state, the agent's latest message,
// the step it is on, and one line of what is around it. The rule is
// `MissionKit/UpdateCard.swift`; this file reads the daemon and draws.
//
// ## Flow
//
// `UpdateWatcher` holds one `UpdateDigest` for each session in Updates. While the inbox
// is on screen it reads one `session.brief` at a time, one every `UpdateWatch.pauseMs`,
// over at most `UpdateWatch.readCap` sessions, and drops the digest of a session that
// left Updates. `UpdateCardView` draws one card, compact in the list and expandable in
// place, or expanded on the board. `UpdateBoardView` lays the cards in a grid whose
// order `UpdateBoard.order` keeps, so a card does not move while it is watched.

/// The briefs the cards draw from. Nothing here is persisted.
///
/// One loop reads them, and it re-derives what to read on every lap from the rows the
/// board holds then, so a session that joins or leaves Updates needs no restart. Each
/// lap reads the session read longest ago and then waits `UpdateWatch.pauseMs`, which
/// is about one read a second in all, inside the daemon's six in four seconds for a
/// credential. The session whose pane is open is left out, since the pane reads its
/// brief itself and hands each one to `offer`, so the card and the pane show one read.
@MainActor
@Observable
final class UpdateWatcher {
    private(set) var digests: [String: UpdateDigest] = [:]

    /// The session whose open pane reads its own brief, which this loop then skips.
    var paneSession: String?

    /// Keeps a brief the open pane read, as if this loop had read it.
    func offer(_ brief: SessionBrief, session: String) {
        digests[session] = UpdateDigest(brief: brief)
    }

    /// Keeps the cards' briefs fresh while the inbox is drawn, for the sessions in Updates only.
    /// The read host spaces them: a brief is a surface read in turn, never-read first and then the
    /// longest ago, and the surfaces' period is the pause times the number of cards, which keeps the
    /// cards at about one read a second whatever their number and leaves the daemon's six in four
    /// seconds room for the open pane's own read.
    func run(model: AppModel, targets: [String]) async {
        let present = Set(UpdateWatch.targets(rows: model.board.rows))
        if digests.keys.contains(where: { !present.contains($0) }) { digests = digests.filter { present.contains($0.key) } }
        let period = UpdateWatch.pauseMs * max(1, targets.count)
        let entries = targets.map { id in
            ReadHost.Entry(.init(name: "update.brief", session: id, periodMs: period, budget: .brief)) {
                guard let control = model.daemon(holding: id)?.control, let brief = try? await control.brief(sessionID: id) else { return .failed }

                // A read that outlived the inbox must not write, and one for a session that left
                // Updates while it ran must not bring it back.
                guard !Task.isCancelled, present.contains(id) else { return .failed }
                let digest = UpdateDigest(brief: brief)
                if self.digests[id] != digest { self.digests[id] = digest }
                return .read
            }
        }
        await model.reads.hold(owner: "updates", entries)
    }
}

extension AppModel {
    /// The card of an Updates row, from what the daemon streams and the digest read.
    func updateCard(for row: InboxRow, digest: UpdateDigest?, now: Int) -> UpdateCard {
        let record = sessions.first { $0.id == row.sessionID }
        let machine = record.flatMap { placement(of: $0) }?.label
        return UpdateCard.make(row: row, activity: activity[row.sessionID], digest: digest, machine: machine, now: now)
    }
}

/// One card. In the list it shows the compact content and a disclosure that expands
/// it in place; on the board it is always expanded. Every word the session wrote is
/// drawn verbatim under a label that says so.
struct UpdateCardView: View {
    enum Layout { case list, board }

    @Environment(AppModel.self) private var model
    let card: UpdateCard
    let layout: Layout
    var selected = false

    /// Whether the owner expanded this card. The set is the inbox view's and is not
    /// saved, so a card scrolled out of the list keeps what the owner chose.
    private var expanded: Bool { model.expandedCards.contains(card.id) }

    private var isExpanded: Bool { layout == .board || expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let message = card.message { messageBlock(message) }
            stepBlock
            if isExpanded { detail } else { aside }
            if layout == .list { actions }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(fill: selected ? Theme.tintStrong : Theme.tint, radius: Theme.radius)
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(card.id)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: card.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                if layout == .list {
                    Button { withAnimation(.snappy(duration: 0.18)) { model.toggleCard(card.id) } } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .help(expanded ? "Collapse" : "Expand in place")
                    .accessibilityLabel(expanded ? "Collapse \(card.name)" : "Expand \(card.name)")
                }
            }
            Text(verbatim: card.state).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func messageBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "Latest message and step, untrusted text" + (card.messageAt.map { " \u{00B7} " + ClockTime.local($0) } ?? ""))
                .font(Theme.caption.weight(.semibold)).foregroundStyle(.tertiary).lineLimit(1)
            Text(verbatim: message)
                .font(.system(size: 12))
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// The step the session is on, in one line.
    @ViewBuilder
    private var stepBlock: some View {
        if let step = card.step, !isExpanded {
            stepLine(step)
        }
    }

    private func stepLine(_ step: UpdateStepLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isExpanded { Text(ClockTime.local(step.at)).font(Theme.meta).foregroundStyle(.secondary) }
            Image(systemName: Self.symbol(step.outcome)).font(Theme.caption)
                .foregroundStyle(step.outcome == .failed ? Theme.failure : .secondary)
            Text(verbatim: step.tool.text).font(Theme.code).lineLimit(1)
            Text(verbatim: step.words.text).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private static func symbol(_ outcome: BriefStep.Outcome) -> String {
        switch outcome {
        case .running: return "circle.dotted"
        case .succeeded: return "checkmark.circle"
        case .failed: return "xmark.circle"
        }
    }

    /// The compact card's one line: strands, a failed command and the machine.
    @ViewBuilder
    private var aside: some View {
        let parts = asideParts
        if !parts.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Text(verbatim: "\u{00B7}").foregroundStyle(.tertiary) }
                    Text(verbatim: part.words).foregroundStyle(part.isFailure ? Theme.failure : .secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(Theme.caption)
        }
    }

    private var asideParts: [(words: String, isFailure: Bool)] {
        var parts: [(String, Bool)] = []
        if let line = card.strandsLine { parts.append((line, false)) }
        if let failure = card.failure { parts.append((failure, true)) }
        if let machine = card.machine { parts.append((machine, false)) }
        return parts
    }

    /// The expanded card: the last steps, each strand with its glance, and the last
    /// command with its exit.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !card.steps.isEmpty {
                section("Last steps, untrusted text") {
                    ForEach(Array(card.steps.enumerated()), id: \.offset) { _, step in stepLine(step) }
                }
            }
            if !card.strands.isEmpty {
                section("Strands, glances are untrusted text") {
                    ForEach(card.strands, id: \.name) { strand in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: strand.name).font(Theme.code)
                            Text(verbatim: strand.state).font(Theme.caption).foregroundStyle(.secondary)
                            if let glance = strand.glance {
                                Text(verbatim: glance.text).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            } else if let line = card.strandsLine {
                Text(verbatim: line).font(Theme.caption).foregroundStyle(.secondary)
            }
            if let command = card.command, let exit = card.commandExit {
                section("Last command, untrusted text") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: command.text).font(Theme.code).lineLimit(2)
                        Text("exit \(exit)").font(Theme.caption).foregroundStyle(exit == 0 ? Color.secondary : Theme.failure)
                    }
                }
            }
            if let machine = card.machine { Text(verbatim: machine).font(Theme.caption).foregroundStyle(.secondary) }
            if layout == .board { actions }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.caption.weight(.semibold)).foregroundStyle(.tertiary)
            content()
        }
    }

    private var actions: some View {
        HStack {
            Button("Open Session") { model.destination = .session(card.sessionID) }
                .buttonStyle(.link).font(Theme.caption)
            Spacer(minLength: 0)
        }
    }
}

/// The "Watch all" board: one card for each working session, in a grid that fits the
/// width the pane has. A card opens that session's thread; the toolbar's toggle goes
/// back to a thread.
struct UpdateBoardView: View {
    @Environment(AppModel.self) private var model
    let rows: [InboxRow]
    let watcher: UpdateWatcher
    let now: Int

    /// The order the cards were first laid out in, which later changes keep.
    @State private var order: [String] = []

    private var cards: [UpdateCard] {
        let drawn = rows.filter { $0.group == .updates && !$0.isTicket }
        let all = drawn.map { model.updateCard(for: $0, digest: watcher.digests[$0.sessionID], now: now) }
        return all.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    var body: some View {
        let shown = cards
        Group {
            if shown.isEmpty {
                ContentUnavailableView(
                    "No session is working",
                    systemImage: "square.grid.2x2",
                    description: Text("Sessions that are working and ask nothing of you appear here as they start.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(shown) { card in
                            UpdateCardView(card: card, layout: .board)
                                .onTapGesture { open(card) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .accessibilityIdentifier("watch-board")
        .onChange(of: shown.map(\.id), initial: true) { _, ids in
            let next = UpdateBoard.order(previous: order, cards: shown)
            if next != order { order = next }
            #if DEBUG
            model.debugBoard = next
            #endif
        }
        .onDisappear {
            #if DEBUG
            model.debugBoard = []
            #endif
        }
    }

    private func open(_ card: UpdateCard) {
        model.inboxWatching = false
        model.chooseInbox(.thread(.session(card.sessionID)))
    }
}
