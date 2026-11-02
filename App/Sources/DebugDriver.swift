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
/// Prefixing a line with `#<id> ` writes its result to `<dir>/reply-<id>`. `snapshot`
/// returns the app's state as JSON, `tree` returns the accessibility tree as JSON,
/// and `press <label>` presses a control by its accessibility name.
///
/// Clicks and keys go through `NSApp.sendEvent`, so they take the same hit
/// testing and responder chain as a person's. A check that sets state directly
/// would not notice a button that cannot be clicked.
@MainActor
enum DebugDriver {
    private static var hitch: HitchMeter?
    private static var reply = "ok"

    static func start(model: AppModel) {
        guard let directory = ProcessInfo.processInfo.environment["LOOM_DEBUG_DRIVER"] else { return }
        let commands = URL(fileURLWithPath: directory).appendingPathComponent("commands")
        Task {
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard let text = try? String(contentsOf: commands, encoding: .utf8), !text.isEmpty else { continue }
                try? FileManager.default.removeItem(at: commands)
                let root = URL(fileURLWithPath: directory)
                for line in text.split(separator: "\n") {
                    // A line may start with "#<id> ", which asks for a reply file, so
                    // a test waits on its own command rather than on a sleep.
                    var command = String(line)
                    var id: Substring?
                    if command.hasPrefix("#"), let space = command.firstIndex(of: " ") {
                        id = command[command.index(after: command.startIndex)..<space]
                        command = String(command[command.index(after: space)...])
                    }
                    reply = "ok"
                    await run(command, model: model, directory: root)
                    if let id {
                        try? reply.write(to: root.appendingPathComponent("reply-\(id)"), atomically: true, encoding: .utf8)
                    }
                }
                try? "done".write(to: root.appendingPathComponent("ack"), atomically: true, encoding: .utf8)
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
        case "run" where parts.count > 1:
            // Sends one session command from the current session with a JSON body,
            // for set-up a scenario does not itself test: `run goal_set {...}`.
            let json = rest.dropFirst(parts[1].count).trimmingCharacters(in: .whitespaces)
            let body = (try? JSONValue.parse(Data((json.isEmpty ? "{}" : json).utf8))) ?? .object([:])
            model.currentSession?.run(String(parts[1]), body: body)
        case "shutdown":
            // Asks the first daemon to drain, which hands every held prompt back.
            do { try await model.daemons.first?.control?.shutdown() } catch { reply = "error: \(error.localizedDescription)" }
        case "stopall":
            // Frees every daemon slot, so one scenario cannot starve the next, and
            // closes the inspector, so the next one starts from the default layout.
            model.showsInspector = false
            for daemon in model.daemons {
                for record in daemon.sessions where record.state.isResident {
                    try? await daemon.stop(record.id)
                }
            }
        case "focus":
            // Puts the caret in a text field of the open sheet (or window) by its
            // accessibility label, since a test cannot click without coordinates.
            reply = focusField(labelled: rest) ? "ok" : "not-found"
        case "clear":
            // Empties the focused text field, which a select-all key cannot do
            // reliably in a sheet.
            if let text = (window?.attachedSheet ?? window)?.firstResponder as? NSTextView {
                text.selectAll(nil)
                text.delete(nil)
            } else {
                reply = "not-found"
            }
        case "snapshot":
            reply = Snapshot.encode(model)
        case "tree":
            reply = AccessibilityAudit.tree()
        case "press":
            // Presses a control by its accessibility label, through the action a
            // screen reader uses, so it needs neither coordinates nor focus.
            reply = AccessibilityAudit.press(label: rest) ? "ok" : "not-found"
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
        case "scrollup":
            // Scrolls the widest scroll view to its top, as a reader dragging up would.
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
            }
            if let content = window?.contentView,
               let scroll = scrollViews(content).max(by: { $0.frame.width < $1.frame.width }) {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        case "detach" where parts.count > 1:
            // Ends the session's socket so the daemon connection attaches a fresh
            // lane, which opens on the recent window and not on everything held.
            model.controller(for: parts[1])?.detach()
        case "strand" where parts.count > 1:
            model.currentSession?.focusedStrand = parts[1]
        case "lanedelay" where parts.count > 1:
            // Holds each send before it reaches the lane, so a test can see the
            // pending line that a quick daemon answer would remove at once.
            ComposerModel.debugSendDelay = Int(parts[1]).flatMap { $0 > 0 ? Duration.milliseconds($0) : nil }
        case "pasteimage" where parts.count > 1:
            pasteImage(at: rest)
        case "staleapprove":
            // Answers the pending request with a copy whose sequence is one behind, as a
            // card does when the record moved after it was drawn.
            if let controller = model.currentSession, let record = controller.escalations.first {
                controller.approve(Escalation(
                    id: record.id, seq: record.seq - 1, status: record.status, strand: record.strand, tool: record.tool,
                    action: record.action, preview: record.preview, reason: record.reason, source: record.source, grants: record.grants
                ))
            }
        case "approve" where parts.count > 1:
            if let controller = model.controller(for: parts[1]), let record = controller.escalations.first {
                controller.approve(record)
            }
        case "connect" where parts.count > 2:
            let token = (try? String(contentsOf: directory.appendingPathComponent("token"), encoding: .utf8)) ?? ""
            try? model.addDaemon(name: parts[1], address: parts[2], token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        case "dispatch" where parts.count > 3:
            guard let daemon = model.daemons.first else { return }
            do {
                let id = try await daemon.dispatch(
                    workspace: parts[2],
                    name: parts[3],
                    prompt: parts[3],
                    placement: parts[1] == "local" ? .local : .executor(parts[1]),
                    configuration: daemon.localRoot?.appendingPathComponent("loom.toml").path ?? "",
                    requestKey: UUID().uuidString
                )
                model.destination = .session(id)
            } catch {
                reply = "error: \(error.localizedDescription)"
            }
        default:
            break
        }
    }

    // MARK: Paste

    /// Pastes an image file through the real Edit > Paste path. The general
    /// pasteboard is borrowed for the moment of the paste and restored after, so
    /// a person's clipboard is not left holding a test image.
    private static func pasteImage(at path: String) {
        guard let data = FileManager.default.contents(atPath: path), let image = NSImage(data: data) else {
            reply = "error: cannot read an image at \(path)"
            return
        }
        let board = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        board.clearContents()
        board.writeObjects([image])

        // The window is key but the app is not active, so the responder is addressed
        // directly instead of through the application's own search for a target.
        let responder = window?.firstResponder
        let handled = NSApp.sendAction(#selector(NSText.paste(_:)), to: responder, from: nil)
        reply = "handled=\(handled) responder=\(responder.map { "\(type(of: $0))" } ?? "none") target=\(PasteBridge.target != nil)"
        board.clearContents()
        for item in saved {
            let restored = NSPasteboardItem()
            for (type, data) in item { restored.setData(data, forType: type) }
            board.writeObjects([restored])
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

    /// Finds an accessibility element of the open sheet (or window) by role and name.
    private static func element(role wanted: [String], named label: String) -> NSObject? {
        guard let target = window?.attachedSheet ?? window else { return nil }
        var found: NSObject?
        AccessibilityAudit.visitElements(of: target) { node, role, name in
            guard found == nil, wanted.contains(role), name == label || name.hasPrefix(label + ",") else { return }
            found = node
        }
        return found
    }

    private static func focusField(labelled label: String) -> Bool {
        guard let field = element(role: ["AXTextField", "AXTextArea"], named: label) else { return false }
        let setter = Selector(("setAccessibilityFocused:"))
        guard field.responds(to: setter) else { return false }
        _ = field.perform(setter, with: NSNumber(value: true))
        return true
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
        // Typing goes to a sheet when one is up, as it does for a person.
        guard let window = window?.attachedSheet ?? window else { return }
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

/// The app's state as JSON, for assertions that do not depend on pixels.
@MainActor
enum Snapshot {
    static func encode(_ model: AppModel) -> String {
        let destination: String
        switch model.destination {
        case .inbox: destination = "inbox"
        case .mission: destination = "mission"
        case .machines: destination = "machines"
        case .session(let id): destination = "session:\(id)"
        case nil: destination = "none"
        }
        var body: [String: Any] = [
            "destination": destination,
            "isDispatching": model.isDispatching,
            "pendingAction": model.actions.summary,
            "actionError": model.actions.error ?? "",
            "isPaletteOpen": model.isPaletteOpen,
            "showsInspector": model.showsInspector,
            "showsSidebar": model.sidebarVisibility != .detailOnly,
            "isMultiMachine": model.isMultiMachine,
            "isDaemonMissing": model.isDaemonMissing,
            "attention": model.attention.map { ["id": $0.id, "kind": $0.kind.title, "agent": $0.agent, "title": $0.title] },
            "cards": model.cards.map { ["name": $0.name, "liveness": $0.liveness.label, "placement": $0.placement?.label ?? ""] },
            "daemons": model.daemons.map { daemon -> [String: Any] in
                let state: String
                switch daemon.state {
                case .connecting: state = "connecting"
                case .connected: state = "connected"
                case .unavailable: state = "unavailable"
                }
                return [
                    "label": daemon.label,
                    "state": state,
                    "deployment": daemon.deployment?.state ?? "",
                    "lastCreation": daemon.lastCreation,
                    "nodes": (daemon.deployment?.nodes ?? []).map { ["name": $0.name, "state": $0.state] },
                    "sessions": daemon.sessions.map { record -> [String: Any] in
                        ["id": record.id, "title": record.title, "state": record.state.label,
                         "activity": daemon.activity[record.id]?.state.rawValue ?? "",
                         "workspace": record.workspace, "executor": record.executor ?? "", "moving": record.movingTo ?? ""]
                    },
                ]
            },
        ]
        if let session = model.currentSession {
            body["session"] = [
                "isLive": session.isLive,
                "thinkingLevel": session.strand?.thinkingLevel ?? "",
                "profile": session.surfaces["profile"]?["profile"]?.string ?? "",
                "isBusy": session.isBusy,
                "isAdopted": session.isAdopted,
                "blocks": session.blocks.count,
                "escalations": session.escalations.map(\.id),
                "lastError": session.lastError ?? "",
                "hasStream": session.stream != nil,
                "context": session.context?.footer ?? "",
                "todo": session.todo?.progress ?? "",
                "strandLines": session.strandLines.map { "\($0.name): \($0.statusLine(elapsed: nil))" },
                "goal": GoalBoard(session.surfaces["goal"]?["board"])?.statusWord ?? "",
                "readFailures": session.readFailures,
                "endedWords": session.ended?.headline ?? "",
                "side": session.showsSideQuestion,
                "focused": session.focusedStrand,
                "strands": session.strands.map(\.id),
                "transcript": session.blocks.map { block -> String in
                    switch block {
                    case .fold(let fold):
                        return fold.title + ": " + ToolSummary.describe(fold.rows.filter { if case .tool = $0.kind { return true }; return false })
                    case .row(let row):
                        switch row.kind {
                        case .user(let text, _), .assistant(let text), .thinking(let text), .notice(let text), .failure(let text): return text
                        case .tool(let name, _, _, _): return name
                        case .spawned(let child, let purpose): return "spawned \(child) \(purpose)"
                        case .agentReport(let child, let outcome, let report): return "report \(child) \(outcome) \(report)"
                        case .decision(let tool, let summary, let outcome): return "decision \(outcome) \(tool) \(summary)"
                        case .memory(let lines, _): return MemoryContext.summary(lines: lines)
                        }
                    }
                },
                "folds": session.blocks.compactMap { block -> [String: Any]? in
                    guard case .fold(let fold) = block else { return nil }
                    return ["title": fold.title, "steps": fold.steps, "files": fold.files, "failed": fold.failed, "live": fold.isLive,
                            "added": fold.added, "removed": fold.removed, "rows": fold.rows.count, "interrupted": fold.isInterrupted,
                            "details": fold.rows.compactMap { $0.details?.compactText }]
                },
                "focusedStrand": session.focusedStrand,
                "hasOlder": session.hasOlder,
                "isLoadingOlder": session.isLoadingOlder,
                "turnStartedAt": session.turnStartedAt != nil,
                "streamThinking": session.stream?.thinking.count ?? 0,
                "pendingInputs": session.pendingInputs.map { ["text": $0.text, "kind": $0.kind, "editable": $0.editable] as [String: Any] },
                "pendingDrafts": session.composer.ledger.lines.map(\.text),
                "draft": session.composer.draft,
                "images": session.composer.images.map(\.name),
                "userImages": session.blocks.reduce(0) { total, block in
                    if case .row(let row) = block { return total + row.images }
                    return total
                },
                "notice": session.composer.notice?.text ?? "",
                "noticeIsWarning": session.composer.notice?.tone == .warning,
                "slashRows": session.composer.suggestions(catalogue: session.catalogue).map(\.command),
                "slashSelected": session.composer.selection,
                "btwStatus": session.showsSideQuestion ? session.surfaces["btw"]?["board"]?["status"]?.string ?? "" : "",
                "editing": session.composer.editing?.text ?? "",
                "models": session.catalogue.models,
                "outputRate": session.outputRate ?? 0,
                "pushedEvents": session.pushedEvents,
                "to": StrandName.display(session.focusedStrand),
                "who": session.who ?? "",
                "cacheOutlook": session.cacheOutlook(at: Date()) ?? "",
                "peers": session.peers.map { "\($0.name) · \($0.role)" },
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
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
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.attachedSheet != nil } ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    /// Reads an accessibility property only if the object answers it. SwiftUI's nodes
    /// answer these selectors without declaring the protocol, and a key-value read
    /// of a key an object lacks raises an exception that ends this task silently.
    private static func read(_ node: NSObject, _ key: String) -> Any? {
        node.responds(to: Selector(key)) ? node.value(forKey: key) : nil
    }

    /// Walks the tree once per node. It can hold cycles through its window and
    /// toolbar references, so a plain recursion would never finish.
    private static func visit(_ root: Any, _ body: (NSObject, Int) -> Void) {
        var seen = Set<ObjectIdentifier>()
        func walk(_ element: Any, _ depth: Int) {
            guard depth < 60, seen.count < 6000, let node = element as? NSObject,
                  seen.insert(ObjectIdentifier(node)).inserted else { return }
            body(node, depth)
            for child in read(node, "accessibilityChildren") as? [Any] ?? [] {
                walk(child, depth + 1)
            }
        }
        walk(root, 0)
    }

    /// Calls `body` with every element under `root`, its role and its name.
    static func visitElements(of root: Any, _ body: (NSObject, String, String) -> Void) {
        visit(root) { node, _ in body(node, role(node), name(node)) }
    }

    private static func name(_ node: NSObject) -> String {
        let label = read(node, "accessibilityLabel") as? String ?? ""
        return label.isEmpty ? read(node, "accessibilityTitle") as? String ?? "" : label
    }

    private static func role(_ node: NSObject) -> String {
        read(node, "accessibilityRole") as? String ?? ""
    }

    /// Every element as JSON: role, name, value, frame and whether it is enabled.
    static func tree() -> String {
        guard let window = mainWindow else { return "[]" }
        var rows: [[String: Any]] = []
        let roots = searchRoots(window)
        for root in roots {
            visit(root) { node, depth in
                let frame = (read(node, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                rows.append([
                    "role": role(node),
                    "name": name(node),
                    "value": read(node, "accessibilityValue").map { "\($0)" } ?? "",
                    "enabled": (node as? NSControl)?.isEnabled ?? (read(node, "isAccessibilityEnabled") as? Bool) ?? true,
                    "depth": depth,
                    // A detached element reports an infinite frame, which JSON cannot hold.
                    "frame": [frame.origin.x, frame.origin.y, frame.width, frame.height].map { $0.isFinite ? $0 : 0 },
                ])
            }
        }
        guard JSONSerialization.isValidJSONObject(rows),
              let data = try? JSONSerialization.data(withJSONObject: rows) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The window, its sheet and its child windows. A popover is a child window,
    /// so its controls are part of what a person sees.
    private static func searchRoots(_ window: NSWindow) -> [Any] {
        var roots: [Any] = [window]
        if let sheet = window.attachedSheet { roots.append(sheet) }
        roots.append(contentsOf: (window.childWindows ?? []) as [Any])
        return roots
    }

    /// Whether a control accepts a press. A disabled control reports false, so a
    /// scenario that presses it waits for it to arm instead of pressing nothing.
    private static func isEnabled(_ node: NSObject) -> Bool {
        guard node.responds(to: Selector(("isAccessibilityEnabled"))) else { return true }
        return (node.value(forKey: "accessibilityEnabled") as? Bool) ?? true
    }

    static func press(label: String) -> Bool {
        guard let window = mainWindow else { return false }
        var target: NSObject?
        for root in searchRoots(window) {
            visit(root) { node, _ in
                guard target == nil, name(node) == label, isEnabled(node) else { return }
                if ["AXButton", "AXLink", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXRow", "AXCell"].contains(role(node)) {
                    target = node
                }
            }
        }
        let press = Selector(("accessibilityPerformPress"))
        guard let target, target.responds(to: press) else { return false }
        _ = target.perform(press)
        return true
    }

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
