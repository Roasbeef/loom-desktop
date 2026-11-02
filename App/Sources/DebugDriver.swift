#if DEBUG
import AppKit
import LoomKit
import SwiftUI

/// Drives a debug build from a command file, for verifying the app with no
/// person at the keyboard. It exists because an automated check here has neither
/// screen-recording nor accessibility permission, and it compiles out of release
/// builds. Set `LOOM_DEBUG_DRIVER` to a directory, then write commands, one per
/// line, to `<dir>/commands`:
///
///     go inbox | go mission | go session <id>
///     shot <name>            writes <dir>/<name>.png of the main window
///     prompt <id> <text>     sends through the session's controller
///     approve <id>           allows the session's first pending escalation
///     dark | light
@MainActor
enum DebugDriver {
    static func start(model: AppModel) {
        guard let directory = ProcessInfo.processInfo.environment["LOOM_DEBUG_DRIVER"] else { return }
        let commands = URL(fileURLWithPath: directory).appendingPathComponent("commands")
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                guard let text = try? String(contentsOf: commands, encoding: .utf8), !text.isEmpty else { continue }
                try? FileManager.default.removeItem(at: commands)
                for line in text.split(separator: "\n") {
                    run(String(line), model: model, directory: directory)
                }
            }
        }
    }

    private static func run(_ line: String, model: AppModel, directory: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        switch parts.first {
        case "go" where parts.count > 1:
            switch parts[1] {
            case "inbox": model.destination = .inbox
            case "mission": model.destination = .mission
            case "session" where parts.count > 2: model.destination = .session(parts[2])
            default: break
            }
        case "shot" where parts.count > 1:
            capture(to: URL(fileURLWithPath: directory).appendingPathComponent("\(parts[1]).png"))
        case "prompt" where parts.count > 2:
            model.attach(parts[1])?.send(text: parts[2])
        case "approve" where parts.count > 1:
            if let controller = model.attached[parts[1]], let record = controller.conversation.escalations.first {
                controller.approve(record)
            }
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            break
        }
    }

    private static func capture(to url: URL) {
        guard
            let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
            let frame = window.contentView?.superview ?? window.contentView,
            let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
        else { return }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
