import LoomKit
import MissionKit
import SwiftUI

// The session page's "Lifted from this session" rail and the strip above the
// transcript. The web view draws the rail beside the stream; here it is the lower
// section of the inspector, below the tabs, which stay above it as they do on the
// web (a recorded departure from the mockup, which has no tabs).
//
// `RailModel` is the page's own state: the session's feed row and the approval
// evidence, read about every five seconds while the page is open, and the one
// action in flight. What lifts, and in which order, is `MissionKit.LiftRule`; this
// file reads and draws. Model text (an ask's question, a find's text, an approval's
// action) is drawn with `Text(verbatim:)`.

/// What the page has read about one session's open records, and the action it has
/// sent from the rail.
@MainActor @Observable
final class RailModel {
    let sessionID: String

    /// The session's row from `sessions.attention`, kept when a read fails or the
    /// daemon does not read the session in time, so a slow read never empties the rail.
    private(set) var feed: AttentionRow?

    /// The pending approvals' evidence by record id: the raise time, the network and
    /// the policy today. Empty when no approval is pending.
    private(set) var evidence: [String: ApprovalEvidenceItem] = [:]

    /// The asks whose questions the rail has read, by ask id, for the forms it draws.
    private(set) var askRecords: [String: AttentionRecord] = [:]

    /// Why an ask's record could not be read, by ask id.
    private(set) var askWords: [String: String] = [:]

    /// The row an action is out for. One at a time, so a second press cannot be made.
    private(set) var sending: String?

    /// The word on the last action, drawn after the rows. Empty when there is none.
    private(set) var status = ""

    /// Whether the last timed read found an approval pending. A read after an action
    /// asks for the evidence again on that word, so it does not empty the evidence
    /// that the approval card draws its words from until the next timed read.
    private var hadApprovals = false

    /// How often the rail reads while the page is open. The daemon caches nothing
    /// and pushes nothing, and the web page reads at the same pace.
    static let refreshEvery: Duration = .seconds(5)

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// The raise time of each pending approval that carries one.
    var raised: [String: Int] {
        evidence.compactMapValues(\.raisedAt)
    }

    /// When the oldest pending approval was raised.
    var oldestRaised: Int? {
        raised.values.min()
    }

    /// Reads the feed row, and the approval evidence only while an approval waits.
    /// A refusal from an older daemon leaves what was read before in place.
    func refresh(control: ControlClient?, hasApprovals: Bool) async {
        guard let control else { return }
        hadApprovals = hasApprovals
        if let rows = try? await control.attention(sessions: [sessionID]), let row = rows[sessionID], row != feed {
            feed = row
        }
        guard hasApprovals else {
            if !evidence.isEmpty { evidence = [:] }
            return
        }
        if let read = try? await control.approvalEvidence(sessionID: sessionID) {
            let next = Dictionary(read.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if next != evidence { evidence = next }
        }
    }

    /// Reads an ask in full, for its form, and answers whether the read landed. A
    /// failed read keeps the record already held.
    @discardableResult
    func readAsk(id: String, control: ControlClient?) async -> Bool {
        guard let control else { return false }
        do {
            askRecords[id] = try await control.attentionRecord(sessionID: sessionID, id: id)
            askWords[id] = nil
            return true
        } catch {
            if askRecords[id] == nil { askWords[id] = error.localizedDescription }
            return false
        }
    }

    /// Reads the ask and the feed row again, after an answer changed or may have
    /// changed them.
    func rereadAsk(id: String, control: ControlClient?) async -> Bool {
        let landed = await readAsk(id: id, control: control)
        await refresh(control: control, hasApprovals: hadApprovals)
        return landed
    }

    /// Asks a stuck strand to retry, by sending it the fixed retry prompt on the
    /// session's own lane, as the web does. The strand must still be stuck in the
    /// feed row, and the lane refuses a strand it does not know.
    func retry(strand: String, controller: SessionController, control: ControlClient?) {
        let key = "stuck:\(strand)"
        guard sending == nil, feed?.stuck.items.contains(where: { $0.strand == strand }) == true else { return }
        sending = key
        status = ""
        Task {
            do {
                _ = try await controller.exchange("prompt", body: [
                    "strand": .string(strand), "text": .string(ThreadRule.retryPrompt),
                ])
                status = "Asked \(StrandName.display(strand)) to retry."
            } catch {
                status = error.localizedDescription
            }
            sending = nil
            await refresh(control: control, hasApprovals: hadApprovals)
        }
    }

    /// Settles a find at the revision read at the moment of the press. The daemon
    /// records the outcome and sends nothing to any strand. "File issue" records
    /// `filed` and nothing else, as the web does: no issue is created by this app.
    func close(find: String, outcome: FindOutcome, control: ControlClient?) {
        guard sending == nil, let control else { return }
        sending = "find:\(find)"
        status = ""
        Task {
            do {
                let record = try await control.attentionRecord(sessionID: sessionID, id: find)
                guard case .find(let detail) = record.detail, detail.mayClose else {
                    throw LoomError.protocolViolation("This find can no longer be closed.")
                }
                try await control.closeFind(sessionID: sessionID, find: find, revision: record.revision, outcome: outcome)
                status = outcome == .filed ? "Marked the find as filed." : "Dismissed the find."
            } catch {
                status = error.localizedDescription
            }
            sending = nil
            await refresh(control: control, hasApprovals: hadApprovals)
        }
    }
}

/// The rail: pinned rows under "Needs you", then the finds under "Insights". A
/// session with nothing lifted draws nothing, so a quiet session has no rail.
struct LiftedRail: View {
    let rows: [LiftedRow]
    let rail: RailModel
    let controller: SessionController
    let control: ControlClient?
    @State private var folded: Set<String> = []

    /// The buttons follow the connection's role: the owner and an operator press
    /// them, and an observer reads. The debug override lives in `isObserver`.
    private var mayAct: Bool {
        LiftRule.mayAct(role: controller.isObserver ? "observer" : controller.role)
    }

    var body: some View {
        let pinned = LiftRule.pinned(rows)
        let insights = LiftRule.insights(rows)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lifted from this session").font(Theme.label)
                Spacer(minLength: 4)
                Text(LiftRule.countWords(needing: pinned.count, insights: insights.count))
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            if !pinned.isEmpty {
                group("Needs you", gloss: "pinned until answered", rows: pinned)
            }
            if !insights.isEmpty {
                group("Insights", gloss: "fold once read", rows: insights)
            }
            if !rail.status.isEmpty {
                Text(rail.status).font(Theme.caption).foregroundStyle(.secondary)
            }
            if !mayAct {
                Quiet("You are watching, so the buttons are not offered.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lifted from this session")
    }

    private func group(_ title: String, gloss: String, rows: [LiftedRow]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(title) \u{00B7} \(rows.count)").font(Theme.caption.weight(.semibold))
                Text(gloss).font(Theme.caption).foregroundStyle(.tertiary)
            }
            ForEach(rows) { row in
                LiftedRowView(
                    row: row, isFolded: folded.contains(row.id), mayAct: mayAct,
                    isSending: rail.sending != nil, rail: rail, controller: controller, control: control
                ) {
                    folded.insert(row.id)
                }
            }
        }
    }
}

/// One lifted row: a chip with the kind's word, the time and source, then the row's
/// words, and the buttons the connection may press.
private struct LiftedRowView: View {
    let row: LiftedRow
    let isFolded: Bool
    let mayAct: Bool
    let isSending: Bool
    let rail: RailModel
    let controller: SessionController
    let control: ControlClient?
    let open: () -> Void
    @Environment(AppModel.self) private var model
    @State private var answering = false

    private var isPinned: Bool { row.hold == .pinned }

    /// The ask's identity, for the row of an ask.
    private var askID: String { String(row.id.dropFirst("ask:".count)) }

    /// Whether the daemon holding this session has refused to take an answer.
    private var cannotAnswer: Bool { model.daemon(holding: rail.sessionID)?.cannotTakeAnswers ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(row.word)
                    .font(Theme.label)
                    .foregroundStyle(isPinned ? Theme.attention : .secondary)
                Text(header).font(Theme.meta).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(verbatim: row.head)
                .font(Theme.caption)
                .lineLimit(isFolded ? 1 : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note { Text(note).font(Theme.caption).foregroundStyle(.secondary) }
            if mayAct { actions }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isPinned ? Theme.attention.opacity(0.09) : Theme.tint, in: .rect(cornerRadius: Theme.radiusInner))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusInner).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .contentShape(.rect)
        .onTapGesture {
            if !isPinned, !isFolded { open() }
        }
        .accessibilityElement(children: .contain)
    }

    /// The time the record was raised, then its source, joined by a dot. A record
    /// with no time says the source alone.
    private var header: String {
        [row.at.map { ClockTime.words($0) }, row.source.isEmpty ? nil : StrandName.display(row.source)]
            .compactMap { $0 }
            .joined(separator: " \u{00B7} ")
    }

    /// Where the row is answered, for the rows this app cannot act on.
    private var note: String? {
        switch row.kind {
        case .approval: return controller.isObserver ? "The operator decides." : "Decide in the card above the composer."
        case .ask:
            if cannotAnswer { return "An ask is answered in the web view. This app cannot send the answer yet." }
            return mayAct ? nil : "Only the owner or an operator can answer an ask."
        case .stuck, .find: return nil
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch row.kind {
        case .stuck(let strand):
            HStack(spacing: 8) {
                Button("Retry the last step") {
                    rail.retry(strand: strand, controller: controller, control: control)
                }
                if rail.sending == row.id { Text("Sending\u{2026}").font(Theme.caption).foregroundStyle(.secondary) }
            }
            .controlSize(.small)
            .disabled(isSending)
        case .find:
            let id = String(row.id.dropFirst("find:".count))
            HStack(spacing: 8) {
                Button("File issue") { rail.close(find: id, outcome: .filed, control: control) }
                Button("Dismiss") { rail.close(find: id, outcome: .dismissed, control: control) }
                if rail.sending == row.id { Text("Sending\u{2026}").font(Theme.caption).foregroundStyle(.secondary) }
            }
            .controlSize(.small)
            .disabled(isSending)
        case .ask:
            if !cannotAnswer { askActions }
        case .approval:
            EmptyView()
        }
    }

    /// An ask's Answer button opens its questions in the row. The record is read when
    /// the button is pressed, since the row carries only the first question's words.
    @ViewBuilder
    private var askActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(answering ? "Hide" : "Answer\u{2026}") {
                answering.toggle()
                if answering { Task { await rail.readAsk(id: askID, control: control) } }
            }
            .controlSize(.small)
            if answering {
                if let record = rail.askRecords[askID], case .ask(let ask) = record.detail {
                    AskAnswering(
                        sessionID: rail.sessionID, name: model.sessions.first { $0.id == rail.sessionID }?.title ?? "the session",
                        record: record, ask: ask, isObserver: controller.isObserver,
                        reread: { await rail.rereadAsk(id: askID, control: control) }
                    )
                } else {
                    Text(verbatim: rail.askWords[askID] ?? "Reading the ask\u{2026}").font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: The strip above the transcript

/// What the strand is doing, in a line above the transcript: a dot for the state
/// and words such as "running, turn 14m" or "stopped for an approval since 12:58".
///
/// The turn's age is redrawn once a minute by its own timeline, so no streamed
/// token touches it. The words come from `StreamWords`, and a time the daemon did
/// not record is left out and not invented.
struct StreamHead: View {
    let controller: SessionController
    let rail: RailModel

    private var liveness: AgentCard.Liveness {
        if !controller.escalations.isEmpty { return .needsYou }
        return controller.isBusy ? .working : .idle
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = Int(context.date.timeIntervalSince1970 * 1000)
            HStack(spacing: 8) {
                StatusDot(liveness: liveness)
                Text(StrandName.display(controller.focusedStrand)).font(Theme.label)
                Text(StreamWords.state(
                    pendingApprovals: controller.escalations.count,
                    raisedAt: rail.oldestRaised,
                    isBusy: controller.isBusy,
                    turnStartedAt: controller.turnStartedAt.map { Int($0.timeIntervalSince1970 * 1000) },
                    now: now
                ))
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(Theme.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Session state")
        }
    }
}

// MARK: The gutter

/// A row of the transcript with its clock time in the gutter, in the local zone.
/// The time is worded once from the row's own record time, which the daemon wrote,
/// and a row that carries none leaves the gutter empty so the text keeps its place.
struct GutterRow<Content: View>: View {
    /// The gutter's width, which the reading column adds to its own so the text
    /// keeps the width it had before there was a gutter.
    static var width: CGFloat { 44 }

    let at: Int?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(at.map { ClockTime.words($0) } ?? "")
                .font(Theme.meta)
                .foregroundStyle(.tertiary)
                .frame(width: Self.width, alignment: .leading)
                .accessibilityHidden(at == nil)
            content
        }
    }
}
