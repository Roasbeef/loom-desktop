import LoomKit
import MissionKit
import SwiftUI

@main
struct LoomApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Loom", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    model.start()
                    #if DEBUG
                    DebugDriver.start(model: model)
                    #endif
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Dispatch Agent…") { model.isDispatching = true }
                    .keyboardShortcut("n")
            }
            CommandMenu("Go") {
                Button("Inbox") { model.destination = .inbox }
                    .keyboardShortcut("1")
                Button("Mission Control") { model.destination = .mission }
                    .keyboardShortcut("2")
            }
        }

        // The count stays visible when the window is not, since being told an
        // agent is waiting is most of what a person running a fleet needs.
        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            let waiting = model.attention.count
            Label(waiting == 0 ? "Loom" : "\(waiting)", systemImage: waiting == 0 ? "circle.dotted" : "circle.inset.filled")
                .labelStyle(.titleAndIcon)
        }
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
        Button("Dispatch Agent…") {
            show(.mission)
            model.isDispatching = true
        }
        Divider()
        Button("Quit Loom") { NSApplication.shared.terminate(nil) }
    }

    private func show(_ destination: Destination) {
        model.destination = destination
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
