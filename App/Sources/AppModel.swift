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
    case status = "Status"
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

    /// When this client last saw each session's activity change. The daemon reports
    /// no such time, so this is an observation, absent until a change is seen.
    private(set) var lastChanged: [String: Date] = [:]

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
        if self.activity != activity {
            for (id, row) in activity where self.activity[id] != nil && self.activity[id] != row {
                lastChanged[id] = Date()
            }
            self.activity = activity
        }

        // An approval count says only that a record exists, so a session asking
        // for one gets a lane in order to read the record the inbox must show.
        for row in activity.values where row.approvals > 0 && attached[row.sessionID]?.isLive != true {
            attach(row.sessionID)
        }

        // A socket can drop while its session lives on, so a session someone
        // attached to is reattached. Nothing unsent is carried across, as the
        // protocol requires (section 6.7).
        for (id, controller) in attached where !controller.isLive && resident.contains(id) {
            attach(id)?.focusedStrand = controller.focusedStrand
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
    var isPaletteOpen = false
    var showsInspector = false

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

    /// Whether the app has nothing to show until a daemon runs.
    var isDaemonMissing: Bool {
        guard daemons.count == 1, case .unavailable? = daemons.first?.state else { return false }
        return daemons.first?.hello == nil
    }

    /// Moves to the next thing waiting, the one-key route through a busy fleet.
    func goToNextNeedingYou() {
        let targets = attention.compactMap { item -> String? in
            if case .session(let id, _) = item.source { return id }
            return nil
        }
        guard !targets.isEmpty else { return }
        if case .session(let current) = destination, let index = targets.firstIndex(of: current) {
            destination = .session(targets[(index + 1) % targets.count])
        } else {
            destination = .session(targets[0])
        }
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
            escalations: attached.filter(\.value.isLive).mapValues(\.escalations),
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

    /// The last reply a person saw in each session, kept across launches. A session
    /// whose latest reply differs finished something while they were away.
    private(set) var seenReplies: [String: String] = UserDefaults.standard.dictionary(forKey: "seenReplies") as? [String: String] ?? [:]

    func hasUnseenReply(_ sessionID: String) -> Bool {
        guard let reply = activity[sessionID]?.lastMessage else { return false }
        if case .session(sessionID) = destination { return false }
        guard let seen = seenReplies[sessionID] else { return false }
        return seen != reply
    }

    /// Takes the first reply seen from each session as already read. A session that
    /// has never been looked at is not news, or every row would shout on first launch.
    func recordFirstReplies() {
        var changed = false
        for (id, row) in activity where seenReplies[id] == nil {
            if let reply = row.lastMessage {
                seenReplies[id] = reply
                changed = true
            }
        }
        if changed { UserDefaults.standard.set(seenReplies, forKey: "seenReplies") }
    }

    /// Records what the open session shows, called as its activity changes.
    func markSeen(_ sessionID: String) {
        guard let reply = activity[sessionID]?.lastMessage, seenReplies[sessionID] != reply else { return }
        seenReplies[sessionID] = reply
        UserDefaults.standard.set(seenReplies, forKey: "seenReplies")
    }

    /// The session the main window shows, which the Session menu acts on.
    var currentSession: SessionController? {
        if case .session(let id) = destination { return controller(for: id) }
        return nil
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

    /// Starts the installed daemon by asking the `loom` client to reach it, which
    /// runs the launch procedure with its locks and identity checks. Reimplementing
    /// that here could leave two daemons racing for one state root.
    func startDaemon() async throws {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/loom").path,
            "/opt/homebrew/bin/loom",
            "/usr/local/bin/loom",
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw LoomError.discovery("Could not find the loom command. Install Loom, then try again.")
        }
        var arguments = ["sessions", "list"]
        if let root = daemons.first?.localRoot, root != DaemonDiscovery.defaultRoot {
            arguments = ["--state-dir", root.path] + arguments
        }
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw LoomError.discovery("loom could not start the daemon (exit \(process.terminationStatus)).")
            }
        }.value
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
///
/// The value `Conversation` stays out of observation. Each fact a view draws is
/// its own observed property, set only when it actually changes, so a streamed
/// token invalidates the stream view and leaves a 5,000-row transcript alone. The
/// idle refresh's identical cut costs one comparison and redraws nothing.
@MainActor
@Observable
final class SessionController {
    let sessionID: String

    private(set) var blocks: [TranscriptBlock] = []
    private(set) var stream: LiveStream?
    private(set) var strands: [Strand] = []
    private(set) var escalations: [Escalation] = []
    private(set) var remoteChildren: [RemoteChild] = []
    private(set) var peek: ChildPeek?
    private(set) var peers: [Peer] = []
    private(set) var surfaces: [String: JSONValue] = [:]
    private(set) var pendingInputs: [PendingInput] = []
    private(set) var worktree: JSONValue?
    private(set) var branch: String?
    private(set) var usage: JSONValue = .null
    private(set) var hasOlder = false
    private(set) var isAdopted = false
    private(set) var toolTails: [String: String] = [:]
    private(set) var isLive = true
    private(set) var lastError: String?
    private(set) var isLoadingOlder = false
    private(set) var busySince: Date?
    var isSearching = false

    // What the panels draw, each set only when it changes so the transcript is
    // not invalidated by a figure moving.
    private(set) var context: ContextBoard?
    private(set) var contextNotice: String?
    private(set) var strandLines: [StrandLine] = []
    private(set) var todo: TodoBoard?
    private(set) var signals: [String: Int] = [:]
    private(set) var remoteUsage: [RemoteUsage] = []
    private(set) var role = ""
    private(set) var trace = TraceBoard(programs: [], omitted: 0)
    /// Why the connection ended, in words, once a lane has closed.
    private(set) var ended: EndingWords?
    /// Whether the side question panel is open above the composer.
    var showsSideQuestion = false
    /// Why a background read was refused, by command, for a panel to say.
    private(set) var readFailures: [String: String] = [:]

    var focusedStrand = "main" {
        didSet {
            if focusedStrand != oldValue { syncAll(force: true) }
        }
    }

    @ObservationIgnored private var conversation: Conversation
    @ObservationIgnored private var projectedRevision = -1
    @ObservationIgnored private var olderCursor: Int?
    @ObservationIgnored private var streamFlush: Task<Void, Never>?
    @ObservationIgnored private let endpoint: DaemonEndpoint
    @ObservationIgnored private var lane: SessionLane?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var notesAsked: Set<String> = []

    init(sessionID: String, endpoint: DaemonEndpoint) {
        self.sessionID = sessionID
        self.endpoint = endpoint
        conversation = Conversation(sessionID: sessionID)
    }

    var strand: Strand? { strands.first { $0.id == focusedStrand } }
    var isBusy: Bool { strand?.isBusy ?? false }
    var totalCost: Double? { usage["cost"]?["total"]?.double }
    var totalTokens: Int? { usage["totalTokens"]?.int }

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
                    if conversation.apply(cut: cut) { syncAll() }
                case .push(let frame):
                    conversation.apply(push: frame)
                    if frame.event == "stream_delta" {
                        scheduleStreamFlush()
                    } else {
                        syncPushed()
                    }
                case .closed(let error):
                    isLive = false
                    ended = EndingWords.notice(for: error)
                    if let error { lastError = error.localizedDescription }
                }
            }
            starter.cancel()
        } catch {
            isLive = false
            lastError = error.localizedDescription
        }
    }

    /// Coalesces tokens to the display's pace. A provider can deliver hundreds a
    /// second, and laying out text for each one would drop frames for no gain.
    private func scheduleStreamFlush() {
        guard streamFlush == nil else { return }
        // Layout grows with the reply, so a very long reply updates less often
        // rather than dropping frames. Nobody reads at thirty updates a second.
        let length = conversation.streams[focusedStrand]?.text.utf8.count ?? 0
        let pace = length > 16_000 ? 100 : length > 4_000 ? 60 : 33
        streamFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(pace))
            guard let self else { return }
            self.streamFlush = nil
            self.setStream()
        }
    }

    private func setStream() {
        let next = conversation.streams[focusedStrand]
        if stream != next { stream = next }
    }

    private func syncPushed() {
        assign(\.peers, conversation.peers)
        assign(\.surfaces, conversation.surfaces)
        assign(\.toolTails, conversation.toolTails)
        assign(\.worktree, conversation.worktree)
        assign(\.remoteChildren, conversation.remoteChildren)
        assign(\.peek, conversation.peek)
        assign(\.context, conversation.context)
        assign(\.contextNotice, conversation.contextNotice)
        assign(\.signals, conversation.signals)
        assign(\.remoteUsage, conversation.remoteUsage)
        assign(\.role, conversation.role)
        if todo == nil, let seeded = notesTodo() { todo = seeded }
        setStream()
    }

    private func syncAll(force: Bool = false) {
        if force || projectedRevision != conversation.revision {
            projectedRevision = conversation.revision
            assign(\.blocks, TranscriptBlock.group(conversation.rows(strand: focusedStrand)))
            assign(\.hasOlder, conversation.hasOlder(strand: focusedStrand))
            assign(\.strandLines, conversation.strandLines())
            assign(\.trace, conversation.traceBoard(strand: focusedStrand))
            assign(\.todo, conversation.todoBoard(strand: focusedStrand) ?? notesTodo())
            askForNotesIfNoBoard()
        }
        assign(\.strands, conversation.strands)
        assign(\.escalations, conversation.escalations)
        assign(\.pendingInputs, conversation.pendingInputs)
        assign(\.branch, conversation.branch)
        assign(\.usage, conversation.usage)
        assign(\.isAdopted, conversation.hasAdoptedCut)
        syncPushed()

        // The elapsed time is this client's own observation of the run.
        if isBusy {
            if busySince == nil { busySince = Date() }
        } else if busySince != nil {
            busySince = nil
        }
    }

    private func assign<T: Equatable>(_ path: ReferenceWritableKeyPath<SessionController, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    func waitUntilAdopted() async {
        while !isAdopted && isLive {
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
    func approve(_ record: Escalation, remember: Bool = false) {
        guard isCurrent(record) else { return }
        perform { lane in _ = try await lane.approve(record, remember: remember) }
    }

    func deny(_ record: Escalation) {
        guard isCurrent(record) else { return }
        perform { lane in _ = try await lane.deny(record) }
    }

    /// Whether the record a person answered is the one the session holds now. A
    /// record that changed under them is refused here with words, instead of
    /// being sent for the daemon to refuse by sequence.
    private func isCurrent(_ record: Escalation) -> Bool {
        if escalations.contains(record) { return true }
        lastError = Escalation.staleWords
        return false
    }

    /// Asks for a fresh board. A refusal because a read is already running is not
    /// worth saying: that read's answer is on its way.
    /// Runs any session command. A snapshot reply lands in `surfaces` by its mode,
    /// and a refusal lands in `lastError`.
    func run(_ command: String, body: JSONValue = .object([:])) {
        guard let lane else { return }
        lastError = nil
        Task {
            do {
                let reply = try await lane.request(command, body: body)
                if reply.event == "snapshot" {
                    conversation.apply(push: reply)
                    syncPushed()
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Reads a surface without disturbing `lastError`, for a panel that polls. A
    /// refusal is kept per command in `readFailures`, so the panel can say why it
    /// has nothing to show, and a later success clears it.
    func read(_ command: String, body: JSONValue = .object([:])) {
        guard let lane else { return }
        Task {
            do {
                let reply = try await lane.request(command, body: body)
                if reply.event == "snapshot" {
                    conversation.apply(push: reply)
                    syncPushed()
                }
                if readFailures[command] != nil { readFailures[command] = nil }
            } catch {
                readFailures[command] = error.localizedDescription
            }
        }
    }

    /// A strand whose chain holds no `todo` result may still have a board in its
    /// notes, which is how a client attaching after the last call recovers it.
    private func askForNotesIfNoBoard() {
        guard todo == nil, notesAsked.insert(focusedStrand).inserted else { return }
        read("notes", body: ["strand": .string(focusedStrand)])
    }

    private func notesTodo() -> TodoBoard? {
        guard let notes = NotesBoard(surfaces["notes"]?["board"]), notes.strand == focusedStrand else { return nil }
        return notes.todo
    }

    func requestDiff() {
        guard let lane else { return }
        Task {
            do {
                try await lane.requestWorktreeDiff()
            } catch LoomError.server(code: "busy", _, _) {
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
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
        syncPushed()
        let id = child.id
        perform { lane in try await lane.requestChildHistory(child: id) }
    }

    func endPeek() {
        conversation.endPeek()
        syncPushed()
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
