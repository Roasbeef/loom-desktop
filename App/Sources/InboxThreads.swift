import LoomKit
import MissionKit
import SwiftUI

// The inbox's reading pane: what the open thread says, by kind. The words and the
// read plan are `ThreadRule`, which is pure and tested; this file draws them.
//
// Every word a model or another session wrote (a brief's message, a step, an ask's
// question, a find's text, a peer message) is drawn with `Text(verbatim:)` under a
// label that says whose words they are. Nothing here parses model text as markup.
//
// ## Flow
//
// `InboxPane` is the pane: a scrolling body over a message bar. `ThreadReader`
// holds what the daemon said about the open thread, read once when it opens and
// again every fifteen seconds while it stays open. The body is chosen by the kind
// of row: an approval draws its evidence over the live Allow and Deny card, an ask
// its questions as controls (`AskAnswer.swift`) for a person who may answer, a stuck strand its failure and Retry, a find its text
// and the ways to close it, and a session's own thread its brief.

// MARK: What the daemon said about the open thread

/// The reads of one open thread. One reader serves one pane, and a new thread gets
/// a new reader, so a read for a thread that closed never lands on its successor.
///
/// A brief read that fails keeps the brief already held, since the daemon allows
/// six reads in four seconds for a credential and a refusal says nothing new about
/// the session. A pane opened by a quick walk down the list waits a moment before
/// it reads, so the walk starts no read for the rows it passes.
@MainActor
@Observable
final class ThreadReader {
    private(set) var brief: SessionBrief?
    private(set) var briefSince: Int?
    private(set) var briefWords: String?
    private(set) var evidence: ApprovalEvidence?
    private(set) var evidenceWords: String?
    private(set) var record: AttentionRecord?
    private(set) var recordWords: String?
    private(set) var review: ReviewRead?
    private(set) var reviewWords: String?
    private(set) var findReads: [String: FindRead] = [:]

    /// How long a pane waits before its first read.
    private static let settle: Duration = .milliseconds(350)

    func run(reads: ThreadReads, session: String, control: ControlClient?) async {
        guard let control, reads.approval || reads.brief || reads.record != nil else { return }
        try? await Task.sleep(for: Self.settle)
        var last: BriefRead?

        // The worktree is read once: it runs Git on the session's helper pool, which the
        // agent's own tools share, and the refresh below would repeat it every fifteen
        // seconds.
        if reads.review { await readReview(control, session) }

        repeat {
            if Task.isCancelled { return }
            if reads.approval { await readEvidence(control, session) }
            if reads.brief { await readBrief(control, session, last: &last) }
            if let id = reads.record { await readRecord(control, session, id) }
            try? await Task.sleep(for: .milliseconds(ThreadRule.refreshMs))
        } while !Task.isCancelled
    }

    private func readEvidence(_ control: ControlClient, _ session: String) async {
        do {
            evidence = try await control.approvalEvidence(sessionID: session)
            evidenceWords = nil
        } catch {
            if evidence == nil { evidenceWords = error.localizedDescription }
        }
    }

    /// The brief's peer messages are those after the raise time of the oldest
    /// pending approval, so the read asks after that time, and after the time of the
    /// last read when the evidence is not held.
    private func readBrief(_ control: ControlClient, _ session: String, last: inout BriefRead?) async {
        let since = evidence?.oldestRaised ?? last?.since ?? 0
        let now = Int(Date().timeIntervalSince1970 * 1000)
        guard ThreadRule.briefDue(last: last, now: now, since: since) else { return }
        last = BriefRead(started: now, since: since)
        do {
            brief = try await control.brief(sessionID: session, since: since)
            briefSince = since
            briefWords = nil
        } catch {
            if brief == nil { briefWords = error.localizedDescription }
        }
    }

    /// Reads the ask or find, and answers whether the read landed. A failed read keeps
    /// the record already held.
    @discardableResult
    func readRecord(_ control: ControlClient, _ session: String, _ id: String) async -> Bool {
        do {
            record = try await control.attentionRecord(sessionID: session, id: id)
            recordWords = nil
            return true
        } catch {
            if record == nil { recordWords = error.localizedDescription }
            return false
        }
    }

    /// Reads the record the form answers, for a form that has just sent.
    func refreshAsk(control: ControlClient?, session: String, id: String) async -> Bool {
        guard let control else { return false }
        return await readRecord(control, session, id)
    }

    /// The session's worktree as a review. A refusal for the credential's allowance of
    /// workspace reads says nothing about the session, so it is waited out and tried
    /// again, twice at most, the way the scan does; any other failure is the words the
    /// pane shows beside Read again.
    func readReview(_ control: ControlClient, _ session: String) async {
        reviewWords = nil
        for attempt in 0..<ReviewScan.maxAttempts {
            do {
                review = try await control.review(sessionID: session)
                return
            } catch is CancellationError {
                return
            } catch {
                let words = ComposerModel.words(error)
                var code: String?
                if case LoomError.server(let found, _, _) = error { code = found }
                let failure = ReviewScan.Failure(code: code, message: words)
                reviewWords = words
                guard failure == .busy, attempt + 1 < ReviewScan.maxAttempts else { return }
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { return }
            }
        }
    }

    /// The revision of each find the review draws, which a close names. Each is read
    /// once and in turn, and one that failed says why and is not read again until the
    /// pane is opened afresh.
    func readFinds(_ ids: [String], control: ControlClient?, session: String) async {
        guard let control else { return }
        for id in ids where findReads[id] == nil {
            findReads[id] = .reading
            do {
                let record = try await control.attentionRecord(sessionID: session, id: id)
                var mayClose = false
                if case .find(let find) = record.detail { mayClose = find.mayClose }
                findReads[id] = .read(revision: record.revision, mayClose: mayClose)
            } catch is CancellationError {
                findReads[id] = nil
                return
            } catch {
                findReads[id] = .unread(ComposerModel.words(error))
            }
        }
    }

    /// Forgets a find's revision after the daemon refused a close at it, so the next
    /// pass reads the find afresh and the owner stages against what is there now.
    func forgetFind(_ id: String) { findReads[id] = nil }

    /// The peer messages the pane may draw: only for an approval whose brief was read
    /// after that approval's own raise time.
    var peers: [BriefPeer] {
        guard let brief, ThreadRule.peersShown(readSince: briefSince, raised: evidence?.oldestRaised) else { return [] }
        return brief.peers
    }
}

// MARK: The pane

/// The reading pane of one open thread.
struct InboxPane: View {
    @Environment(AppModel.self) private var model
    let row: InboxRow
    /// What `Mission.attention` holds for the session: its pending approvals or its
    /// failed run.
    let items: [AttentionItem]
    @Binding var draft: String
    @State private var reader = ThreadReader()
    @State private var outcome = SendOutcome.unsent
    @State private var outbox = ReviewOutbox()

    /// How many times the owner has asked to write to this thread's session. The
    /// message bar focuses its field on each, and one that arrived before the bar
    /// existed is still met.
    @State private var messageRequests = 0

    private var sessionID: String { row.sessionID }

    private var reads: ThreadReads { ThreadRule.reads(for: row) }

    private var activity: SessionActivity? { model.daemon(holding: sessionID)?.activity[sessionID] }

    private var feedRow: AttentionRow? { model.attentionRows[sessionID] }

    /// Whether this connection only watches the session, as the rail's gate reads it.
    /// A session not attached yet has no role to read, and a send attaches it and is
    /// refused there when the role is an observer's.
    private var isObserver: Bool { model.controller(for: sessionID)?.isObserver ?? false }

    /// What Retry does for the stuck strand this thread is about.
    private var retry: ThreadRule.RetryOffer {
        ThreadRule.retryOffer(
            isObserver: isObserver,
            stuckListed: feedRow?.stuck.items.contains { $0.strand == strand } == true,
            sending: model.retrying.contains(row.id)
        )
    }

    /// The strand a message goes to: the one the record is about, else main.
    private var strand: String {
        switch row.subject {
        case .ask(_, let id): return feedRow?.asks.items.first { $0.id == id }?.strand ?? "main"
        case .stuck(_, let strand): return strand
        case .find(_, let id): return feedRow?.finds.items.first { $0.id == id }?.strand ?? "main"
        case .session, .ticket: return "main"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                    HStack {
                        Button("Open Session") { model.destination = .session(sessionID) }
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.return, modifiers: .command)
                        if case .stuck = row.subject, retry != .hidden {
                            Button("Retry") { retryStrand() }
                                .buttonStyle(.bordered)
                                .disabled(retry == .disabled)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if row.kind == .review, reader.review != nil {
                OutboxBar(
                    name: row.name, acting: !isObserver, outbox: outbox,
                    clear: { outbox.clear() },
                    send: { sendReview() }
                )
            } else if ThreadRule.offersMessage(kind: row.kind, hasReview: reader.review != nil, isObserver: isObserver) {
                MessageBar(
                    name: row.name, kind: row.kind, draft: $draft, outcome: outcome, focusRequests: messageRequests,
                    send: { choice in send(text: draft, choice: choice, strand: strand) }
                )
            } else if isObserver {
                Text(verbatim: SessionController.observerWords)
                    .font(Theme.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.vertical, 10)
            }
        }
        .accessibilityIdentifier("inbox-pane/\(row.id)")

        // The Inbox menu's "Message Session" names this thread by row id, and the pane
        // that draws it takes the request, so it is met whichever window shows it.
        // Every pane that shows the row focuses its own field, and the request is cleared
        // on the next main-actor turn, after each of them has seen it. Clearing it at
        // once would leave the field to whichever pane observed it first.
        .onChange(of: model.messageRequest, initial: true) {
            guard model.messageRequest == row.id else { return }
            messageRequests += 1
            let id = row.id
            Task { @MainActor in if model.messageRequest == id { model.messageRequest = nil } }
        }
        // The reads follow the kind as well as the row: a session opened as "Waiting" becomes
        // "To review" once the scan has read its tree, and the review is read only for the
        // second, so a task keyed on the row alone would never read it.
        .task(id: "\(row.id)/\(row.kind.chip)") {
            await reader.run(reads: reads, session: sessionID, control: model.daemon(holding: sessionID)?.control)
        }
        .task(id: findIDs) {
            await reader.readFinds(findIDs, control: model.daemon(holding: sessionID)?.control, session: sessionID)
        }
    }

    // MARK: Header

    private var raised: Int? { reader.evidence?.oldestRaised ?? model.approvalRaised[sessionID] }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.kind.chip)
                    .font(Theme.caption)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.tintStrong, in: .rect(cornerRadius: 4))
                Text(verbatim: eyebrow).font(Theme.meta).foregroundStyle(.secondary)
            }
            title.font(.system(size: 20, weight: .semibold)).textSelection(.enabled).lineLimit(3)
            if let age = row.age, !row.isFind {
                Text("waiting \(age.words)").font(Theme.meta).foregroundStyle(.secondary)
            }
        }
    }

    /// The session's name, where it runs and the strand the record is about, then
    /// the time the thread dates, or what the session is doing.
    private var eyebrow: String {
        var words = row.name
        if let record = model.sessions.first(where: { $0.id == sessionID }), let placement = model.placement(of: record) {
            words += " \u{00B7} " + placement.label
        }
        switch row.subject {
        case .ask, .stuck, .find: words += " \u{00B7} " + strand
        case .session, .ticket: break
        }
        if row.kind == .working {
            words += " \u{00B7} " + (row.since.map { "working, " + ThreadRule.turnWords(started: $0, now: Self.nowMs) } ?? "working")
        } else if let moment = ThreadRule.moment(for: row, raised: raised) {
            words += " \u{00B7} \(moment.label) \(ClockTime.local(moment.at))"
        } else {
            words += " \u{00B7} " + Self.stateWords(row.kind)
        }
        return words
    }

    private static var nowMs: Int { Int(Date().timeIntervalSince1970 * 1000) }

    private static func stateWords(_ kind: InboxKind) -> String {
        switch kind {
        case .approval: return "waiting on an approval"
        case .failed: return "its last run failed"
        case .waiting, .review: return "idle, finished"
        case .working: return "working"
        case .quiet: return "quiet"
        case .ask, .stuck, .find, .ticket: return ""
        }
    }

    @ViewBuilder
    private var title: some View {
        switch row.subject {
        case .stuck:
            if let stuck = feedRow?.stuck.items.first(where: { $0.strand == strand }) {
                Text(verbatim: ThreadRule.stuckTitle(reason: stuck.reason))
            } else {
                Text(verbatim: row.head)
            }
        case .session where row.kind == .review:
            // The row's head is the agent's last message, which is quoted under its own
            // label below and is never a headline here. The web falls back to the head
            // until the review's title arrives; the desktop differs on purpose, so text
            // a model wrote is never drawn as a headline, unlabelled, in a larger size.
            // A review not read, or whose read failed, is titled in the app's own words.
            if let review = reader.review {
                Text(verbatim: ReviewRule.title(review.stat))
            } else {
                Text(verbatim: "Ready to review")
            }
        case .session where row.kind == .waiting || row.kind == .working:
            Text(verbatim: row.kind == .working ? "Working" : "Idle, finished")
        case .session where row.kind == .failed:
            // The failure's own words are in the body, under the item's title.
            Text(verbatim: "Its last run failed.")
        case .session where row.kind == .approval:
            if let item = reader.evidence?.items.first, let parts = ThreadRule.approvalTitle(item) {
                parts.reduce(Text(verbatim: "")) { text, part in
                    switch part {
                    case .words(let words): Text("\(text)\(Text(verbatim: words))")
                    case .code(let code): Text("\(text)\(Text(verbatim: code).font(.system(size: 18, weight: .semibold).monospaced()))")
                    }
                }
            } else {
                Text(verbatim: ThreadRule.approvalFallbackTitle)
            }
        default:
            Text(verbatim: row.head)
        }
    }

    // MARK: Body by kind

    @ViewBuilder
    private var content: some View {
        switch row.subject {
        case .ask: askBody
        case .stuck: stuckBody
        case .find: findBody
        case .ticket: EmptyView()
        case .session:
            switch row.kind {
            case .approval: approvalBody
            case .failed: failedBody
            case .review: reviewBody
            case .waiting, .working: sessionBody
            case .quiet, .ask, .stuck, .find, .ticket: EmptyView()
            }
        }
    }

    private var approvalBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let read = reader.evidence {
                PaneSection("What it asks for") {
                    ForEach(read.items) { item in FactsCard(rows: ThreadRule.evidenceRows(item)) }
                    if read.count > read.items.count {
                        Text("\(read.count - read.items.count) more pending on the session's page.")
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                    if read.oldestRaised == nil {
                        Text("The record carries no time, so no age is shown.").font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let words = reader.evidenceWords {
                Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary)
            }
            if !reader.peers.isEmpty {
                PaneSection("In this session since it asked") {
                    ForEach(Array(reader.peers.enumerated()), id: \.offset) { _, peer in PeerQuote(peer: peer) }
                }
            }
            PaneSection("Decide") {
                ForEach(items) { AttentionItemBody(item: $0) }
            }
            .environment(\.approvalContentAbove, [reader.evidence?.items.count ?? 0, reader.evidenceWords == nil ? 0 : 1, reader.peers.count])
        }
    }

    private var failedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing is running.").font(Theme.caption).foregroundStyle(.secondary)
            ForEach(items) { AttentionItemBody(item: $0) }
        }
    }

    private var askBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let text = reader.brief?.assistant?.text, !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let at = reader.brief?.assistant?.at {
                PaneSection("Where it stopped") {
                    QuoteBox(source: "The agent's latest message, untrusted text \u{00B7} \(ClockTime.local(at))", words: text.text)
                }
            }
            CoordinatorCard(brief: reader.brief)
            PaneSection("What it asks for") {
                if let record = reader.record, case .ask(let ask) = record.detail {
                    if let why = ask.why { QuoteBox(source: "The agent asks, untrusted text", words: why) }
                    AskAnswering(
                        sessionID: sessionID, name: row.name, record: record, ask: ask, isObserver: isObserver,
                        reread: { await reader.refreshAsk(control: model.daemon(holding: sessionID)?.control, session: sessionID, id: record.id) }
                    )
                } else {
                    Text(verbatim: reader.recordWords ?? "Reading the ask\u{2026}").font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stuckBody: some View {
        PaneSection("What the page knows") {
            if let stuck = feedRow?.stuck.items.first(where: { $0.strand == strand }) {
                Text(verbatim: ThreadRule.render(ThreadRule.stuckPhrase(stuck))).font(Theme.body).textSelection(.enabled)
                if let parent = stuck.parent { FactsCard(rows: [EvidenceRow(label: "Parent", value: parent, isCode: false)]) }
            } else {
                Text("The daemon no longer lists this strand as stuck.").font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var findBody: some View {
        PaneSection("Noticed along the way") {
            if case .find(_, let id) = row.subject, let head = feedRow?.finds.items.first(where: { $0.id == id }) {
                let full: String? = {
                    if let record = reader.record, case .find(let find) = record.detail { return find.text }
                    return nil
                }()
                QuoteBox(source: "The agent noticed (\(head.kind.rawValue)), untrusted text", words: full ?? head.head)
                if let path = head.path {
                    Text(verbatim: head.line.map { "\(path):\($0)" } ?? path).font(Theme.code).textSelection(.enabled)
                }
            }
            FindActions(sessionID: sessionID, record: reader.record, words: reader.recordWords)
        }
    }

    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Until the review is read, the scan's size line says how large the change is.
            if reader.review == nil {
                Text(verbatim: reviewWords).font(Theme.body)
            }
            ReviewThread(
                review: reader.review, words: reader.reviewWords,
                commandWords: reader.brief?.command.map { ThreadRule.commandWords($0) },
                finds: feedRow?.finds.items ?? [], reads: reader.findReads, acting: !isObserver,
                outbox: $outbox,
                readAgain: {
                    let id = sessionID
                    guard let control = model.daemon(holding: id)?.control else { return }
                    Task { await reader.readReview(control, id) }
                }
            ) {
                LastMessage(activity: activity, brief: reader.brief, working: false)
            }
        }
    }

    /// The ids of the finds the review may draw, which the revisions are read for.
    private var findIDs: [String] {
        row.kind == .review ? (feedRow?.finds.items.map(\.id) ?? []) : []
    }

    /// The change's size from the worktree scan, or what the scan has not yet said.
    private var reviewWords: String {
        guard let message = reviewMessage else { return "Nothing to read." }
        return ThreadRule.reviewWords(
            stat: model.reviewStat(of: sessionID, message: message),
            isUnreadable: model.reviewIsUnreadable(of: sessionID, message: message),
            finds: feedRow?.finds.count ?? 0
        )
    }

    private var reviewMessage: String? { activity.flatMap { InboxRule.said($0) } }

    private var sessionBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            LastMessage(activity: activity, brief: reader.brief, working: row.kind == .working)
            if let steps = reader.brief?.steps, !steps.isEmpty {
                PaneSection("Last few steps") { StepsCard(steps: steps) }
            } else if let glances = activity?.glances, !glances.isEmpty {
                PaneSection("What its strands are doing") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(glances) { glance in
                            Text(verbatim: (glance.title.isEmpty ? glance.strand : glance.title) + ": " + glance.summary)
                                .font(Theme.caption).textSelection(.enabled)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).surface()
                }
            }
            CoordinatorCard(brief: reader.brief)
            if let command = reader.brief?.command {
                Text(verbatim: ThreadRule.commandWords(command)).font(Theme.code).textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 3).surface(radius: Theme.radiusInner)
            }
            if let words = reader.briefWords, reader.brief == nil {
                Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sending

    /// Sends the staged review: each find close in turn, then the one prompt, as
    /// `ReviewOutbox` asks. A close the daemon refuses halts the Send with nothing
    /// said to the agent, and its find is read afresh.
    private func sendReview() {
        guard let review = reader.review else { return }
        var step = outbox.send(files: ReviewRule.ordered(review.files).map(\.path))
        guard step != .halted else { return }
        let id = sessionID
        let name = row.name
        Task {
            while step != .halted {
                switch step {
                case .close(let find, let revision, let found):
                    let result = await closeFind(session: id, find: find, revision: revision, outcome: found)
                    if !result.isDone { reader.forgetFind(find) }
                    step = outbox.closed(result)
                case .prompt(let text):
                    outbox.prompted(await deliver(text, session: id, name: name))
                    step = .halted
                case .halted:
                    break
                }
            }
            if let control = model.daemon(holding: id) {
                await control.readAttentionNow()
            }
            await reader.readFinds(findIDs, control: model.daemon(holding: id)?.control, session: id)
        }
    }

    private func closeFind(session: String, find: String, revision: Int, outcome: FindOutcome) async -> ReviewCloseResult {
        guard let control = model.daemon(holding: session)?.control else {
            return ReviewCloseResult(find: find, outcome: outcome, isDone: false, words: "The session is not running.")
        }
        do {
            try await control.closeFind(sessionID: session, find: find, revision: revision, outcome: outcome)
            return ReviewCloseResult(find: find, outcome: outcome, isDone: true, words: "Closed as \(outcome.rawValue).")
        } catch {
            return ReviewCloseResult(find: find, outcome: outcome, isDone: false, words: ComposerModel.words(error))
        }
    }

    /// The review's prompt goes to the session's main strand, which is what the web's
    /// Send does. A verdict is words in it and not a command of its own.
    private func deliver(_ text: String, session: String, name: String) async -> ReviewPromptResult {
        do {
            let status = try await model.sendMessage(sessionID: session, strand: "main", text: text, choice: .send)
            return .delivered(ThreadSend.deliveredWords(status: status, choice: .send, name: name))
        } catch LoomError.outcomeUnknown {
            return .refused(ThreadSend.unansweredWords)
        } catch {
            return .refused(ThreadSend.refusedWords(ComposerModel.words(error)))
        }
    }

    /// Retries through the model, which holds the row while one is out, so the menu's
    /// Retry and this button cannot queue two.
    private func retryStrand() {
        guard !model.retrying.contains(row.id) else { return }
        outcome = .sending
        Task { outcome = .said(await model.retry(row).words) }
    }

    private func send(text: String, choice: ThreadSend.Choice, strand: String) {
        guard ThreadSend.sendable(text), !outcome.isSending else { return }
        outcome = .sending
        let id = sessionID
        let name = row.name
        Task {
            do {
                let status = try await model.sendMessage(sessionID: id, strand: strand, text: text, choice: choice)

                // The feed row may still list the strand as stuck for up to its refresh
                // period. Reading it before the button comes back keeps a second press
                // from queueing a duplicate retry against a row the daemon has cleared.
                if case .stuck = row.subject { await model.daemon(holding: id)?.readAttentionNow() }
                outcome = .said(ThreadSend.deliveredWords(status: status, choice: choice, name: name))
                if text == draft { draft = "" }
            } catch LoomError.outcomeUnknown {
                outcome = .said(ThreadSend.unansweredWords)
            } catch {
                outcome = .said(ThreadSend.refusedWords(ComposerModel.words(error)))
            }
        }
    }
}

// MARK: The message bar

/// What the bar says about the last send from this pane.
enum SendOutcome: Equatable {
    case unsent
    case sending
    case said(String)

    var isSending: Bool { self == .sending }
}

/// The bar at the foot of the pane: a message for the thread's session, the buttons
/// its kind offers, and what the last send did. A message to a session awaiting an
/// approval starts a new turn now.
private struct MessageBar: View {
    let name: String
    let kind: InboxKind
    @Binding var draft: String
    let outcome: SendOutcome
    let focusRequests: Int
    let send: (ThreadSend.Choice) -> Void
    @FocusState private var isWriting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            // A session's name is text a person or a model wrote, so the prompt and
            // the label are verbatim and a name is never read as markup.
            TextField(text: $draft, prompt: Text(verbatim: "Message \(name)\u{2026}"), axis: .vertical) { EmptyView() }
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...5)
                .padding(.horizontal, 24)
                .focused($isWriting)
                .onChange(of: focusRequests, initial: true) { _, count in if count > 0 { isWriting = true } }
                .accessibilityLabel(Text(verbatim: "Message to \(name)"))
            HStack(spacing: 8) {
                Text(verbatim: statusWords).font(Theme.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 8)
                ForEach(ThreadSend.choices(for: kind), id: \.label) { choice in
                    Button(choice.label) { send(choice) }
                        .buttonStyle(.bordered)
                        .disabled(!ThreadSend.sendable(draft) || outcome.isSending)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
    }

    private var statusWords: String {
        switch outcome {
        case .sending: return "Sending\u{2026}"
        case .said(let words): return words
        case .unsent: return ThreadSend.holdNote(for: kind) ?? ""
        }
    }
}

// MARK: Find actions

/// The ways to settle a find. The daemon says whether this principal may close it
/// (`may_close`), so an observer sees the words and no buttons. Closing sends
/// nothing to any strand; it records the outcome.
private struct FindActions: View {
    @Environment(AppModel.self) private var model
    let sessionID: String
    let record: AttentionRecord?
    let words: String?
    @State private var said: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let record, case .find(let find) = record.detail {
                if find.mayClose {
                    HStack {
                        close("Fixed", .fixed, record)
                        close("Filed", .filed, record)
                        close("Dismiss", .dismissed, record)
                    }
                } else if let closure = find.closure {
                    Text(verbatim: "Closed as \(closure.outcome).").font(Theme.caption).foregroundStyle(.secondary)
                } else {
                    Text("Only the owner or an operator can close a find.").font(Theme.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(verbatim: words ?? "Reading the find\u{2026}").font(Theme.caption).foregroundStyle(.secondary)
            }
            if let said { Text(verbatim: said).font(Theme.caption).foregroundStyle(.secondary) }
        }
    }

    private func close(_ label: String, _ outcome: FindOutcome, _ record: AttentionRecord) -> some View {
        Button(label) {
            working = true
            Task {
                defer { working = false }
                guard let daemon = model.daemon(holding: sessionID), let control = daemon.control else { return }
                do {
                    try await control.closeFind(sessionID: sessionID, find: record.id, revision: record.revision, outcome: outcome)
                    said = "Closed as \(outcome.rawValue)."
                    await daemon.readAttentionNow()
                } catch {
                    said = ComposerModel.words(error)
                }
            }
        }
        .buttonStyle(.bordered)
        .disabled(working)
    }
}

// MARK: Parts

/// A sentence-case heading over its parts. Every section of the pane uses it, so the
/// pane has one heading style.
struct PaneSection<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

/// A card of labelled facts, each a `LabeledContent`. The values are the daemon's
/// words or a model's, drawn as text.
private struct FactsCard: View {
    let rows: [EvidenceRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                LabeledContent {
                    Text(verbatim: row.value)
                        .font(row.isCode ? Theme.code : Theme.body)
                        .textSelection(.enabled)
                        // A command can be long; it is capped so one fact cannot grow a tall row.
                        .lineLimit(40)
                } label: {
                    Text(row.label)
                }
            }
        }
        .labeledContentStyle(FactStyle())
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// Puts a fact's label in a column of fixed width and its value beside it, left
/// aligned, so a value that wraps stays under its own first line. The default style
/// pushes the value to the trailing edge.
private struct FactStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
                .font(Theme.caption).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A session's own words on a tinted surface, under a label that says whose they are.
struct QuoteBox: View {
    let source: String
    let words: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: source).font(Theme.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: words).font(Theme.body).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Theme.radiusInner)
    }
}

private struct PeerQuote: View {
    let peer: BriefPeer

    var body: some View {
        QuoteBox(
            source: "Peer message \u{00B7} \(peer.session) \u{00B7} \(peer.strand) messaged this session at \(ClockTime.local(peer.at)) \u{00B7} untrusted text",
            words: peer.text.text
        )
    }
}

/// One question of an ask, with its options and the daemon's marks, as text.
struct QuestionBlock: View {
    let question: AttentionQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: question.prompt).font(Theme.label).textSelection(.enabled)
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).").font(Theme.caption).foregroundStyle(.secondary)
                    Text(verbatim: option.label).font(Theme.body)
                    if option.isRecommended { Text("recommended").font(Theme.caption).foregroundStyle(Theme.attention) }
                    if let note = option.note { Text(verbatim: note).font(Theme.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// The agent's message. A working session's is the brief's latest, which may belong
/// to the turn still running; any other is the last finished message, labelled as
/// not current work.
struct LastMessage: View {
    let activity: SessionActivity?
    let brief: SessionBrief?
    let working: Bool

    var body: some View {
        if working, let assistant = brief?.assistant, !assistant.text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            QuoteBox(source: "The agent's latest message, untrusted text \u{00B7} \(ClockTime.local(assistant.at))", words: assistant.text.text)
        } else if let activity, let said = InboxRule.said(activity) {
            QuoteBox(
                source: "The agent's last message, untrusted text" + (activity.lastMessageAt.map { " \u{00B7} " + ClockTime.local($0) } ?? ""),
                words: said
            )
        }
    }
}

private struct StepsCard: View {
    let steps: [BriefStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ClockTime.local(step.at)).font(Theme.meta).foregroundStyle(.secondary)
                    Text(verbatim: step.tool.text).font(Theme.code)
                    Text(verbatim: step.words.text).font(Theme.caption).lineLimit(2)
                    Spacer(minLength: 4)
                    Text(step.outcome.rawValue).font(Theme.caption)
                        .foregroundStyle(step.outcome == .failed ? Theme.failure : .secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// The coordinator's card: the goal's objective and status, the delegates' counts,
/// the tokens spent of the budget, and a line for each delegate. A delegate is a
/// strand other than `main`, which is the session's own.
private struct CoordinatorCard: View {
    let brief: SessionBrief?

    var body: some View {
        if let brief {
            let delegates = brief.strands.filter { $0.name != "main" }
            if brief.goal != nil || !delegates.isEmpty {
                PaneSection("The coordinator") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 24) {
                            if let goal = brief.goal {
                                column("Goal", goal.objective, ThreadRule.goalStatus(goal.status))
                                if goal.tokenBudget > 0 {
                                    column("Tokens", "\(ThreadRule.tokens(goal.tokensUsed)) of \(ThreadRule.tokens(goal.tokenBudget))", nil)
                                }
                            }
                            if !delegates.isEmpty { column("Delegates", ThreadRule.delegates(delegates), nil) }
                        }
                        ForEach(delegates) { strand in
                            HStack(spacing: 8) {
                                Text(verbatim: strand.name).font(Theme.code)
                                    .foregroundStyle(strand.state == .stopped ? Theme.failure : .primary)
                                Text(verbatim: ThreadRule.render(ThreadRule.strandPhrase(state: strand.state, since: strand.since)))
                                    .font(Theme.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surface()
                }
            }
        }
    }

    private func column(_ label: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(Theme.body.weight(.semibold)).textSelection(.enabled)
            if let note { Text(note).font(Theme.caption).foregroundStyle(.secondary) }
        }
    }
}

extension InboxRow {
    /// Whether the row is a find, which waits on no one and so has no wait to word.
    fileprivate var isFind: Bool {
        if case .find = kind { return true }
        return false
    }
}
