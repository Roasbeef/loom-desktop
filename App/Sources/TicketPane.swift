import LoomKit
import MissionKit
import SwiftUI

// A project ticket's pane: why it exists, the thread on its opening message, the
// worker's question and an answer box, the check's output with its cause, the
// assignments of its workers, and a control for every action the daemon lists.
// The inbox draws it for a ticket that waits on a person, and the Projects
// destination draws it for any ticket.
//
// Every string in it is external text. A title, an input and a check's output can
// come from a message anyone could write, and the decoders have already made them
// safe to draw, so each is drawn with `Text(verbatim:)` under a label that says
// whose words they are.

/// What a ticket's pane holds between draws: the last read of the ticket, an act
/// that is out, and the act the pane is asking about. What an act came to is kept on
/// the model (`AppModel.ticketResults`), so it outlives this pane.
@MainActor
@Observable
final class TicketReader {
    private(set) var detail: ProjectDetail?
    private(set) var unreadable = false
    private(set) var sending = false
    private(set) var confirming: TicketControl?
    private(set) var review: ReviewRead?
    private(set) var reviewWords: String?

    private var isReadingChanges = false
    private var wantsAnotherRead = false

    /// Reads the worker session's working tree. A refusal is the daemon's own words and
    /// leaves the last read in place.
    ///
    /// The read runs apart from the view's task, because the control connection closes
    /// a socket whose exchange was cancelled and would then fail every other read, and
    /// the view's task is cancelled whenever the ledger moves. A request that arrives
    /// while one is out asks for one more read when it returns.
    func readChanges(control: ControlClient?, session: String) async {
        guard let control else { return }
        if isReadingChanges {
            wantsAnotherRead = true
            return
        }
        isReadingChanges = true
        repeat {
            wantsAnotherRead = false
            let outcome = await Task { () -> Result<ReviewRead, Error> in
                do { return .success(try await control.review(sessionID: session)) } catch { return .failure(error) }
            }.value
            switch outcome {
            case .success(let read):
                review = read
                reviewWords = nil
            case .failure(let error):
                reviewWords = ComposerModel.words(error)
            }
        } while wantsAnotherRead
        isReadingChanges = false
    }

    func read(control: ControlClient?, project: String, ticket: String) async {
        guard let control else { return }
        do {
            detail = try await control.projectTicket(project, ticket: ticket)
            unreadable = false
        } catch {
            unreadable = detail == nil
        }
    }

    /// A press on a control. A control that needs confirmation only asks, and the
    /// confirmation is its own button, so one gesture cannot do both. A press while an
    /// act is out asks nothing.
    func press(
        _ control: TicketControl, ticket: ProjectTicket, daemon: DaemonConnection?, project: String, answer: String,
        answered: @escaping @MainActor () -> Void, record: @escaping @MainActor (TicketResult?) -> Void
    ) {
        guard !sending else { return }
        if control.needsConfirmation, confirming != control {
            confirming = control
            record(nil)
            return
        }
        confirming = nil
        perform(control, ticket: ticket, daemon: daemon, project: project, answer: answer, answered: answered, record: record)
    }

    /// A control the daemon no longer lists cannot be waiting on a confirmation, so a
    /// read that took the action away takes the question with it.
    func reconcile(_ controls: [TicketControl]) {
        if let asking = confirming, !controls.contains(asking) { confirming = nil }
    }

    func cancel() { confirming = nil }

    private func perform(
        _ control: TicketControl, ticket: ProjectTicket, daemon: DaemonConnection?, project: String, answer: String,
        answered: @escaping @MainActor () -> Void, record: @escaping @MainActor (TicketResult?) -> Void
    ) {
        guard let client = daemon?.control else {
            record(TicketResult(words: "The daemon is not connected.", isRefusal: true))
            return
        }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .answer = control, text.isEmpty { return }
        sending = true
        record(nil)
        Task {
            defer { sending = false }
            do {
                switch control {
                case .answer(let seq): try await client.answerTicket(project, ticket: ticket.id, seq: seq, text: text)
                default: if let act = control.act { try await client.actOnTicket(act, project: project, ticket: ticket.id) }
                }
                if case .answer = control { answered() }
                await read(control: client, project: project, ticket: ticket.id)
                await daemon?.readProjectsNow()

                // The result is kept on the model, because the row this pane was opened
                // from may leave the inbox the moment the daemon moves the ticket, and
                // the pane that replaces it still says what was done.
                record(TicketResult(words: ProjectRule.done(control, stage: detail?.ticket.stage), isRefusal: false))
                return
            } catch LoomError.server(let code, let message, _) {
                record(TicketResult(words: ProjectRule.refusal(code: code, message: message, control: control), isRefusal: true))
            } catch {
                record(TicketResult(
                    words: "No reply arrived, so the outcome is unknown. Read the ticket again before trying again.", isRefusal: true
                ))
            }
            await read(control: client, project: project, ticket: ticket.id)
            await daemon?.readProjectsNow()
        }
    }
}

struct TicketPane: View {
    @Environment(AppModel.self) private var model
    let project: String
    let ticket: String
    @State private var reader = TicketReader()

    private var state: ProjectState? { model.projectStates.first { $0.id == project } }
    private var daemon: DaemonConnection? { model.daemon(holdingProject: project) }
    private var key: ProjectSelection { .ticket(project: project, ticket: ticket) }

    /// The answer being written, kept on the model by ticket so it survives a move
    /// down the list and so a test can write it without a key window.
    private var draft: Binding<String> {
        let key = ProjectSelection.ticket(project: project, ticket: ticket)
        return Binding(get: { model.ticketDrafts[key] ?? "" }, set: { model.ticketDrafts[key] = $0 })
    }

    /// The last read of the ticket when one has answered, which is newer than the
    /// board's row, and otherwise the board's row.
    private var current: ProjectTicket? {
        reader.detail?.ticket ?? state?.page?.tickets.first { $0.id == ticket }
    }

    var body: some View {
        Group {
            if let current {
                content(current)
            } else {
                ContentUnavailableView(
                    reader.unreadable ? "This ticket could not be read" : "This ticket is not listed",
                    systemImage: "ticket",
                    description: Text("It may have ended, or the project's board has not been read yet.")
                )
            }
        }
        // The ticket is read again whenever the project's ledger moves, so a stage
        // the board has since changed is never acted on from an older read.
        .task(id: "\(project)/\(ticket)/\(state?.page?.revision ?? -1)") {
            await reader.read(control: daemon?.control, project: project, ticket: ticket)
        }
        // The tree is read when the ticket is opened and whenever the ledger moves, and a
        // read the daemon refuses as busy is only the daemon's allowance for the credential.
        .task(id: "changes/\(project)/\(ticket)/\(state?.page?.revision ?? -1)/\(current?.session ?? "")") {
            if let current { await readChanges(current) }
        }
        .accessibilityIdentifier("ticket-pane/\(project)/\(ticket)")
    }

    private func content(_ ticket: ProjectTicket) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(ticket)
                if let question = ticket.question { questionSection(ticket, question) }
                if let failure = ticket.failure { sentence("The worker could not start", failure) }
                if let check = ticket.check { checkSection(check) }
                if let review = ticket.review { sentence("Why it waits for you", review) }
                if let url = ticket.pullRequest { sentence("Pull request", url) }
                if let detail = reader.detail { threadSection(detail) }
                changesSection(ticket)
                controls(ticket)
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private func header(_ ticket: ProjectTicket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The daemon's own word, `person/check` included.
                Text(verbatim: ticket.stage.word)
                    .font(Theme.caption)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.tintStrong, in: .rect(cornerRadius: 4))
                Text(verbatim: state?.summary.name ?? "").font(Theme.meta).foregroundStyle(.secondary)
            }
            Text(verbatim: ProjectRule.titleWords(ticket))
                .font(.system(size: 20, weight: .semibold)).textSelection(.enabled).lineLimit(3)
            Text(verbatim: ProjectRule.gloss(ticket.stage)).font(Theme.meta).foregroundStyle(.secondary)
            if let words = ProjectRule.mandateWords(ticket.mandate) {
                Text(verbatim: words).font(Theme.meta).foregroundStyle(.secondary)
            }
            if let age = ProjectRule.age(ticket, now: Int(Date().timeIntervalSince1970 * 1000)) {
                Text(age.words == "now" ? "opened just now" : "opened \(age.words) ago").font(Theme.meta).foregroundStyle(.secondary)
            }
        }
    }

    private func sentence(_ label: String, _ words: String) -> some View {
        PaneSection(label) {
            Text(verbatim: words).font(Theme.body).textSelection(.enabled)
        }
    }

    // MARK: Question

    private func questionSection(_ ticket: ProjectTicket, _ question: ProjectQuestion) -> some View {
        PaneSection("The worker asks") {
            // The question is the worker's text, so it is labelled as untrusted.
            Text("Untrusted text from the worker:").font(Theme.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: question.text).font(Theme.body).textSelection(.enabled)
                if !question.options.isEmpty {
                    Text(verbatim: "Options it offered: " + question.options.joined(separator: " \u{00B7} "))
                        .font(Theme.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.tint, in: .rect(cornerRadius: Theme.radiusInner))
            if ProjectRule.controls(ticket).contains(.answer(seq: question.seq)) {
                TextField("Your answer", text: draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...6)
                    .accessibilityLabel("Answer text")
            }
        }
    }

    // MARK: Check

    private func checkSection(_ check: ProjectCheck) -> some View {
        PaneSection("The check") {
            Text(verbatim: checkLine(check)).font(Theme.body).textSelection(.enabled)
            if let note = check.note { Text(verbatim: note).font(Theme.caption).foregroundStyle(.secondary) }
            if let command = check.command {
                Text(verbatim: "$ " + command).font(Theme.code).textSelection(.enabled)
            }
            if let output = check.output, !output.isEmpty {
                // What a process printed while running the worker's code.
                Text("Output, as the check printed it:").font(Theme.caption).foregroundStyle(.secondary)
                Text(verbatim: output).font(Theme.code).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.tint, in: .rect(cornerRadius: Theme.radiusInner))
                    .accessibilityLabel("Check output")
            }
        }
    }

    private func checkLine(_ check: ProjectCheck) -> String {
        let outcome: String
        switch check.outcome {
        case .passed: outcome = "Passed"
        case .failed: outcome = "Failed"
        case .overridden: outcome = "A person published past it"
        case .unfinished: outcome = "Gave no result"
        case .waiting: outcome = "Not run yet"
        case .unknown(let word): outcome = word
        }
        let cause = check.cause.map { ", cause: \($0)" } ?? ""
        let handling = check.handling.map { ", handled by: \($0)" } ?? ""
        let commit = check.commit.isEmpty ? "" : " at \(check.commit.prefix(10))"
        return outcome + cause + handling + commit
    }

    // MARK: Thread

    private func threadSection(_ detail: ProjectDetail) -> some View {
        PaneSection("Thread") {
            ForEach(Array(detail.inputs.enumerated()), id: \.offset) { _, input in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: inputLabel(input)).font(Theme.caption).foregroundStyle(.secondary)
                    if let text = input.text {
                        Text(verbatim: text).font(Theme.body).textSelection(.enabled)
                    }
                }
            }
            if detail.inputs.isEmpty {
                Text("The ledger holds no text for this thread.").font(Theme.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(detail.assignments.enumerated()), id: \.offset) { _, assignment in
                Text(verbatim: "Worker \(assignment.seq): \(assignment.status)").font(Theme.meta).foregroundStyle(.secondary)
            }
        }
    }

    private func inputLabel(_ input: ProjectInput) -> String {
        let who = [input.actor, input.source.map { "via \($0)" }].compactMap { $0 }.joined(separator: " ")
        return "Untrusted text from " + (who.isEmpty ? "an unknown author" : who) + " \u{00B7} " + input.delivery
    }

    // MARK: Changes

    private var sessionState: SessionState? {
        guard let id = current?.session else { return nil }
        return model.sessions.first { $0.id == id }?.state
    }

    /// The worker's changes in the app's own diff view, red for what it removed and
    /// green for what it added, read-only: a ticket's changes are judged here and
    /// acted on with the controls, so there is no verdict, comment or find to stage.
    private func changesSection(_ ticket: ProjectTicket) -> some View {
        PaneSection("Changes") {
            if let words = ProjectRule.changesPrecondition(session: ticket.session, state: sessionState) {
                Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary)
            } else {
                ReviewThread(
                    review: reader.review, words: reader.reviewWords, commandWords: nil, finds: [], reads: [:], acting: false,
                    outbox: .constant(ReviewOutbox()),
                    readAgain: { Task { await readChanges(ticket) } }
                ) { EmptyView() }
                if let review = reader.review, let words = ProjectRule.cleanTreeWords(review) {
                    Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: ProjectRule.changesCaption).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func readChanges(_ ticket: ProjectTicket) async {
        guard let session = ticket.session, ProjectRule.changesPrecondition(session: session, state: sessionState) == nil else { return }
        await reader.readChanges(control: model.daemon(holding: session)?.control, session: session)
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ ticket: ProjectTicket) -> some View {
        let all = ProjectRule.controls(ticket)
        VStack(alignment: .leading, spacing: 10) {
            if let asking = reader.confirming {
                Text(verbatim: asking.consequence).font(Theme.caption).foregroundStyle(.secondary)
            }
            HStack {
                ForEach(all, id: \.self) { control in
                    Button(control.title) {
                        reader.press(control, ticket: ticket, daemon: daemon, project: project, answer: draft.wrappedValue) {
                            draft.wrappedValue = ""
                        } record: { model.ticketResults[key] = $0 }
                    }
                    .buttonStyle(.bordered)

                    // The control that is being asked about is off until the question is
                    // answered, so a double click on it cannot ask and confirm in one gesture.
                    .disabled(reader.sending || isEmptyAnswer(control) || reader.confirming == control)
                }
                if let asking = reader.confirming {
                    Button("Confirm \(asking.title)") {
                        reader.press(asking, ticket: ticket, daemon: daemon, project: project, answer: draft.wrappedValue) {
                            draft.wrappedValue = ""
                        } record: { model.ticketResults[key] = $0 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(reader.sending)
                    Button("Keep") { reader.cancel() }.buttonStyle(.borderless)
                }
            }
            .onChange(of: all) { _, now in reader.reconcile(now) }
            if let result = model.ticketResults[key] {
                Text(verbatim: result.words).font(Theme.caption)
                    .foregroundStyle(result.isRefusal ? Theme.failure : .secondary)
                    .accessibilityIdentifier("ticket-notice")
            }
        }
    }

    private func isEmptyAnswer(_ control: TicketControl) -> Bool {
        if case .answer = control { return draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return false
    }
}

/// The pane for a row of the inbox: a ticket draws its own, and every session
/// thread draws `InboxPane`.
struct ThreadPane: View {
    let row: InboxRow
    let items: [AttentionItem]
    @Binding var draft: String

    var body: some View {
        if case .ticket(let project, let ticket) = row.subject {
            TicketPane(project: project, ticket: ticket)
        } else {
            InboxPane(row: row, items: items, draft: $draft)
        }
    }
}
