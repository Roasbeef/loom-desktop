#if DEBUG
import AppKit
import LoomKit
import QuartzCore
import SwiftUI

/// Drives a debug build from a command file, for verifying the app with no
/// person at the keyboard. It exists because an automated check here has neither
/// screen-recording nor accessibility permission, and it compiles out of release
/// builds. Set `LOOM_DEBUG_DRIVER` to a directory, then write commands, one per
/// line, to `<dir>/commands`:
///
///     go inbox | go mission | go machines | go session <id>
///     shot <name>          the composited window, glass included, as PNG
///     click <x> <y>        a real mouse click, in points from the top left
///     rclick <x> <y>       a real right click
///     type <text>          real key events
///     key <name> [mods]    return, escape, up, down, tab, or a letter; cmd,shift,opt
///     resize <w> <h>       the main window's size
///     activate | deactivate   take and return focus, for a check of clicks
///     menu <title>         invokes a menu item
///     menus                every key equivalent the menu bar claims
///     dark | light
///     hitch start | hitch stop <name>   frame gaps while running
///     ax <name>            the accessibility tree and its unlabeled controls
///     stats <name>         CPU, memory and uptime of this process
///     prompt <id> <text> | approve <id>
///     connect <name> <address>     with the token in <dir>/token
///     dispatch <executor> <workspace> <prompt>
///
/// Clicks and keys go through `NSApp.sendEvent`, so they take the same hit
/// testing and responder chain as a person's. A check that sets state directly
/// would not notice a button that cannot be clicked.
@MainActor
enum DebugDriver {
    private static var hitch: HitchMeter?

    static func start(model: AppModel) {
        guard let directory = ProcessInfo.processInfo.environment["LOOM_DEBUG_DRIVER"] else { return }
        let commands = URL(fileURLWithPath: directory).appendingPathComponent("commands")
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard let text = try? String(contentsOf: commands, encoding: .utf8), !text.isEmpty else { continue }
                try? FileManager.default.removeItem(at: commands)
                for line in text.split(separator: "\n") {
                    await run(String(line), model: model, directory: URL(fileURLWithPath: directory))
                }
                try? "done".write(to: URL(fileURLWithPath: directory).appendingPathComponent("ack"), atomically: true, encoding: .utf8)
            }
        }
    }

    private static var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frame.width > 400 && $0.canBecomeMain }
    }

    private static func run(_ line: String, model: AppModel, directory: URL) async {
        let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
        let rest = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        switch parts.first {
        case "go" where parts.count > 1:
            switch parts[1] {
            case "inbox": model.destination = .inbox
            case "mission": model.destination = .mission
            case "machines": model.destination = .machines
            case "session" where parts.count > 2: model.destination = .session(parts[2])
            default: break
            }
        case "shot" where parts.count > 1:
            capture(to: directory.appendingPathComponent("\(parts[1]).png"))
        case "click" where parts.count > 2:
            click(x: Double(parts[1]) ?? 0, y: Double(parts[2]) ?? 0, right: false)
        case "rclick" where parts.count > 2:
            click(x: Double(parts[1]) ?? 0, y: Double(parts[2]) ?? 0, right: true)
        case "type":
            for character in rest { send(key: String(character), code: 0, flags: []) }
        case "key" where parts.count > 1:
            press(parts[1], modifiers: parts.count > 2 ? parts[2] : "")
        case "resize" where parts.count > 2:
            if let window {
                let size = NSSize(width: Double(parts[1]) ?? 1200, height: Double(parts[2]) ?? 800)
                window.setContentSize(size)
            }
        case "state":
            let session = NSApp.keyWindow?.firstResponder.map { "\(type(of: $0))" } ?? "none"
            let text = "destination=\(String(describing: model.destination)) responder=\(session) modal=\(NSApp.modalWindow != nil) sheets=\(NSApp.keyWindow?.sheets.count ?? -1) inspector=\(model.showsInspector) palette=\(model.isPaletteOpen) dispatching=\(model.isDispatching) adding=\(model.isAddingDaemon) current=\(model.currentSession != nil) escalations=\(model.currentSession?.escalations.count ?? -1) canApprove=\(model.currentSession?.escalations.first?.canApprove ?? false) grants=\(model.currentSession?.escalations.first?.grants.count ?? -1) live=\(model.currentSession?.isLive ?? false)\n"
            try? text.write(to: directory.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
        case "activate":
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        case "deactivate":
            NSApp.deactivate()
        case "menu":
            // Invokes a menu item by title, the way a click on it does.
            func find(_ menu: NSMenu) -> (NSMenu, Int)? {
                for (index, item) in menu.items.enumerated() {
                    if item.title == rest { return (menu, index) }
                    if let sub = item.submenu, let hit = find(sub) { return hit }
                }
                return nil
            }
            if let main = NSApp.mainMenu, let (menu, index) = find(main) {
                menu.performActionForItem(at: index)
            }
        case "menus":
            // Lists every key equivalent the menu bar claims, to find collisions.
            var rows: [String] = []
            func walk(_ menu: NSMenu) {
                for item in menu.items {
                    if !item.keyEquivalent.isEmpty {
                        rows.append("\(item.keyEquivalentModifierMask.rawValue) \(item.keyEquivalent) \(item.title) enabled=\(item.isEnabled)")
                    }
                    if let sub = item.submenu { walk(sub) }
                }
            }
            if let main = NSApp.mainMenu { walk(main) }
            try? rows.joined(separator: "\n").write(to: directory.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "hitch" where parts.count > 1:
            if parts[1] == "start" {
                hitch = HitchMeter()
                hitch?.start()
            } else if parts[1] == "stop", let meter = hitch {
                let name = parts.count > 2 ? parts[2] : "hitch"
                try? meter.stop().write(to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
                hitch = nil
            }
        case "ax" where parts.count > 1:
            try? AccessibilityAudit.run().write(to: directory.appendingPathComponent("\(parts[1]).txt"), atomically: true, encoding: .utf8)
        case "stats" where parts.count > 1:
            try? processStats().write(to: directory.appendingPathComponent("\(parts[1]).txt"), atomically: true, encoding: .utf8)
        case "prompt" where parts.count > 2:
            let text = parts.dropFirst(2).joined(separator: " ")
            model.daemon(holding: parts[1])?.attach(parts[1])?.send(text: text)
        case "approve" where parts.count > 1:
            if let controller = model.controller(for: parts[1]), let record = controller.escalations.first {
                controller.approve(record)
            }
        case "connect" where parts.count > 2:
            let token = (try? String(contentsOf: directory.appendingPathComponent("token"), encoding: .utf8)) ?? ""
            try? model.addDaemon(name: parts[1], address: parts[2], token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        case "dispatch" where parts.count > 3:
            guard let daemon = model.daemons.first else { return }
            let id = try? await daemon.dispatch(
                workspace: parts[2],
                name: parts[3],
                prompt: parts[3],
                placement: parts[1] == "local" ? .local : .executor(parts[1]),
                configuration: daemon.localRoot?.appendingPathComponent("loom.toml").path ?? "",
                requestKey: UUID().uuidString
            )
            if let id { model.destination = .session(id) }
        default:
            break
        }
    }

    // MARK: Capture

    private typealias WindowListCreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Captures this process's own window from the window server, so glass and
    /// vibrancy appear as a person sees them. `cacheDisplay` would redraw the
    /// views offscreen, which skips the compositor and shows flat fills. The call
    /// is looked up at run time because the SDK no longer exposes it, and a
    /// process may always read its own windows without screen-recording access.
    private static func capture(to url: URL) {
        // An open sheet is its own window, and it is what a person is looking at.
        guard let window = window?.attachedSheet ?? window else { return }
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        guard let symbol = dlsym(handle, "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: WindowListCreateImage.self)

        // Below the window, and only this window, with its bounds and no shadow.
        let optionIncludingWindow: UInt32 = 1 << 3
        let imageBoundsIgnoreFraming: UInt32 = 1 << 0
        guard let image = create(.null, optionIncludingWindow, UInt32(window.windowNumber), imageBoundsIgnoreFraming)?.takeRetainedValue() else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Input

    private static func click(x: Double, y: Double, right: Bool) {
        guard let window, let content = window.contentView else { return }
        let point = NSPoint(x: x, y: content.frame.height - y)

        // Deliberately no activation: a check must not take focus from a person
        // working in another app. The event still takes the normal hit testing.
        window.makeKey()
        let events: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.mouseMoved, .leftMouseDown, .leftMouseUp]
        for type in events {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) {
                // Queued rather than delivered directly, because a table's mouse
                // tracking waits for the matching mouse-up from the event queue.
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func press(_ name: String, modifiers: String) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains("cmd") { flags.insert(.command) }
        if modifiers.contains("shift") { flags.insert(.shift) }
        if modifiers.contains("opt") { flags.insert(.option) }
        if modifiers.contains("ctrl") { flags.insert(.control) }
        let table: [String: (String, UInt16)] = [
            "return": ("\r", 36), "escape": ("\u{1B}", 53), "tab": ("\t", 48), "space": (" ", 49),
            "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
            "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125),
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123),
            "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            "delete": ("\u{7F}", 51),
        ]
        let (characters, code) = table[name] ?? (name, 0)
        send(key: characters, code: code, flags: flags)
    }

    private static func send(key: String, code: UInt16, flags: NSEvent.ModifierFlags) {
        guard let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code
            ) else { continue }

            // A key equivalent goes to the menu first, as it would for a person.
            if type == .keyDown, flags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                continue
            }
            NSApp.sendEvent(event)
        }
    }

    private static func processStats() -> String {
        var info = rusage()
        getrusage(RUSAGE_SELF, &info)
        let cpu = Double(info.ru_utime.tv_sec + info.ru_stime.tv_sec)
            + Double(info.ru_utime.tv_usec + info.ru_stime.tv_usec) / 1_000_000
        let key = NSApp.keyWindow != nil
        return "cpu_seconds=\(cpu) max_rss_mb=\(info.ru_maxrss / 1_048_576) uptime=\(ProcessInfo.processInfo.systemUptime) active=\(NSApp.isActive) key=\(key)\n"
    }
}

/// Records the gap between display refreshes on the main thread. A gap well over
/// one refresh is a frame the person saw drop.
@MainActor
final class HitchMeter: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []

    func start() {
        guard let view = NSApp.windows.first(where: \.isVisible)?.contentView else { return }
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { gaps.append((link.timestamp - last) * 1000) }
        last = link.timestamp
    }

    func stop() -> String {
        link?.invalidate()
        let sorted = gaps.sorted()
        guard !sorted.isEmpty else { return "no frames\n" }
        func percentile(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
        let over25 = sorted.filter { $0 > 25 }.count
        let over50 = sorted.filter { $0 > 50 }.count
        return String(
            format: "frames=%d p50=%.1fms p95=%.1fms p99=%.1fms max=%.1fms over25ms=%d over50ms=%d\n",
            sorted.count, percentile(0.5), percentile(0.95), percentile(0.99), sorted.last ?? 0, over25, over50
        )
    }
}

/// Walks the window's accessibility tree, the way VoiceOver reads it.
@MainActor
enum AccessibilityAudit {
    static func run() -> String {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return "no window\n" }
        var lines: [String] = []
        var controls = 0
        var unlabeled: [String] = []

        func walk(_ element: Any, depth: Int) {
            guard depth < 40, let node = element as? NSAccessibilityElementProtocol as? NSObject else { return }
            let role = node.value(forKey: "accessibilityRole") as? String ?? ""
            let label = node.value(forKey: "accessibilityLabel") as? String ?? ""
            let title = node.value(forKey: "accessibilityTitle") as? String ?? ""
            let value = node.value(forKey: "accessibilityValue").map { "\($0)" } ?? ""
            let isControl = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea", "AXSlider"].contains(role)
            if isControl {
                controls += 1
                if label.isEmpty && title.isEmpty {
                    unlabeled.append("\(role) value=\(value.prefix(40))")
                }
            }
            if !role.isEmpty && !(role == "AXGroup" && label.isEmpty) {
                lines.append(String(repeating: " ", count: depth) + "\(role) \(label.isEmpty ? title : label)".prefix(120))
            }
            for child in node.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        walk(window, depth: 0)
        return "controls=\(controls) unlabeled=\(unlabeled.count)\n"
            + unlabeled.map { "UNLABELED \($0)" }.joined(separator: "\n") + "\n---\n"
            + lines.joined(separator: "\n") + "\n"
    }
}
#endif
