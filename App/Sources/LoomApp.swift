import LoomKit
import MissionKit
import SwiftUI
import UserNotifications

@main
struct LoomApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Loom", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
                .task {
                    model.appearance.apply()
                    model.start()
                    Announcer.shared.watch(model)
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
        CommandMenu("Session") {
            SessionMenuItems(model: model, approval: approval)
            Divider()
            SessionLifecycleMenuItems(model: model)
        }
    }
}

/// The Session menu's items. Most stay enabled and check at the moment they run,
/// because SwiftUI does not refresh a menu item's enabled state from observable
/// model changes, and a stale disabled item would swallow the shortcut. The three
/// that decide an approval are the exception: their state follows the focused
/// window's armed approval card, which a focused scene value publishes.
private struct SessionMenuItems: View {
    let model: AppModel

    private var session: SessionController? { model.currentSession }

    /// The armed approval card in the focused window, if one is on screen. The
    /// Commands value reads it, since a focused value is delivered to it and not
    /// reliably to a view nested inside a menu.
    let approval: ArmedApproval?

    var body: some View {
        // These decide the armed approval card in the focused window, and nothing
        // else: a decision is made beside its evidence, so with no such card they are
        // disabled. The titles name the tool the card asks for.
        Button { approval?.controller.approve(approval!.record) } label: {
            Text(verbatim: approval.map { "Allow \($0.toolName)" } ?? "Allow Request")
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .disabled(approval?.canAllow != true)
        Button { approval?.controller.approve(approval!.record, remember: true) } label: {
            Text(verbatim: approval.map { "Allow \($0.toolName) for This Session" } ?? "Allow Request for This Session")
        }
        .keyboardShortcut("a", modifiers: [.command, .shift, .option])
        .disabled(approval?.canRemember != true)
        Button { approval?.controller.deny(approval!.record) } label: {
            Text(verbatim: approval.map { "Deny \($0.toolName)" } ?? "Deny Request")
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(approval == nil)
        Divider()
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

/// Reports new attention items outside the window: the Dock badge always, and a
/// notification while the app is in the background.
@MainActor
final class Announcer {
    static let shared = Announcer()
    private var known: Set<String> = []
    private var isWatching = false

    func watch(_ model: AppModel) {
        guard !isWatching else { return }
        isWatching = true
        let notifies = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true
        if notifies, !isUnderTest {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        }
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
        let rows = board.needsYou
        let current = Set(rows.map(\.id))
        let fresh = rows.filter { !known.contains($0.id) }

        // The first read is a backlog, not news.
        let isFirstRead = known.isEmpty && !hasRead
        hasRead = true
        known = current
        guard !isFirstRead, !NSApp.isActive, !isUnderTest,
              UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true else { return }
        for row in fresh {
            let content = UNMutableNotificationContent()
            content.title = row.name
            content.subtitle = row.kind.chip
            content.body = model.summary(of: row)
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: row.id, content: content, trigger: nil))
        }
    }

    private var hasRead = false
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
