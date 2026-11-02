import Foundation

/// The `GET /api/v1/command/feed` payload: one round trip for the whole fleet.
public struct CommandFeed: Sendable, Decodable, Equatable {
    public let lanes: [Lane]
    public let attention: [Attention]

    public struct Lane: Sendable, Decodable, Equatable, Identifiable {
        public let agent: Agent
        public let events: [Event]?
        public let unreadCount: Int
        public let needsActionCount: Int
        public let waitingFor: String?
        public var id: Int64 { agent.id }

        enum CodingKeys: String, CodingKey {
            case agent, events
            case unreadCount = "unread_count"
            case needsActionCount = "needs_action_count"
            case waitingFor = "waiting_for"
        }
    }

    public struct Agent: Sendable, Decodable, Equatable {
        public let id: Int64
        public let name: String
        public let projectKey: String?
        public let gitBranch: String?
        public let purpose: String?
        public let status: String
        public let secondsIdle: Int?

        enum CodingKeys: String, CodingKey {
            case id, name, purpose, status
            case projectKey = "project_key"
            case gitBranch = "git_branch"
            case secondsIdle = "seconds_since_heartbeat"
        }
    }

    public struct Event: Sendable, Decodable, Equatable, Identifiable {
        public let messageID: Int64
        public let threadID: String?
        public let kind: String
        public let subject: String
        public let body: String?
        public let needsAction: Bool
        public let planReviewID: String?
        public var id: Int64 { messageID }

        enum CodingKeys: String, CodingKey {
            case kind, subject, body
            case messageID = "message_id"
            case threadID = "thread_id"
            case needsAction = "needs_action"
            case planReviewID = "plan_review_id"
        }
    }

    public struct Attention: Sendable, Decodable, Equatable {
        public let kind: String
        public let agentID: Int64
        public let agentName: String
        public let title: String
        public let detail: String?
        public let threadID: String?
        public let messageID: Int64?
        public let planReviewID: String?
        public let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case kind, title, detail
            case agentID = "agent_id"
            case agentName = "agent_name"
            case threadID = "thread_id"
            case messageID = "message_id"
            case planReviewID = "plan_review_id"
            case createdAt = "created_at"
        }
    }

    enum CodingKeys: String, CodingKey { case lanes, attention }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // The Go server encodes an empty slice as null.
        lanes = try container.decodeIfPresent([Lane].self, forKey: .lanes) ?? []
        attention = try container.decodeIfPresent([Attention].self, forKey: .attention) ?? []
    }
}

/// A plan review decision, in the state vocabulary the server stores.
public enum PlanDecision: String, Sendable {
    case approved
    case changesRequested = "changes_requested"
    case rejected
}

/// A client of a local `substrated` web gateway.
///
/// Substrate is optional. A refused connection means it is not running, which
/// the caller draws as absence rather than as a failure of the whole app.
public struct SubstrateClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://localhost:8080")!) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral

        // A request bound would also end a quiet WebSocket, so the listener's
        // idle socket gets the resource bound only.
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration)
    }

    public func feed() async throws -> CommandFeed {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/command/feed"))
        request.timeoutInterval = 4
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return try JSONDecoder().decode(CommandFeed.self, from: data)
    }

    /// Resolves the operator's own agent, which authors every reply. The feed
    /// leaves that agent out of its lanes, so it must be read from the roster.
    public func operatorID(named name: String = "User") async throws -> Int64 {
        let (data, response) = try await session.data(from: baseURL.appending(path: "api/v1/agents"))
        try Self.check(response)
        struct Roster: Decodable {
            struct Row: Decodable {
                let id: String
                let name: String
            }
            let agents: [Row]?
        }
        let roster = try JSONDecoder().decode(Roster.self, from: data)
        guard let row = roster.agents?.first(where: { $0.name == name }), let id = Int64(row.id) else {
            throw URLError(.userAuthenticationRequired)
        }
        return id
    }

    /// Listens to the server's `/ws` hub and yields each event's type until the
    /// socket closes.
    ///
    /// A frame is only a signal to read the feed again, not state to merge, so
    /// the feed stays the one source of what the board shows. The global bucket,
    /// `agent_id=0`, receives the operator's mail notifications.
    public func events() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            var components = URLComponents(url: baseURL.appending(path: "ws"), resolvingAgainstBaseURL: false)
            components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
            components?.queryItems = [URLQueryItem(name: "agent_id", value: "0")]
            guard let url = components?.url else {
                continuation.finish(throwing: URLError(.badURL))
                return
            }
            let task = session.webSocketTask(with: url)
            task.resume()
            let reader = Task {
                do {
                    while !Task.isCancelled {
                        guard case .string(let text) = try await task.receive() else { continue }
                        let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                        if let type = frame?["type"] as? String { continuation.yield(type) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    /// Answers a thread as `senderID`, normally the operator's `User` agent.
    public func reply(threadID: String, senderID: Int64, body: String) async throws {
        try await send("POST", path: "api/v1/threads/\(threadID)/reply", json: [
            "sender_id": senderID,
            "thread_id": threadID,
            "body": body,
        ])
    }

    /// Sends a direct message, the way a steer reaches a Substrate agent.
    public func sendMail(senderID: Int64, to recipient: String, subject: String, body: String) async throws {
        try await send("POST", path: "api/v1/messages", json: [
            "sender_id": senderID,
            "recipient_names": [recipient],
            "subject": subject,
            "body": body,
        ])
    }

    public func decide(planReviewID: String, decision: PlanDecision, comment: String, reviewer: Int64) async throws {
        try await send("PATCH", path: "api/v1/plan-reviews/\(planReviewID)", json: [
            "plan_review_id": planReviewID,
            "state": decision.rawValue,
            "reviewer_comment": comment,
            "reviewed_by": reviewer,
        ])
    }

    private func send(_ method: String, path: String, json: [String: Any]) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
