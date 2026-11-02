import CryptoKit
import Foundation

/// What a daemon says about the member a claim named.
public struct ClaimResult: Sendable, Equatable {
    public let principalID: String
    public let name: String
    /// The first 16 hexadecimal characters of the bound digest, which the owner and
    /// the member compare out of band.
    public let fingerprint: String
    public let sessionCount: Int
}

/// Redeems an invitation's claim token for a credential of the invitee's own.
///
/// The claim route is authenticated by the claim, not by a credential, and carries
/// one command that binds the digest of a bearer the client drew itself. The
/// daemon never sees the bearer. The caller stores it before calling `redeem`, so a
/// lost reply is recovered by presenting the same claim and digest again.
public enum Claim {
    public static func isClaimToken(_ text: String) -> Bool {
        let body = text.dropFirst("loomclaim_".count)
        return text.hasPrefix("loomclaim_") && body.count == 64 && body.allSatisfy { $0.isHexDigit }
    }

    /// A fresh bearer: 32 random bytes as 64 lowercase hexadecimal characters.
    public static func newCredential() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// The digest the daemon binds: SHA-256 of the bearer's text, in lowercase hexadecimal.
    public static func digest(of credential: String) -> String {
        SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The claim route of a daemon address, whatever path the address was pasted with.
    public static func claimURL(address: String) throws -> URL {
        guard
            let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme, ["ws", "wss"].contains(scheme), let host = url.host()
        else {
            throw LoomError.discovery("\(address) is not a ws:// or wss:// address.")
        }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = url.port
        parts.path = "/v2/claim"
        guard let result = parts.url else { throw LoomError.discovery("\(address) does not form a URL.") }

        // The claim token is a bearer, so cleartext is for this machine only.
        guard scheme == "wss" || ["127.0.0.1", "::1", "localhost"].contains(host) else {
            throw LoomError.discovery("Use wss:// or an SSH tunnel to a loopback port. A claim must not cross the network in cleartext.")
        }
        return result
    }

    public static func redeem(address: String, claim: String, credential: String) async throws -> ClaimResult {
        guard isClaimToken(claim) else { throw LoomError.discovery("That is not a claim token.") }
        let socket = WebSocket(url: try claimURL(address: address), bearer: claim, maximumMessageSize: 64 * 1024)
        defer { socket.close() }

        let hello = try EventEnvelope.decode(try await withDeadline(seconds: 6, command: "hello") { try await socket.receive() })
        guard hello.event == "hello" else { throw LoomError.protocolViolation("the claim route did not open with hello") }

        let command = try encodeCommand(id: 1, cmd: "credentials.claim", body: .object(["credential_digest": .string(digest(of: credential))]))
        try await socket.send(command)
        let reply = try EventEnvelope.decode(try await withDeadline(seconds: 10, command: "credentials.claim") { try await socket.receive() })
        if reply.event == "error" {
            throw LoomError.server(
                code: reply.body["code"]?.string ?? "unknown",
                message: reply.body["message"]?.string ?? "",
                details: reply.body["details"]
            )
        }
        guard reply.event == "credentials.claim" else { throw LoomError.protocolViolation("unexpected \(reply.event)") }
        return ClaimResult(
            principalID: reply.body["principal_id"]?.string ?? "",
            name: reply.body["name"]?.string ?? "",
            fingerprint: reply.body["fingerprint"]?.string ?? "",
            sessionCount: reply.body["sessions"]?.array?.count ?? 0
        )
    }
}
