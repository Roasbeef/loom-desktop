import Foundation

/// Where a daemon listens and the credential that admits this client.
///
/// `CustomStringConvertible` deliberately omits the token, so interpolating
/// this value into a log line cannot leak the bearer.
public struct DaemonEndpoint: Sendable, Equatable, CustomStringConvertible {
    public let host: String
    public let port: Int
    public let token: String

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    public var description: String { "\(host):\(port)" }

    /// The daemon binds loopback only and terminates no TLS, so a bearer may
    /// travel over `ws://` only to a loopback address (protocol section 2.4).
    public var isLoopback: Bool {
        ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host)
    }

    func url(path: String) throws -> URL {
        guard isLoopback else {
            throw LoomError.discovery("Refusing to send a bearer over cleartext to \(host).")
        }
        guard let url = URL(string: "ws://\(host):\(port)\(path)") else {
            throw LoomError.discovery("The endpoint \(self) does not form a URL.")
        }
        return url
    }
}

/// Reads the discovery files a running daemon leaves under its state root.
public enum DaemonDiscovery {
    /// The default state root, `~/.loom`.
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".loom")
    }

    /// Reads `daemon.endpoint` and `owner.token` under `root`.
    ///
    /// A daemon's readiness is proved only by the authenticated control
    /// exchange that follows, so a stale record surfaces there as a failed
    /// connection and not here.
    public static func discover(root: URL = defaultRoot) throws -> DaemonEndpoint {
        let recordURL = root.appendingPathComponent("daemon.endpoint")
        guard let recordData = try? Data(contentsOf: recordURL) else {
            throw LoomError.discovery("No daemon record at \(recordURL.path). Is loomd running?")
        }
        let record = try JSONValue.parse(recordData)
        guard let host = record["host"]?.string, let port = record["port"]?.int else {
            throw LoomError.discovery("The daemon record names no host and port.")
        }
        guard let tokenData = try? Data(contentsOf: root.appendingPathComponent("owner.token")) else {
            throw LoomError.discovery("No owner.token under \(root.path).")
        }
        let token = String(decoding: tokenData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOwnerToken(token) else {
            throw LoomError.discovery("owner.token is not 64 hexadecimal characters.")
        }
        return DaemonEndpoint(host: host, port: port, token: token)
    }

    static func isOwnerToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.allSatisfy { $0.isHexDigit }
    }
}
