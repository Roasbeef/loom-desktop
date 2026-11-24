import LoomKit
import MissionKit
import SwiftUI

// Answering an ask from the app: the questions as controls, one for each kind, and a
// Send that delivers the answer through `attention.answer` and settles the ask. The
// inbox's reading pane and the session page's rail both draw `AskAnswering`, so an
// ask is answered one way wherever it is read.
//
// What may be answered, what an entry means and when the form may send again are
// `MissionKit.AnswerRule` and `AnswerFlow`, which are pure and tested; this file
// draws them and makes the one call. Every word a model wrote (a prompt, an option's
// label and note) is drawn with `Text(verbatim:)`.
//
// ## Flow
//
// `AskAnswering` asks `AnswerRule.offer` whether the record shows a form. If it does
// not (answered, routed to a strand, an observer, an older daemon) it draws the
// questions read-only under the offer's words. If it does, `AskAnswerForm` draws a
// control for each question and Send checks the entries, calls the daemon at the
// revision it read, and then reads the record again. Any send, delivered or refused or
// lost, holds the form until that read has landed.

/// The questions of an open ask, as controls or as words.
struct AskAnswering: View {
    @Environment(AppModel.self) private var model
    let sessionID: String
    let name: String
    let record: AttentionRecord
    let ask: AttentionRecord.Ask
    let isObserver: Bool
    /// What the ask says when the daemon cannot take an answer. The session page's
    /// card passes its own, since the default sends a reader to the page they are on.
    var unsupportedWords: String = AnswerRule.unsupportedWords
    /// Reads the record again and answers whether the read landed.
    let reread: () async -> Bool

    var body: some View {
        let offer = AnswerRule.offer(
            ask: ask, status: record.status, isObserver: isObserver,
            unsupported: model.daemon(holding: sessionID)?.cannotTakeAnswers ?? false,
            unsupportedWords: unsupportedWords
        )
        switch offer {
        case .form:
            AskAnswerForm(sessionID: sessionID, name: name, record: record, ask: ask, reread: reread)
        case .words(let words):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ask.questions) { QuestionBlock(question: $0) }
                Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// What a person has entered for an ask, and the state of its Send.
@MainActor @Observable
final class AnswerModel {
    private(set) var entries: [String: AnswerEntry] = [:]
    private(set) var flow = AnswerFlow()

    /// The first question the entries cannot answer, shown beside it after a Send
    /// that was not made.
    private(set) var problem: AnswerRefusal?

    func entry(_ key: String) -> AnswerEntry { entries[key] ?? .unset }

    func set(_ key: String, _ entry: AnswerEntry) {
        entries[key] = entry
        if problem?.key == key { problem = nil }
    }

    /// Checks the entries and sends them at the record's revision. The record is read
    /// again afterwards whenever the answer changed it or may have, and only that read
    /// releases the form for another send.
    func send(record: AttentionRecord, ask: AttentionRecord.Ask, sessionID: String, name: String, model: AppModel, reread: () async -> Bool) async {
        guard flow.maySend else { return }
        let body: AttentionAnswerBody
        switch AnswerRule.check(questions: ask.questions, entries: entries) {
        case .refused(let refusal):
            problem = refusal
            return
        case .ready(let ready):
            problem = nil
            body = ready
        }
        guard flow.begin() else { return }
        guard let daemon = model.daemon(holding: sessionID), let control = daemon.control else {
            flow.ended(words: "The session is not running.")
            return
        }
        do {
            let receipt = try await control.answerAsk(sessionID: sessionID, ask: record.id, revision: record.revision, answer: body)
            flow.ended(words: AnswerRule.deliveredWords(receipt.delivery, name: name))
        } catch let error as LoomError where error.isUnknownCommand {
            // An older daemon: the ask goes back to being read-only, as it was.
            daemon.noteAnswersUnsupported()
            flow.declined(words: AnswerRule.unsupportedWords)
            return
        } catch LoomError.server(let code, let message, _) {
            flow.ended(words: AnswerRule.refusalWords(code: code, message: message))
        } catch LoomError.outcomeUnknown {
            flow.ended(words: AnswerRule.unansweredWords)
        } catch {
            flow.ended(words: ComposerModel.words(error))
        }
        await settle(daemon: daemon, reread: reread)
    }

    /// Reads the feed and the record again. A read that fails leaves the form held,
    /// and Read again tries once more.
    func settle(daemon: DaemonConnection, reread: () async -> Bool) async {
        await daemon.readAttentionNow()
        if await reread() { flow.readLanded() }
    }
}

/// The form: a control for each question, then Send.
struct AskAnswerForm: View {
    @Environment(AppModel.self) private var model
    let sessionID: String
    let name: String
    let record: AttentionRecord
    let ask: AttentionRecord.Ask
    let reread: () async -> Bool
    @State private var answer = AnswerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ask.questions) { question in
                QuestionControl(question: question, answer: answer)
            }
            HStack(spacing: 10) {
                Button("Send answers") {
                    Task {
                        await answer.send(record: record, ask: ask, sessionID: sessionID, name: name, model: model, reread: reread)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!answer.flow.maySend)
                .accessibilityIdentifier("ask-answer-send")
                if answer.flow.isHeld, !answer.flow.isSending, let daemon = model.daemon(holding: sessionID) {
                    Button("Read again") { Task { await answer.settle(daemon: daemon, reread: reread) } }
                        .buttonStyle(.bordered)
                }
                if answer.flow.isSending { Text("Sending\u{2026}").font(Theme.caption).foregroundStyle(.secondary) }
            }
            if let words = answer.flow.holdWords ?? answer.flow.said {
                Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer the ask")
    }
}

/// One question and the control its kind takes. A question can also be answered by
/// Other, which replaces whatever the kind would have given with the person's words.
private struct QuestionControl: View {
    let question: AttentionQuestion
    let answer: AnswerModel

    private var entry: AnswerEntry { answer.entry(question.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: question.prompt).font(Theme.label).textSelection(.enabled)
            switch question.kind {
            case .confirm:
                radio("Yes", selected: entry == .confirm(true)) { answer.set(question.key, .confirm(true)) }
                radio("No", selected: entry == .confirm(false)) { answer.set(question.key, .confirm(false)) }
            case .choice:
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    radio(option, selected: entry == .picked(option.label)) { answer.set(question.key, .picked(option.label)) }
                }
            case .multiple, .checklist:
                if case .multiple = question.kind {
                    let bounds = AnswerRule.bounds(of: question)
                    Text(bounds.min == bounds.max ? "Pick \(bounds.min)." : "Pick \(bounds.min) to \(bounds.max).")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    check(option, ticked: ticked.contains(option.label)) { toggle(option.label) }
                }
            case .fill:
                fill
            case .other:
                // Unreachable: an ask with a question of an unknown kind shows no form.
                EmptyView()
            }
            otherRow
            if let problem = answer.problem, problem.key == question.key {
                Text(verbatim: problem.words).font(Theme.caption).foregroundStyle(Theme.failure)
            }
        }
    }

    private var ticked: Set<String> {
        if case .ticked(let labels) = entry { return labels }
        return []
    }

    private func toggle(_ label: String) {
        var next = ticked
        if next.contains(label) { next.remove(label) } else { next.insert(label) }
        answer.set(question.key, .ticked(next))
    }

    // MARK: Parts

    private func radio(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        radio(AttentionOption(label: label, note: nil, isRecommended: false), selected: selected, action: action)
    }

    private func radio(_ option: AttentionOption, selected: Bool, action: @escaping () -> Void) -> some View {
        row(option, symbol: selected ? "largecircle.fill.circle" : "circle", selected: selected, action: action)
    }

    private func check(_ option: AttentionOption, ticked: Bool, action: @escaping () -> Void) -> some View {
        row(option, symbol: ticked ? "checkmark.square.fill" : "square", selected: ticked, action: action)
    }

    /// An option: its mark, label, the daemon's "recommended" mark and its note.
    private func row(_ option: AttentionOption, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(verbatim: option.label).font(Theme.body)
                if option.isRecommended { Text("recommended").font(Theme.caption).foregroundStyle(Theme.attention) }
                if let note = option.note { Text(verbatim: note).font(Theme.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("answer/\(question.key)/\(option.label)")
    }

    @ViewBuilder
    private var fill: some View {
        let format = question.format ?? "text"
        let text = Binding<String>(
            get: { if case .typed(let typed) = entry { return typed } else { return "" } },
            set: { answer.set(question.key, .typed($0)) }
        )
        VStack(alignment: .leading, spacing: 2) {
            TextField(text: text, prompt: Text(verbatim: Self.prompt(format)), axis: format == "long_text" ? .vertical : .horizontal) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .lineLimit(format == "long_text" ? 3...8 : 1...2)
                .accessibilityLabel(Text(verbatim: question.prompt))
        }
    }

    private static func prompt(_ format: String) -> String {
        switch format {
        case "number": return "A number"
        case "path": return "A path"
        case "url": return "http:// or https://"
        default: return "Your answer"
        }
    }

    /// The "Other" row: choosing it gives the question a field for the person's own
    /// words, and choosing any option takes it back.
    @ViewBuilder
    private var otherRow: some View {
        let isOther: Bool = { if case .other = entry { return true } else { return false } }()
        Button { answer.set(question.key, isOther ? .unset : .other("")) } label: {
            HStack(spacing: 6) {
                Image(systemName: isOther ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(isOther ? Color.accentColor : .secondary)
                Text("Other\u{2026}").font(Theme.body)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOther ? .isSelected : [])
        .accessibilityIdentifier("answer/\(question.key)/other")
        if case .other(let words) = entry {
            TextField(
                text: Binding(get: { words }, set: { answer.set(question.key, .other($0)) }),
                prompt: Text("In your own words"), axis: .vertical
            ) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .accessibilityLabel("Other: your own words")
        }
    }
}
