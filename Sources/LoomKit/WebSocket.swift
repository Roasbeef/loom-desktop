import Foundation

/// One authenticated text-frame WebSocket to the daemon.
final class WebSocket: Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(url: URL, bearer: String, maximumMessageSize: Int = 4 * 1024 * 1024) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        task.resume()
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw translated(error)
        }
    }

    /// Returns the next text frame. Binary frames are not part of the protocol.
    func receive() async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw translated(error)
        }
        guard case .string(let text) = message else {
            throw LoomError.protocolViolation("the server sent a binary frame")
        }
        return text
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func translated(_ error: Error) -> LoomError {
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            return .upgradeRefused(status: response.statusCode)
        }
        return .closed(error.localizedDescription)
    }
}

/// Races `operation` against a deadline, reporting a lost reply as such.
func withDeadline<T: Sendable>(
    seconds: Double,
    command: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw LoomError.outcomeUnknown(command: command)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw LoomError.closed("no result")
        }
        return first
    }
}
