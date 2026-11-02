import Foundation

/// The words for why a session's connection ended, with advice that fits.
///
/// The reference page words each ending with a headline and one line of fixed
/// advice (`web_view/ending`). The native client maps the failures its lane can
/// report onto the same few endings, so a person reads a reason and a next step
/// and not a transport error.
public struct EndingWords: Sendable, Equatable {
    public let headline: String
    public let advice: String

    /// Words for the error a lane ended with. A nil error is a close this client
    /// asked for, which needs no explanation.
    public static func notice(for error: LoomError?) -> EndingWords? {
        guard let error else { return nil }
        switch error {
        case .upgradeRefused(let status) where status == 401 || status == 403:
            return EndingWords(
                headline: "Your access to this session was revoked or changed.",
                advice: "Ask the session's owner to restore your access.")
        case .upgradeRefused:
            return EndingWords(
                headline: "The session is not open.",
                advice: "Open the session again from the list. The app reconnects once it is running.")
        case .outcomeUnknown(let command):
            return EndingWords(
                headline: "The daemon did not answer \(command) in time.",
                advice: "Its outcome is unknown. The transcript shows whether it was applied, and nothing is resent.")
        case .protocolViolation:
            return EndingWords(
                headline: "The daemon broke a protocol rule, so the connection was closed.",
                advice: "What is shown may be out of date. Reconnecting starts from a fresh read.")
        case .server(_, let message, _):
            return EndingWords(headline: PanelWords.oneLine(message), advice: "The app reconnects on its own.")
        case .closed, .discovery:
            return EndingWords(
                headline: "The connection to the session closed.",
                advice: "The app reconnects on its own while the session is running.")
        }
    }
}
