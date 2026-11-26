import LoomKit
import MissionKit
import SwiftUI

// The views of the inbox's commands: the Inbox menu, the context menu on a row,
// and a thread's own window. What each command is, and when it can run, is
// `InboxCommands` in MissionKit, which is pure and tested. This file maps an action
// to a button and a button to the model, so the menu and both context menus draw
// from one list and cannot disagree.
//
// ## Flow
//
// A window that shows a thread publishes an `InboxCommandContext` as a focused
// scene value (`InboxView` for the main window's open thread, `ThreadWindow` for a
// thread of its own). `InboxMenu` reads it with the armed approval card's value
// and draws every action, enabled as `InboxCommands.state` says. `.inboxContextMenu`
// builds the same context for one row and draws only what can run for it, minus any
// decision. Both end in `InboxCommandRunner.perform`.

// MARK: The focused window's context

extension FocusedValues {
    /// What the focused window shows of the inbox: the open thread and where it sits
    /// in the list. Nil in a window that shows no thread, which leaves the menu's
    /// thread commands disabled.
    @Entry var inboxContext: InboxCommandContext?
}

extension AppModel {
    /// The context the commands read for `row`: whether this connection only watches
    /// the session, and whether the feed still lists the strand as stuck.
    func commandContext(
        for row: InboxRow?, neighbors: InboxNeighbors = .none, isInOwnWindow: Bool = false
    ) -> InboxCommandContext {
        var stuckListed = false
        if case .stuck(let session, let strand)? = row?.subject {
            stuckListed = attentionRows[session]?.stuck.items.contains { $0.strand == strand } == true
        }
        return InboxCommandContext(
            row: row,
            isObserver: row.flatMap { controller(for: $0.sessionID)?.isObserver } ?? false,
            stuckListed: stuckListed,
            isRetrying: row.map { retrying.contains($0.id) } ?? false,
            neighbors: neighbors,
            isInOwnWindow: isInOwnWindow
        )
    }

    /// The row a session's agent strip stands for: its own thread when it has one,
    /// else the first of its rows.
    func threadRow(forSession id: String) -> InboxRow? {
        let rows = InboxRule.selectable(board.sections).filter { $0.sessionID == id }
        return rows.first { $0.subject == .session(id) } ?? rows.first
    }

    /// What `Mission.attention` holds for a thread's session, which its pane reads
    /// for a live approval card or a failed run.
    func paneItems(for subject: InboxSubject) -> [AttentionItem] {
        attention.filter { item in
            if case .session(let id, _) = item.source { return id == subject.sessionID && item.kind != .machine }
            return false
        }
    }
}

// MARK: Running a command

/// Carries out an `InboxAction`. A failure is said in the refusal alert the main
/// window already carries, so a command from a menu that has no pane to say it is
/// never silent.
@MainActor
struct InboxCommandRunner {
    let model: AppModel
    let openWindow: OpenWindowAction

    func perform(
        _ action: InboxAction, in context: InboxCommandContext, approval: ArmedApproval? = nil, outcome: FindOutcome = .dismissed
    ) {
        guard InboxCommands.state(action, in: context) == .enabled else { return }
        let row = context.row
        switch action {
        case .next: model.stepInbox(.next)
        case .previous: model.stepInbox(.previous)
        case .openSession:
            guard let row else { return }
            model.destination = .session(row.sessionID)

            // From a thread's own window the session is in the main window, which
            // comes to the front so the result and any refusal are seen.
            if context.isInOwnWindow {
                openWindow(id: "main")
                NSApplication.shared.activateUnlessDriven()
            }
        case .openInWindow:
            if let row { openWindow(id: "thread", value: row.subject) }
        case .retry:
            if let row {
                Task {
                    if case .refused(let words) = await model.retry(row) { model.actions.error = words }
                }
            }
        case .closeFind:
            if let row { Task { await model.closeFind(row, as: outcome) } }
        case .message:
            guard let row else { return }

            // A row's own window already shows its pane, and anywhere else the
            // thread is opened first, which is the owner's own choice.
            if !context.isInOwnWindow { model.openInbox(row.subject) }
            model.messageRequest = row.id
        case .allow:
            if let approval { approval.controller.approve(approval.record) }
        case .allowForSession:
            if let approval { approval.controller.approve(approval.record, remember: true) }
        case .deny:
            if let approval { approval.controller.deny(approval.record) }
        }
    }
}

extension AppModel {
    /// What a retry came to, in the words the pane shows.
    enum RetryReport: Equatable {
        case said(String)
        case refused(String)

        var words: String {
            switch self {
            case .said(let words), .refused(let words): return words
            }
        }
    }

    /// Asks the strand to retry, as the pane's Retry and the menu's both do, and reads
    /// the feed again so the row does not stay listed as stuck beside a retry already
    /// sent. The row is held in `retrying` until then, so a second press queues
    /// nothing.
    func retry(_ row: InboxRow) async -> RetryReport {
        guard case .stuck(let session, let strand) = row.subject, retrying.insert(row.id).inserted else {
            return .refused("A retry is already out.")
        }
        defer { retrying.remove(row.id) }
        do {
            let status = try await sendMessage(sessionID: session, strand: strand, text: ThreadRule.retryPrompt, choice: .send)
            await daemon(holding: session)?.readAttentionNow()
            return .said(ThreadSend.deliveredWords(status: status, choice: .send, name: row.name))
        } catch LoomError.outcomeUnknown {
            return .said(ThreadSend.unansweredWords)
        } catch {
            return .refused(ThreadSend.refusedWords(ComposerModel.words(error)))
        }
    }

    /// Closes a find. The revision is read first, since a row holds none and a close
    /// names the one it was staged against, and the daemon says whether this
    /// principal may close it.
    func closeFind(_ row: InboxRow, as outcome: FindOutcome) async {
        guard case .find(let session, let id) = row.subject, let daemon = daemon(holding: session), let control = daemon.control else {
            actions.error = "The session is not running."
            return
        }
        do {
            let record = try await control.attentionRecord(sessionID: session, id: id)
            guard case .find(let find) = record.detail, find.mayClose else {
                actions.error = "Only the owner or an operator can close a find."
                return
            }
            try await control.closeFind(sessionID: session, find: record.id, revision: record.revision, outcome: outcome)
            await daemon.readAttentionNow()
        } catch {
            actions.error = ComposerModel.words(error)
        }
    }
}

// MARK: The Inbox menu

/// The Inbox menu: every action of the list, enabled for the focused window's thread.
/// Allow and Deny are here and not in the Session menu so that there is one list; they
/// are enabled only while an armed approval card is in the focused window, which
/// can be a session's page as well as the inbox.
struct InboxMenu: View {
    let model: AppModel
    let context: InboxCommandContext?
    let approval: ArmedApproval?
    @Environment(\.openWindow) private var openWindow

    private var resolved: InboxCommandContext {
        var found = context ?? InboxCommandContext(row: nil)
        found.approval = approval.map { InboxApproval(tool: $0.toolName, canAllow: $0.canAllow, canRemember: $0.canRemember) }
        return found
    }

    var body: some View {
        let context = resolved
        let runner = InboxCommandRunner(model: model, openWindow: openWindow)
        ForEach(InboxCommands.menu, id: \.self) { action in
            InboxActionButtons.button(action, context: context, approval: approval, runner: runner)
            if action == .previous || action == .message { Divider() }
        }
    }
}

enum InboxActionButtons {
    /// The ways to close a find, as the pane's three buttons name them.
    static let outcomes: [(outcome: FindOutcome, title: String)] = [
        (.fixed, "Close as Fixed"), (.filed, "Close as Filed"), (.dismissed, "Dismiss Find"),
    ]

    /// One action as a menu button. The shortcut is only drawn for the menu bar,
    /// where the chord names it; a context menu passes none.
    @ViewBuilder
    static func button(
        _ action: InboxAction, context: InboxCommandContext, approval: ArmedApproval?, runner: InboxCommandRunner,
        showsShortcut: Bool = true
    ) -> some View {
        let enabled = InboxCommands.state(action, in: context) == .enabled
        if action == .closeFind {
            Menu("Close Find") {
                ForEach(outcomes, id: \.outcome) { entry in
                    Button(entry.title) { runner.perform(.closeFind, in: context, outcome: entry.outcome) }
                }
            }
            .disabled(!enabled)
        } else {
            plain(action, context: context, approval: approval, runner: runner, showsShortcut: showsShortcut, enabled: enabled)
        }
    }

    @ViewBuilder
    private static func plain(
        _ action: InboxAction, context: InboxCommandContext, approval: ArmedApproval?, runner: InboxCommandRunner,
        showsShortcut: Bool, enabled: Bool
    ) -> some View {
        let title = Text(verbatim: action.title(tool: context.approval?.tool))
        if showsShortcut, let shortcut = action.shortcut {
            Button { runner.perform(action, in: context, approval: approval) } label: { title }
                .keyboardShortcut(KeyEquivalent(shortcut.key), modifiers: modifiers(shortcut))
                .disabled(!enabled)
        } else {
            Button { runner.perform(action, in: context, approval: approval) } label: { title }
                .disabled(!enabled)
        }
    }

    private static func modifiers(_ shortcut: InboxShortcut) -> EventModifiers {
        var found: EventModifiers = .command
        if shortcut.modifiers.contains(.shift) { found.insert(.shift) }
        if shortcut.modifiers.contains(.option) { found.insert(.option) }
        return found
    }
}

// MARK: The context menu

extension View {
    /// The row's context menu: the Inbox menu's actions that apply to this row and
    /// can run, with nothing that decides an approval and nothing that navigates.
    func inboxContextMenu(for row: InboxRow?) -> some View {
        modifier(InboxContextMenu(row: row))
    }
}

private struct InboxContextMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let row: InboxRow?

    func body(content: Content) -> some View {
        let context = model.commandContext(for: row)
        let runner = InboxCommandRunner(model: model, openWindow: openWindow)
        content.contextMenu {
            ForEach(InboxCommands.contextActions(for: context), id: \.self) { action in
                InboxActionButtons.button(action, context: context, approval: nil, runner: runner, showsShortcut: false)
            }
        }
    }
}

// MARK: A thread in its own window

/// One thread in a window of its own, for keeping it beside the session it is about.
/// It draws the same pane as the inbox, so a decision is still made beside its
/// evidence. A thread that resolves stays on screen, marked resolved, as it does in
/// the inbox, and a thread that was never listed says so.
struct ThreadWindow: View {
    @Environment(AppModel.self) private var model
    let subject: InboxSubject
    @State private var draft = ""
    @State private var held: InboxRow?

    private var row: InboxRow? { InboxRule.selectable(model.board.sections).first { $0.subject == subject } }

    var body: some View {
        let listed = row
        Group {
            if let listed {
                ThreadPane(row: listed, items: model.paneItems(for: subject), draft: $draft).id(listed.id)
            } else if let held {
                ResolvedPane(row: held, note: "Resolved. This thread no longer needs you. Close this window when you are done with it.")
            } else {
                ContentUnavailableView(
                    "This thread is not listed", systemImage: "checkmark.circle",
                    description: Text("It is not waiting on you, or it was resolved before this window opened.")
                )
            }
        }
        .onChange(of: listed, initial: true) { _, now in if let now { held = now } }
        .focusedSceneValue(\.inboxContext, model.commandContext(for: listed, isInOwnWindow: true))
        .navigationTitle(listed?.name ?? held?.name ?? "Thread")
    }
}
