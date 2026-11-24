import AppKit

/// The one call every form that asks for a folder makes. It runs the system folder
/// panel and answers the chosen path, or nil when the person cancelled. A form never
/// builds a panel of its own, so replacing the choice (a searchable popover is
/// planned) changes this function and no caller.
enum FolderChoice {
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
