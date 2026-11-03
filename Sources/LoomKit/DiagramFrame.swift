import Foundation

/// The frame contract of Loom's protocol-change/091, as far as the app needs it.
public enum DiagramProtocol {
    public static let scheme = "loom-diagram"
    public static let host = URL(string: "\(scheme)://frame/host.html")!

    /// Heights outside these bounds are clamped, as the web view clamps them.
    public static let minimumHeight: CGFloat = 120
    public static let maximumHeight: CGFloat = 2000

    /// The renderer refuses longer source, so the app does not send it.
    public static let sourceLimit = 32_000

    /// How long a request may go unanswered before the block falls back to source.
    public static let deadline: Duration = .seconds(10)

    /// The longest diagnostic drawn, in characters.
    public static let diagnosticLimit = 2000

    /// The request the frame expects, as a JSON string.
    public static func request(source: String, theme: String, revision: Int) -> String? {
        let body: [String: Any] = ["source": source, "theme": theme, "revision": revision]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public enum Reply: Equatable {
        case ready
        case rendered(revision: Int, height: CGFloat)
        case failed(revision: Int, diagnostic: String?)
    }

    /// Reads one of the frame's fixed replies. Anything else is ignored.
    public static func reply(_ text: String) -> Reply? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else { return nil }
        switch kind {
        case "ready":
            return .ready
        case "rendered":
            guard let revision = object["revision"] as? Int, let height = object["height"] as? Double else { return nil }
            return .rendered(revision: revision, height: min(max(CGFloat(height), minimumHeight), maximumHeight))
        case "failed":
            guard let revision = object["revision"] as? Int else { return nil }
            let diagnostic = (object["diagnostic"] as? String).map { String($0.prefix(diagnosticLimit)) }
            return .failed(revision: revision, diagnostic: diagnostic)
        default:
            return nil
        }
    }
}
