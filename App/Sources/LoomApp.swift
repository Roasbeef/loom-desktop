import LoomKit
import MissionKit
import SwiftUI
import UserNotifications

@main
struct LoomApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        // The center delivers a click that launched the app as soon as a delegate is
        // set, which can be before any window and its model exist, so the delegate is
        // set here and a click waits in `NoticeClicks` for the model.
        if !Announcer.isUnderTest { UNUserNotificationCenter.current().delegate = NoticeClicks.shared }
    }

    var body: some Scene {
        WindowGroup("Loom", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
                .task {
                    model.appearance.apply()
                    model.start()
                    Announcer.shared.watch(model)
                    NoticeClicks.shared.showWindow = { raiseMainWindow { openWindow(id: "main") } }
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

/// Brings the main window forward: a minimized one is restored, one on screen is
/// raised, and with neither `open` makes one, so a second main window never opens
/// beside a window that is already there. A closed window is not visible and not
/// minimized, so it is opened again.
@MainActor
func raiseMainWindow(open: () -> Void) {
    let mains = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
    guard let window = mains.first(where: { $0.isVisible || $0.isMiniaturized }) else { return open() }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
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
        raiseMainWindow { openWindow(id: "main") }
        NSApplication.shared.activateUnlessDriven()
    }

    private func show(_ destination: Destination) {
        model.destination = destination
        raiseMainWindow { openWindow(id: "main") }
        NSApplication.shared.activateUnlessDriven()
    }
}

/// Reports what needs the owner outside the window: the Dock badge always, and a
/// notification while the app is in the background. What to post and what to remove
/// is `Notices.plan`, a diff of two boards; this class only keeps the previous board
/// and hands the plan to the notification center.
@MainActor
final class Announcer {
    static let shared = Announcer()
    private var isWatching = false

    #if DEBUG
    /// The identifiers of every notice the plan listed. A real run posts those while
    /// the app is in the background; a test posts none and only records them.
    private(set) var posted: [String] = []

    /// The identifiers removed after their item resolved, in the same spirit.
    private(set) var removed: [String] = []
    #endif

    func watch(_ model: AppModel) {
        guard !isWatching else { return }
        isWatching = true

        // Asking is not gated on the toggle, which gates posting, so turning it on
        // later finds the permission already settled.
        if !Self.isUnderTest {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
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

    static var isUnderTest: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["LOOM_DEBUG_DRIVER"] != nil
        #else
        false
        #endif
    }

    private func update(_ model: AppModel) {
        let board = model.board
        NSApp.dockTile.badgeLabel = board.dockLabel

        // The core decided what to post, remove and sweep when it settled the board.
        let pending = model.takePendingNotices()
        for keeping in pending.sweeps { sweep(keeping: keeping) }
        for plan in pending.plans where !plan.isEmpty { deliver(plan) }
    }

    private func deliver(_ plan: NoticePlan) {
        // A resolved item's notice goes whether or not notifications are on or the
        // app is in front, so nothing stale is left in the center.
        #if DEBUG
        removed += plan.remove
        posted += plan.post.map(\.identifier)
        #endif
        guard !Self.isUnderTest else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: plan.remove)
        center.removePendingNotificationRequests(withIdentifiers: plan.remove)

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
            center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
        }
    }

    /// Removes delivered notices whose identifier is not in `keeping`.
    private func sweep(keeping: Set<String>) {
        guard !Self.isUnderTest else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let stale = delivered.map(\.request.identifier).filter { !keeping.contains($0) }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
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

    /// Set once, on the main actor. A click that arrived first waits in `pending`
    /// and is opened here.
    @MainActor var model: AppModel? {
        didSet {
            guard model != nil, let waiting = pending else { return }
            pending = nil
            open(row: waiting.row, session: waiting.session)
        }
    }

    /// A click that arrived before the model existed.
    @MainActor private var pending: (row: String?, session: String?)?

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
        guard let model else {
            pending = (row, session)
            return
        }
        let rows = model.board.rows
        let subject = rows.first { $0.id == row }?.subject ?? session.map { InboxSubject.session($0) }
        showWindow()
        NSApplication.shared.activateUnlessDriven()
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

extension NSApplication {
    /// Brings the app forward, except under the test driver, which must never take the owner's focus.
    /// The driver's own `activate` command is the one way a foreground scenario asks for it.
    func activateUnlessDriven() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LOOM_DEBUG_DRIVER"] != nil,
           ProcessInfo.processInfo.environment["LOOM_FORCE_ACTIVE"] == nil { return }
        #endif
        activate()
    }
}
