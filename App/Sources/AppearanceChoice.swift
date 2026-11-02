import AppKit

/// Whether the app follows the system's light or dark appearance or holds one.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    var id: Self { self }

    static let key = "appearance"

    static var stored: AppearanceChoice {
        UserDefaults.standard.string(forKey: key).flatMap(AppearanceChoice.init) ?? .system
    }

    var menuTitle: String {
        switch self {
        case .system: return "Use System Appearance"
        case .light: return "Use Light Appearance"
        case .dark: return "Use Dark Appearance"
        }
    }

    /// Sets the appearance of every window. A nil appearance follows the system.
    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
