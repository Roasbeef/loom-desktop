import Foundation

/// A failure this client reports to its caller.
public enum LoomError: Error, Sendable, Equatable, LocalizedError {
    /// The daemon's discovery files are missing or unusable.
    case discovery(String)
    /// The server refused a command with a machine-readable code.
    case server(code: String, message: String, details: JSONValue?)
    /// The upgrade was refused with this HTTP status.
    case upgradeRefused(status: Int)
    /// The server broke a protocol rule, so the connection cannot be trusted.
    case protocolViolation(String)
    /// No reply arrived in time. A mutation's outcome is unknown and is never
    /// resent automatically (client protocol section 6.5).
    case outcomeUnknown(command: String)
    /// The connection closed.
    case closed(String)

    public var errorDescription: String? {
        switch self {
        case .discovery(let text): return text
        case .server(let code, let message, _): return Refusal.words(code: code, message: message) ?? "\(code): \(message)"
        case .upgradeRefused(let status): return "The daemon refused the connection (HTTP \(status))."
        case .protocolViolation(let text): return "Protocol violation: \(text)"
        case .outcomeUnknown(let command): return "No reply to \(command); its outcome is unknown."
        case .closed(let text): return "Connection closed: \(text)"
        }
    }
}

/// One server frame, in the `v: 2` event envelope.
public struct EventEnvelope: Sendable, Equatable {
    public let replyTo: Int?
    public let event: String
    public let seq: Int?
    public let body: JSONValue

    /// Decodes a text frame. Anything but a `v: 2` object is a violation.
    public static func decode(_ text: String) throws -> EventEnvelope {
        let value = try JSONValue.parse(Data(text.utf8))
        guard value["v"]?.int == 2, let event = value["event"]?.string else {
            throw LoomError.protocolViolation("frame is not a v2 event envelope")
        }
        return EventEnvelope(
            replyTo: value["reply_to"]?.int,
            event: event,
            seq: value["seq"]?.int,
            body: value["body"] ?? .object([:])
        )
    }
}

/// Encodes one command envelope as the text of a frame.
func encodeCommand(id: Int, cmd: String, body: JSONValue) throws -> String {
    let envelope: JSONValue = .object(["v": 2, "id": .int(Int64(id)), "cmd": .string(cmd), "body": body])
    return String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
}

/// A first-in, first-out lock for use across suspension points.
///
/// The protocol's stop-and-wait credit allows one command in flight, and a
/// snapshot transfer must hold that credit across many exchanges. An actor
/// alone cannot express that, because it releases its isolation at each await.
actor CreditLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Holds the credit across `body`, releasing it however `body` ends.
    func withCredit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
