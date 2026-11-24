import LoomKit
import MissionKit
import SwiftUI
import UserNotifications

@main
struct LoomApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Loom", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
                .task {
                    model.appearance.apply()
                    model.start()
                    Announcer.shared.watch(model)
                    NoticeClicks.shared.showWindow = {
                        // A second main window would open beside one already there.
                        let hasMain = NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true }
                        if !hasMain { openWindow(id: "main") }
                    }
                    #if DEBUG
                    DebugDriver.start(model: model)
                    #endif
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands { LoomCommands(model: model) }

        // A session in its own window, for keeping one on a second display.
        WindowGroup("Session", id: "session", for: String.self) { $sessionID in
            if let sessionID {
                NavigationStack {
                    SessionScreen(sessionID: sessionID)
                }
                .environment(model)
                .frame(minWidth: 560, minHeight: 480)
            }
        }
        .defaultSize(width: 820, height: 760)
        .windowToolbarStyle(.unified)

        // A thread of the inbox in its own window, beside the session it is about.
        WindowGroup("Thread", id: "thread", for: InboxSubject.self) { $subject in
            if let subject {
                ThreadWindow(subject: subject)
                    .environment(model)
                    .frame(minWidth: 520, minHeight: 420)
            }
        }
        .defaultSize(width: 640, height: 720)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView().environment(model)
        }

        // The count stays visible when the window is not, since being told an
        // agent is waiting is most of what a person running a fleet needs.
        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            let waiting = model.board.needing
            if waiting == 0 {
                Image(systemName: "circle.dotted")
            } else {
                Label("\(waiting)", systemImage: "circle.inset.filled").labelStyle(.titleAndIcon)
            }
        }
    }
}

/// The menu bar: every command a person can reach, with its shortcut on show. It is
/// how a Mac app teaches its keyboard.
private struct LoomCommands: Commands {
    let model: AppModel
    @FocusedValue(\.armedApproval) private var approval
    @FocusedValue(\.inboxContext) private var inboxContext

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Agent…") { model.isDispatching = true }
                .keyboardShortcut("n")
            Button("Connect a Daemon…") {
                model.daemonSuggestion = nil
                model.isAddingDaemon = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            ForEach(AppearanceChoice.allCases) { choice in
                Button(choice.menuTitle) { model.appearance = choice }
            }
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                model.sidebarVisibility = model.sidebarVisibility == .detailOnly ? .all : .detailOnly
            }
            .keyboardShortcut("b")
            Button("Toggle Inspector") {
                model.showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("Go") {
            Button("Command Palette…") { model.isPaletteOpen.toggle() }
                .keyboardShortcut("k")
            Divider()
            Button("Inbox") { model.destination = .inbox }
                .keyboardShortcut("1")
            Button("Mission Control") { model.destination = .mission }
                .keyboardShortcut("2")
            Button("Machines") { model.destination = .machines }
                .keyboardShortcut("3")
            Divider()
            Button("Next Session Needing You") { model.goToNextNeedingYou() }
                .keyboardShortcut("j")
            Button("People…") { model.actions.showsPeople = true }
            Button("Toggle Saved Sessions") {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "sidebarSavedOpen"), forKey: "sidebarSavedOpen")
            }
        }
        CommandMenu("Inbox") {
            InboxMenu(model: model, context: inboxContext, approval: approval)
        }
        CommandMenu("Session") {
            SessionMenuItems(model: model)
            Divider()
            SessionLifecycleMenuItems(model: model)
        }
    }
}

/// The Session menu's items. They stay enabled and check at the moment they run,
/// because SwiftUI does not refresh a menu item's enabled state from observable
/// model changes, and a stale disabled item would swallow the shortcut. The three
/// that decide an approval are in the Inbox menu instead (`InboxMenu`), whose state
/// follows the focused window's armed approval card and the thread it shows.
private struct SessionMenuItems: View {
    let model: AppModel

    private var session: SessionController? { model.currentSession }

    var body: some View {
        Button("Stop Run") {
            if session?.isBusy == true { session?.abort() }
        }
            .keyboardShortcut(".")
        Button("Find in Transcript") { session?.isSearching = true }
            .keyboardShortcut("f")

        // The side question had a button in the composer's bar; it is here, and
        // `/btw` in the composer asks one directly.
        Button("Toggle Side Question") { session?.showsSideQuestion.toggle() }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        Button("Refresh Changes") { session?.requestDiff() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rows = model.board.needsYou
        if model.board.needing == 0 {
            Text("Nothing needs you")
        } else {
            ForEach(rows.prefix(8)) { row in
                Button { show(row.subject) } label: { Text(verbatim: "\(row.name): \(model.summary(of: row))") }
            }
            if rows.isEmpty {
                Button("\(model.board.needing) in saved sessions") { show(.inbox) }
            }
        }
        Divider()
        Button("Mission Control") { show(.mission) }
        Button("New Agent…") {
            show(.mission)
            model.isDispatching = true
        }
        Divider()
        Button("Quit Loom") { NSApplication.shared.terminate(nil) }
    }

    private func show(_ subject: InboxSubject) {
        model.openInbox(subject)
        openWindow(id: "main")
        NSApplication.shared.activate()
    }

    private func show(_ destination: Destination) {
        model.destination = destination
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}

/// Reports what needs the owner outside the window: the Dock badge always, and a
/// notification while the app is in the background. What to post and what to remove
/// is `Notices.plan`, a diff of two boards; this class only keeps the previous board
/// and hands the plan to the notification center.
@MainActor
final class Announcer {
    static let shared = Announcer()
    private var previous: InboxBoard?
    private var isWatching = false

    /// The identifiers of every notice the plan listed. A real run posts those while
    /// the app is in the background; a test posts none and only records them. A scenario reads them to see the plan.
    private(set) var posted: [String] = []

    /// The identifiers removed after their item resolved, in the same spirit.
    private(set) var removed: [String] = []

    func watch(_ model: AppModel) {
        guard !isWatching else { return }
        isWatching = true
        let notifies = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true
        if !isUnderTest {
            let center = UNUserNotificationCenter.current()
            center.delegate = NoticeClicks.shared
            if notifies { center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in } }
        }
        NoticeClicks.shared.model = model
        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                update(model)
                model.recordFirstReplies()
            }
        }
    }

    private var isUnderTest: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["LOOM_DEBUG_DRIVER"] != nil
        #else
        false
        #endif
    }

    private func update(_ model: AppModel) {
        let board = model.board
        NSApp.dockTile.badgeLabel = board.dockLabel

        // Until a daemon has reported a session the board is empty because nothing was
        // read, not because nothing waits, so that board is not the backlog's baseline.
        guard board.reported > 0 || previous != nil else { return }
        let plan = Notices.plan(previous: previous, next: board) { row in
            guard row.kind == .approval else { return nil }
            return model.controller(for: row.sessionID)?.escalations.first?.authorityLines.first
        }
        previous = board
        guard !plan.isEmpty else { return }

        // A resolved item's notice goes whether or not notifications are on or the
        // app is in front, so nothing stale is left in the center.
        removed += plan.remove
        if !isUnderTest {
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: plan.remove)
            center.removePendingNotificationRequests(withIdentifiers: plan.remove)
        }

        posted += plan.post.map(\.identifier)
        guard !isUnderTest else { return }

        // An owner looking at the app is told by the app itself.
        guard !NSApp.isActive, UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true else { return }
        for notice in plan.post {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.subtitle = notice.subtitle
            content.body = notice.body
            content.sound = .default
            content.threadIdentifier = notice.thread
            content.userInfo = [NoticeClicks.rowKey: notice.subject.key, NoticeClicks.sessionKey: notice.thread]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
        }
    }
}

/// Receives a click on a delivered notification and opens its thread in the inbox.
/// A click never decides anything: an approval is decided only beside its evidence,
/// so the notification carries no actions.
final class NoticeClicks: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NoticeClicks()
    static let rowKey = "row"
    static let sessionKey = "session"

    /// Set once, on the main actor, before the center can call back.
    @MainActor var model: AppModel?

    /// Raises the main window, which a click should do even when it was closed.
    @MainActor var showWindow: () -> Void = {}

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let row = info[Self.rowKey] as? String
        let session = info[Self.sessionKey] as? String
        await MainActor.run { open(row: row, session: session) }
    }

    /// Opens the row's thread, or the session's own thread when the row is gone, as
    /// an item that resolved while the notification sat in the center is.
    @MainActor
    func open(row: String?, session: String?) {
        guard let model else { return }
        let rows = model.board.rows
        let subject = rows.first { $0.id == row }?.subject ?? session.map { InboxSubject.session($0) }
        showWindow()
        NSApplication.shared.activate()
        if let subject { model.openInbox(subject) } else { model.destination = .inbox }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("notifications") private var notifications = true

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Notifications") {
                Toggle("Notify me when an agent needs me", isOn: $notifications)
            }
            Section("Daemons") {
                ForEach(model.daemons) { daemon in
                    LabeledContent(daemon.label) {
                        HStack(spacing: 8) {
                            Text(stateLabel(daemon)).foregroundStyle(.secondary)
                            if daemon.isRemote {
                                Button("Remove") { model.removeDaemon(daemon) }
                            }
                        }
                    }
                }
                Button("Connect a Daemon…") {
                    model.daemonSuggestion = nil
                    model.isAddingDaemon = true
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
        .sheet(isPresented: $model.isAddingDaemon) {
            AddDaemonSheet()
        }
    }

    private func stateLabel(_ daemon: DaemonConnection) -> String {
        switch daemon.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .unavailable: return "Unavailable"
        }
    }
}
