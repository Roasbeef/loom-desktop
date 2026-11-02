import Foundation

/// Display words shared by the panels, kept in one place so that two surfaces
/// never format the same quantity two ways.
///
/// The formats follow the reference client's `agent_roster` and `live_jobs`
/// modules, so a figure reads the same in the web view and here.
public enum PanelWords {
    /// Abbreviates a token count to one decimal in the thousands or millions,
    /// so a figure watched for a minute shows movement.
    ///
    /// `count(136_540)` is `136.5k`, and `count(950)` is `950`.
    public static func count(_ value: Int) -> String {
        func tenths(_ unit: Int) -> String {
            let scaled = value * 10 / unit
            return "\(scaled / 10).\(scaled % 10)"
        }
        if value >= 1_000_000 { return tenths(1_000_000) + "m" }
        if value >= 1000 { return tenths(1000) + "k" }
        return String(max(0, value))
    }

    /// A run's length in the roster's form: `45s`, `3m 05s`, `1h 02m`.
    public static func duration(seconds: Int) -> String {
        if seconds >= 3600 {
            return "\(seconds / 3600)h " + String(format: "%02d", (seconds % 3600) / 60) + "m"
        }
        if seconds >= 60 {
            return "\(seconds / 60)m " + String(format: "%02d", seconds % 60) + "s"
        }
        return "\(max(0, seconds))s"
    }

    /// An age within the daemon's own clock domain, in the jobs form:
    /// `45s`, `3m 5s`, `1h 2m`. A negative difference reads as zero.
    public static func age(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    /// Collapses whitespace and drops control characters, so model-written text
    /// fits on one line without a hidden character changing what it says.
    public static func oneLine(_ text: String) -> String {
        let cleaned = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{2028}" || scalar == "\u{2029}"
                ? " " : Character(scalar)
        }
        return String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cuts a line to `limit` characters, marking the cut.
    public static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    /// The last path component of a model name, as the strand cards show it.
    public static func modelName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}
