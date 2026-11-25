import AppKit

/// The system folder panel, which the folder picker's "Open folder…" row runs for
/// anything its search does not list. It answers the chosen path, or nil when the
/// person cancelled. No form builds a panel of its own: the new-session and the
/// new-project sheets both choose through `FolderPickerChip`, which opens
/// `FolderPickerPopover`, and this is the one place a panel is made.
enum FolderChoice {
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
