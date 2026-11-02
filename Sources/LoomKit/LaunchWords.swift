import Foundation

/// The command that reaches a session held by another orchestrator, in the words
/// every Loom client uses for it.
///
/// This app holds no credential for that orchestrator, so it cannot open the
/// session itself. It says which launch does, on the machine whose owner token
/// that launch needs. The line names the token file with a placeholder, since the
/// file is on the other machine.
public enum LaunchWords {
    public static let unknownAddress = "<its control address>"
    public static let tokenPlaceholder = "<owner token file on that host>"

    public static func line(address: String?, session: String) -> String {
        "loom --addr \(address ?? unknownAddress) --session \(session) --token-file \(tokenPlaceholder)"
    }
}
