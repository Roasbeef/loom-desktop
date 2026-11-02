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
            let waiting = model.attention.count
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
            Button(model.showsInspector ? "Hide Inspector" : "Show Inspector") {
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
            Button(UserDefaults.standard.bool(forKey: "sidebarSavedOpen") ? "Hide Saved Sessions" : "Show Saved Sessions") {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "sidebarSavedOpen"), forKey: "sidebarSavedOpen")
            }
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
/// model changes, and a stale disabled item would swallow the shortcut.
private struct SessionMenuItems: View {
    let model: AppModel

    private var session: SessionController? { model.currentSession }

    var body: some View {
        // These answer the first card on screen, which is the record the person
        // is looking at, so the echo still states what was displayed.
        Button("Allow Request") {
            if let session, let record = session.escalations.first, record.canApprove { session.approve(record) }
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
        Button("Allow Request for This Session") {
            if let session, session.role == "owner", let record = session.escalations.first, record.canRemember {
                session.approve(record, remember: true)
            }
        }
        .keyboardShortcut("a", modifiers: [.command, .shift, .option])
        Button("Deny Request") {
            if let session, let record = session.escalations.first { session.deny(record) }
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        Divider()
        Button("Stop Run") {
            if session?.isBusy == true { session?.abort() }
        }
            .keyboardShortcut(".")
        Button("Find in Transcript") { session?.isSearching = true }
            .keyboardShortcut("f")
        Button("Refresh Changes") { session?.requestDiff() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let items = model.attention
        if items.isEmpty {
            Text("Nothing needs you")
        } else {
            ForEach(items.prefix(8)) { item in
                Button("\(item.agent): \(item.title)") { show(.inbox) }
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
                update(model.attention)
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

    private func update(_ items: [AttentionItem]) {
        NSApp.dockTile.badgeLabel = items.isEmpty ? nil : "\(items.count)"
        let current = Set(items.map(\.id))
        let fresh = items.filter { !known.contains($0.id) }

        // The first read is a backlog, not news.
        let isFirstRead = known.isEmpty && !hasRead
        hasRead = true
        known = current
        guard !isFirstRead, !NSApp.isActive, !isUnderTest,
              UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true else { return }
        for item in fresh {
            let content = UNMutableNotificationContent()
            content.title = item.agent
            content.subtitle = item.kind.title
            content.body = item.title
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
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
