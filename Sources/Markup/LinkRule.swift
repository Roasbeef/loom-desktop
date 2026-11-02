import Foundation

/// Decides whether a destination a model wrote may be opened.
///
/// A model's markdown link is text from outside the harness, so it is followed only
/// when it is a plain absolute `http` or `https` address: no other scheme, no
/// credentials in the authority, no whitespace, control or invisible character, and
/// no longer than a browser or server accepts. This is the same rule the web page
/// applies (`web_client/link_rule`), so a link is clickable in one client when it is
/// in the other.
public enum LinkRule {
    /// The longest destination accepted, in characters.
    public static let limit = 2048

    /// The destination exactly as given when it may be opened, or nil.
    public static func destination(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count <= limit, scalars.allSatisfy({ allowed($0.value) }) else { return nil }
        let lowered = text.lowercased()
        let rest: Substring
        if lowered.hasPrefix("https://") {
            rest = text.dropFirst(8)
        } else if lowered.hasPrefix("http://") {
            rest = text.dropFirst(7)
        } else {
            return nil
        }
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty, !authority.hasPrefix(":"), !authority.contains("@") else { return nil }
        return text
    }

    private static func allowed(_ code: UInt32) -> Bool {
        switch code {
        case 0...0x20, 0x5C, 0x7F...0xA0, 0x2060...0x2069, 0x2000...0x200F, 0x2028...0x202F: return false
        case 0xAD, 0x61C, 0x3000, 0xFEFF: return false
        default: return true
        }
    }
}
