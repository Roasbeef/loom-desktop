import Foundation
import LoomKit
import MissionKit
import Observation
import Security

/// What the main window is showing.
enum Destination: Hashable {
    case inbox
    case mission
    case machines
    case session(String)
}

/// How a person last chose to group the sidebar.
enum SidebarGrouping: String, CaseIterable, Identifiable {
    case project = "Project"
    case machine = "Machine"
    var id: Self { self }
}

/// A saved way to reach a daemon on another machine.
struct SavedDaemon: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var address: String
}

/// Keeps remote credentials in the login keychain, and never in preferences.
enum CredentialStore {
    private static let service = "com.roasbeef.loom-desktop.daemon"

    static func save(_ token: String, for id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LoomError.discovery("The keychain refused the credential (\(status)).")
        }
    }

    static func load(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(for id: UUID) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ] as CFDictionary)
    }
}

/// One daemon this app is connected to, here or on another machine.
///
/// A session's brain is the daemon that holds it, so a session on another
/// machine can only be driven through a connection to that machine's daemon. Each
/// connection therefore owns its sockets, its catalogue and its attachments, and
/// `AppModel` only merges their views.
@MainActor
@Observable
final class DaemonConnection: Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case unavailable(String)
    }

    enum Source {
        case local(root: URL)
        case remote(SavedDaemon, token: String)
    }

    let id: String
    let source: Source

    private(set) var state: State = .connecting
    private(set) var hello: DaemonHello?
    private(set) var status: DaemonStatus?
    private(set) var deployment: Deployment?
    private(set) var elsewhere: [ElsewhereGroup] = []
    private(set) var sessions: [SessionRecord] = []
    private(set) var activity: [String: SessionActivity] = [:]
    private(set) var attached: [String: SessionController] = [:]

    private var endpoint: DaemonEndpoint?
    private var control: ControlClient?
    private var loop: Task<Void, Never>?
    private var ticks = 0

    /// The deployment read connects to every node, so it runs far less often
    /// than the catalogue poll.
    private static let deploymentEvery = 8

    init(id: String, source: Source) {
        self.id = id
        self.source = source
    }

    /// The name people see: a saved name, or what the daemon calls its machine.
    var label: String {
        switch source {
        case .remote(let saved, _): return saved.name
        case .local: return deployment?.selfName ?? "This machine"
        }
    }

    var isRemote: Bool {
        if case .remote = source { return true }
        return false
    }

    /// The state root, for the configuration a local dispatch uses.
    var localRoot: URL? {
        if case .local(let root) = source { return root }
        return nil
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    func shutDown() {
        loop?.cancel()
        attached.values.forEach { $0.detach() }
        attached = [:]
        let control = self.control
        Task { await control?.close() }
    }

    private func resolveEndpoint() throws -> DaemonEndpoint {
        switch source {
        case .local(let root): return try DaemonDiscovery.discover(root: root)
        case .remote(let saved, let token): return try DaemonEndpoint(address: saved.address, token: token)
        }
    }

    /// Holds a control connection and polls it. The daemon pushes no activity
    /// on this socket, so a poll is the only way to see it. A failure drops all
    /// state tied to that daemon lifetime and starts over from discovery.
    private func run() async {
        while !Task.isCancelled {
            do {
                let endpoint = try resolveEndpoint()
                let control = try ControlClient(endpoint: endpoint)
                let hello = try await control.connect()
                adopt(hello: hello, endpoint: endpoint, control: control)
                ticks = 0
                while !Task.isCancelled {
                    try await refresh(control)
                    try await Task.sleep(for: .seconds(2))
                }
            } catch {
                await control?.close()
                control = nil
                state = .unavailable(error.localizedDescription)
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
        state = .connected
    }

    private func refresh(_ control: ControlClient) async throws {
        let status = try await control.status()
        let sessions = try await control.listSessions()
        let resident = sessions.filter { $0.state.isResident }.map(\.id)
        let activity = try await control.activity(sessions: resident)

        self.status = status
        let sorted = sessions.sorted { $0.createdAt > $1.createdAt }
        if self.sessions != sorted { self.sessions = sorted }
        if self.activity != activity { self.activity = activity }

        // An approval count says only that a record exists, so a session asking
        // for one gets a lane in order to read the record the inbox must show.
        for row in activity.values where row.approvals > 0 && attached[row.sessionID]?.isLive != true {
            attach(row.sessionID)
        }

        if ticks % Self.deploymentEvery == 0 {
            await refreshDeployment(control)
        }
        ticks += 1
    }

    /// Both reads are owner-only and absent from older daemons, so a refusal
    /// hides those views rather than failing the connection.
    private func refreshDeployment(_ control: ControlClient) async {
        if let next = try? await control.deployment(), deployment != next { deployment = next }
        if let next = try? await control.sessionsElsewhere(), elsewhere != next { elsewhere = next }
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
        guard let control else { throw LoomError.closed("\(label) is not connected.") }
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

    /// Reads the workspaces an executor has registered, by name.
    func workspaces(onExecutor name: String) async -> [String] {
        guard let control else { return [] }
        let detail = try? await control.deployment(node: name)
        return detail?.nodes.first?.workspaces ?? []
    }

    /// Creates a session and sends its first prompt, the whole of a dispatch.
    func dispatch(
        workspace: String,
        name: String,
        prompt: String,
        placement: PlacementChoice,
        configuration: String,
        requestKey: String
    ) async throws -> String {
        guard let control else { throw LoomError.closed("\(label) is not connected.") }
        let record = try await control.createSession(
            requestKey: requestKey,
            workspace: workspace,
            name: name.isEmpty ? (workspace as NSString).lastPathComponent : name,
            configuration: configuration,
            placement: placement
        )
        _ = try await control.openUntilResident(sessionID: record.id)
        try await refresh(control)
        guard let controller = attach(record.id) else { return record.id }
        await controller.waitUntilAdopted()
        controller.send(text: prompt)
        return record.id
    }
}

/// The app's merged view of every daemon.
///
/// Every decision about what those results mean lives in LoomKit and MissionKit,
/// which is what keeps this type small enough to read in one sitting.
@MainActor
@Observable
final class AppModel {
    private(set) var daemons: [DaemonConnection] = []

    var destination: Destination? = .mission
    var isDispatching = false
    var isAddingDaemon = false

    /// A name to prefill, when a person follows a session held elsewhere.
    var daemonSuggestion: (name: String, address: String)?

    private var hasStarted = false
    private static let savedKey = "savedDaemons"

    /// Every session on every connected daemon.
    var sessions: [SessionRecord] {
        daemons.flatMap(\.sessions)
    }

    var activity: [String: SessionActivity] {
        daemons.reduce(into: [:]) { $0.merge($1.activity) { _, new in new } }
    }

    private var attached: [String: SessionController] {
        daemons.reduce(into: [:]) { $0.merge($1.attached) { _, new in new } }
    }

    /// Whether placement is worth any screen space. A person on one machine with
    /// no executors never sees brain and hands vocabulary.
    var isMultiMachine: Bool {
        daemons.count > 1 || daemons.contains { $0.deployment?.isDistributed == true }
    }

    var attention: [AttentionItem] {
        Mission.attention(
            sessions: sessions,
            activity: activity,
            // A dead lane's records may be stale and cannot be answered, so the
            // inbox shows the count until a fresh lane reads them.
            escalations: attached.filter(\.value.isLive).mapValues(\.conversation.escalations),
            unhealthy: daemons.flatMap { daemon in
                Mission.blastRadius(nodes: daemon.deployment?.nodes ?? [], sessions: daemon.sessions)
            }
        )
    }

    var cards: [AgentCard] {
        Mission.cards(sessions: sessions, activity: activity) { [self] in placement(of: $0) }
    }

    /// Sessions the connected daemons say other orchestrators hold, minus any
    /// held by a daemon this app is already connected to.
    var elsewhere: [ElsewhereGroup] {
        let known = Set(daemons.flatMap(\.sessions).map(\.id))
        return daemons.flatMap(\.elsewhere).filter { group in
            !group.sessions.allSatisfy { known.contains($0.id) } || group.sessions.isEmpty
        }
    }

    func daemon(holding sessionID: String) -> DaemonConnection? {
        daemons.first { daemon in daemon.sessions.contains { $0.id == sessionID } }
    }

    func controller(for sessionID: String) -> SessionController? {
        daemon(holding: sessionID)?.attached[sessionID]
    }

    func placement(of record: SessionRecord) -> Placement? {
        guard isMultiMachine, let daemon = daemon(holding: record.id) else { return nil }
        return Placement(record: record, brain: daemon.label)
    }

    /// Workspaces already used on this daemon, for the dispatch sheet.
    func knownWorkspaces(on daemon: DaemonConnection) -> [String] {
        Array(Set(daemon.sessions.filter { $0.executor == nil && $0.pool == nil }.map(\.workspace))).sorted()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let root = ProcessInfo.processInfo.environment["LOOM_STATE_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? DaemonDiscovery.defaultRoot
        daemons = [DaemonConnection(id: "local", source: .local(root: root))]
        for saved in Self.loadSaved() {
            if let token = CredentialStore.load(for: saved.id) {
                daemons.append(DaemonConnection(id: saved.id.uuidString, source: .remote(saved, token: token)))
            }
        }
        daemons.forEach { $0.start() }
    }

    // MARK: Other machines

    private static func loadSaved() -> [SavedDaemon] {
        guard let data = UserDefaults.standard.data(forKey: savedKey) else { return [] }
        return (try? JSONDecoder().decode([SavedDaemon].self, from: data)) ?? []
    }

    /// Saves and connects a daemon. The credential goes to the keychain, and the
    /// address is checked now so a cleartext route is refused before it is kept.
    func addDaemon(name: String, address: String, token: String) throws {
        let endpoint = try DaemonEndpoint(address: address, token: token)
        guard endpoint.scheme == "wss" || endpoint.isLoopback else {
            throw LoomError.discovery("Use wss:// or an SSH tunnel to a loopback port. A bearer must not cross the network in cleartext.")
        }
        let saved = SavedDaemon(id: UUID(), name: name, address: address)
        try CredentialStore.save(token, for: saved.id)
        var all = Self.loadSaved()
        all.append(saved)
        UserDefaults.standard.set(try JSONEncoder().encode(all), forKey: Self.savedKey)

        let connection = DaemonConnection(id: saved.id.uuidString, source: .remote(saved, token: token))
        daemons.append(connection)
        connection.start()
    }

    func removeDaemon(_ connection: DaemonConnection) {
        guard case .remote(let saved, _) = connection.source else { return }
        connection.shutDown()
        daemons.removeAll { $0.id == connection.id }
        CredentialStore.delete(for: saved.id)
        let remaining = Self.loadSaved().filter { $0.id != saved.id }
        if let data = try? JSONEncoder().encode(remaining) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        }
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
    private var olderCursor: Int?
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
        guard let before = olderCursor ?? conversation.oldestSeq, !isLoadingOlder, let lane else { return }
        isLoadingOlder = true
        Task {
            defer { isLoadingOlder = false }
            do {
                olderCursor = try await lane.loadOlder(beforeSeq: before)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Reads a page of a subagent running on another orchestrator.
    func peek(child: RemoteChild) {
        conversation.beginPeek(child: child.id)
        let id = child.id
        perform { lane in try await lane.requestChildHistory(child: id) }
    }

    func endPeek() {
        conversation.endPeek()
    }

    private func perform(_ action: @escaping @Sendable (SessionLane) async throws -> Void) {
        guard let lane else { return }
        lastError = nil
        Task {
            do {
                try await action(lane)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
