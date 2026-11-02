import Foundation
import LoomKit
import MissionKit
import Observation
import SubstrateKit

/// What the main window is showing.
enum Destination: Hashable {
    case inbox
    case mission
    case session(String)
}

/// The app's live view of one daemon and, when present, one Substrate.
///
/// This object is the host: it owns the sockets and timers and turns their
/// results into observable state. Every decision about what those results mean
/// lives in LoomKit and MissionKit, which is what keeps this type testable by
/// proxy and small enough to read in one sitting.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case connecting
        case connected
        case unavailable(String)
    }

    /// The state root. `LOOM_STATE_DIR` selects a test daemon.
    let root: URL = ProcessInfo.processInfo.environment["LOOM_STATE_DIR"]
        .map { URL(fileURLWithPath: $0) } ?? DaemonDiscovery.defaultRoot

    private(set) var connection: Connection = .connecting
    private(set) var hello: DaemonHello?
    private(set) var status: DaemonStatus?
    private(set) var sessions: [SessionRecord] = []
    private(set) var activity: [String: SessionActivity] = [:]
    private(set) var feed: CommandFeed?
    private(set) var attached: [String: SessionController] = [:]

    var destination: Destination? = .mission
    var isDispatching = false

    private var endpoint: DaemonEndpoint?
    private var control: ControlClient?
    private let substrate = SubstrateClient(
        baseURL: URL(string: ProcessInfo.processInfo.environment["SUBSTRATE_URL"] ?? "http://localhost:8080")!
    )
    private var loops: [Task<Void, Never>] = []

    var substrateOnline: Bool { feed != nil }

    var attention: [AttentionItem] {
        Mission.attention(
            sessions: sessions,
            activity: activity,
            escalations: attached.mapValues(\.conversation.escalations),
            feed: feed
        )
    }

    var cards: [AgentCard] {
        Mission.cards(sessions: sessions, activity: activity, feed: feed)
    }

    /// Workspaces already used, for the dispatch sheet.
    var knownWorkspaces: [String] {
        Array(Set(sessions.filter { $0.executor == nil }.map(\.workspace))).sorted()
    }

    func start() {
        guard loops.isEmpty else { return }
        loops.append(Task { await self.daemonLoop() })
        loops.append(Task { await self.substrateLoop() })
    }

    // MARK: Polling

    /// Holds a control connection and polls it. The daemon pushes no activity
    /// on this socket, so a poll is the only way to see it. A failure drops all
    /// state tied to that daemon lifetime and starts over from discovery.
    private func daemonLoop() async {
        while !Task.isCancelled {
            do {
                let endpoint = try DaemonDiscovery.discover(root: root)
                let control = try ControlClient(endpoint: endpoint)
                let hello = try await control.connect()
                adopt(hello: hello, endpoint: endpoint, control: control)
                while !Task.isCancelled {
                    try await refresh(control)
                    try await Task.sleep(for: .seconds(2))
                }
            } catch {
                await control?.close()
                control = nil
                connection = .unavailable(error.localizedDescription)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func adopt(hello: DaemonHello, endpoint: DaemonEndpoint, control: ControlClient) {
        // A new epoch means every ephemeral fact is void (protocol section 6.7).
        if self.hello?.epoch != hello.epoch {
            attached.values.forEach { $0.detach() }
            attached = [:]
        }
        self.hello = hello
        self.endpoint = endpoint
        self.control = control
        connection = .connected
    }

    private func refresh(_ control: ControlClient) async throws {
        let status = try await control.status()
        let sessions = try await control.listSessions()
        let resident = sessions.filter { $0.state.isResident }.map(\.id)
        let activity = try await control.activity(sessions: resident)

        self.status = status
        if self.sessions != sessions {
            self.sessions = sessions.sorted { $0.createdAt > $1.createdAt }
        }
        if self.activity != activity { self.activity = activity }

        // An approval count says only that a record exists, so a session asking
        // for one gets a lane in order to read the record the inbox must show.
        for row in activity.values where row.approvals > 0 && attached[row.sessionID] == nil {
            attach(row.sessionID)
        }
    }

    /// Substrate is optional, so its absence is drawn as absence and retried.
    ///
    /// The listener makes mail appear as it arrives. The slower timer repairs
    /// anything the hub does not announce, such as an agent's liveness expiring,
    /// and keeps the board current if the socket is refused.
    private func substrateLoop() async {
        loops.append(Task { await self.substrateListener() })
        while !Task.isCancelled {
            await reloadFeed()
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func substrateListener() async {
        while !Task.isCancelled {
            do {
                for try await type in substrate.events() where Self.feedEvents.contains(type) {
                    await reloadFeed()
                }
            } catch {
                // The socket dropped or Substrate is not running. Retry below.
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Hub events that change what the feed returns.
    private static let feedEvents: Set<String> = [
        "new_message", "agent_update", "task_update", "summary_updated", "unread_count",
    ]

    private func reloadFeed() async {
        let next = try? await substrate.feed()
        if feed != next { feed = next }
    }

    // MARK: Sessions

    /// Attaches to a resident session. It never opens a saved one, since that
    /// claims one of the daemon's capacity slots and is the person's choice.
    @discardableResult
    func attach(_ sessionID: String) -> SessionController? {
        if let existing = attached[sessionID], existing.isLive { return existing }
        guard let endpoint else { return nil }
        let controller = SessionController(sessionID: sessionID, endpoint: endpoint)
        attached[sessionID] = controller
        controller.connect()
        return controller
    }

    func resume(_ sessionID: String) async throws {
        guard let control else { throw LoomError.closed("The daemon is not connected.") }
        _ = try await control.openUntilResident(sessionID: sessionID)
        try await refresh(control)
        attach(sessionID)
    }

    func stop(_ sessionID: String) async throws {
        guard let control else { return }
        attached[sessionID]?.detach()
        attached[sessionID] = nil
        try await control.stopSession(sessionID: sessionID)
        try await refresh(control)
    }

    /// Creates a session and sends its first prompt, the whole of a dispatch.
    func dispatch(workspace: String, name: String, prompt: String, requestKey: String) async throws {
        guard let control else { throw LoomError.closed("The daemon is not connected.") }

        // The same configuration the terminal falls back to with no --config.
        let configuration = root.appendingPathComponent("loom.toml").path
        let record = try await control.createSession(
            requestKey: requestKey,
            workspace: workspace,
            name: name.isEmpty ? (workspace as NSString).lastPathComponent : name,
            configuration: configuration
        )
        _ = try await control.openUntilResident(sessionID: record.id)
        try await refresh(control)
        guard let controller = attach(record.id) else { return }
        await controller.waitUntilAdopted()
        controller.send(text: prompt)
        destination = .session(record.id)
    }

    // MARK: Substrate actions

    func reply(threadID: String, body: String) async throws {
        let sender = try await substrate.operatorID()
        try await substrate.reply(threadID: threadID, senderID: sender, body: body)
        await reloadFeed()
    }

    func steerSubstrateAgent(named name: String, body: String) async throws {
        let sender = try await substrate.operatorID()
        try await substrate.sendMail(senderID: sender, to: name, subject: "Steer from Loom", body: body)
        await reloadFeed()
    }

    func decide(planReviewID: String, decision: PlanDecision, comment: String) async throws {
        let reviewer = try await substrate.operatorID()
        try await substrate.decide(planReviewID: planReviewID, decision: decision, comment: comment, reviewer: reviewer)
        await reloadFeed()
    }
}

/// One attached session: a lane and the projection of what it reports.
@MainActor
@Observable
final class SessionController {
    let sessionID: String

    private(set) var conversation: Conversation
    private(set) var isLive = true
    private(set) var lastError: String?
    private(set) var isLoadingOlder = false
    var focusedStrand = "main"

    private let endpoint: DaemonEndpoint
    private var lane: SessionLane?
    private var pump: Task<Void, Never>?

    init(sessionID: String, endpoint: DaemonEndpoint) {
        self.sessionID = sessionID
        self.endpoint = endpoint
        conversation = Conversation(sessionID: sessionID)
    }

    var rows: [TranscriptRow] { conversation.rows(strand: focusedStrand) }
    var strand: Strand? { conversation.strands.first { $0.id == focusedStrand } }
    var stream: LiveStream? { conversation.streams[focusedStrand] }
    var isBusy: Bool { strand?.isBusy ?? false }

    func connect() {
        pump = Task { await self.run() }
    }

    func detach() {
        pump?.cancel()
        isLive = false
        let lane = self.lane
        Task { await lane?.close() }
    }

    private func run() async {
        do {
            let lane = try SessionLane(endpoint: endpoint, sessionID: sessionID)
            self.lane = lane
            let starter = Task { try await lane.start() }
            for await event in lane.events {
                switch event {
                case .cut(let cut):
                    conversation.apply(cut: cut)
                case .push(let frame):
                    conversation.apply(push: frame)
                case .closed(let error):
                    isLive = false
                    if let error { lastError = error.localizedDescription }
                }
            }
            starter.cancel()
        } catch {
            isLive = false
            lastError = error.localizedDescription
        }
    }

    func waitUntilAdopted() async {
        while !conversation.hasAdoptedCut && isLive {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Sends input to the focused strand: a prompt when idle, a steer when busy.
    func send(text: String) {
        let strand = focusedStrand
        let busy = isBusy
        perform { lane in
            _ = busy
                ? try await lane.steer(strand: strand, text: text)
                : try await lane.prompt(strand: strand, text: text)
        }
    }

    func abort() {
        let strand = focusedStrand
        perform { lane in _ = try await lane.abort(strand: strand) }
    }

    /// Answers with the record the person is looking at, captured by the view.
    /// A stale answer is refused by sequence, and the next cut redraws it.
    func approve(_ record: Escalation) {
        perform { lane in _ = try await lane.approve(record) }
    }

    func deny(_ record: Escalation) {
        perform { lane in _ = try await lane.deny(record) }
    }

    func requestDiff() {
        perform { lane in try await lane.requestWorktreeDiff() }
    }

    func loadOlder() {
        guard let oldest = conversation.oldestSeq, !isLoadingOlder else { return }
        isLoadingOlder = true
        perform { lane in try await lane.loadOlder(beforeSeq: oldest) }
    }

    private func perform(_ action: @escaping @Sendable (SessionLane) async throws -> Void) {
        guard let lane else { return }
        lastError = nil
        Task {
            defer { isLoadingOlder = false }
            do {
                try await action(lane)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
