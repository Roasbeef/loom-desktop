import CryptoKit
import Foundation
import LoomCore
import LoomKit
import LoomShell
import SwiftUI
import MissionKit
import Observation
import Security

/// What the main window is showing.
enum Destination: Hashable {
    case inbox
    case mission
    case machines
    /// Project mode: each project with its tickets, router and workers.
    case projects
    case session(String)
}

/// What the last act on a ticket came to, in words.
struct TicketResult: Equatable {
    let words: String
    let isRefusal: Bool
}

/// A session that was created, whose first message never went out. The session is
/// kept, so the person can open it and write the message there.
struct CreatedButUnsent: LocalizedError {
    let sessionID: String
    let reason: String

    var errorDescription: String? { Refusal.unopened(reason: reason) }
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

/// Why a message from the inbox pane was not sent, in the app's own words.
struct SendFailure: LocalizedError {
    let words: String
    var errorDescription: String? { words }
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

    /// The feed rows the daemon last read, by session: asks, finds and stuck
    /// strands. A resident session with no entry was not read, which the inbox
    /// says as "not checked" and never as "nothing waits".
    private(set) var attentionRows: [String: AttentionRow] = [:]

    /// The projects this daemon holds, each with the last page zero of its board.
    /// A project whose board did not read keeps the page it had, or none.
    private(set) var projects: [ProjectState] = []

    /// Whether a project table answered. A daemon that started none, or predates
    /// the commands, refuses them, and the app then draws no Projects and does not
    /// ask again until the epoch changes.
    private(set) var projectsAnswered = false

    /// The epoch of the daemon that said it holds no project table or does not know
    /// `projects.list`.
    private var projectsRefusedAtEpoch: String?

    /// What the catalogue's counts said of the saved sessions at the last read. It is
    /// `unchecked` until a read answers and again once the daemon refuses the command
    /// as unknown, and then the inbox says saved sessions are not checked.
    private(set) var savedReading: SavedReading = .unchecked

    /// The epoch of the daemon that refused `attention.answer` as an unknown command.
    /// The ask's form is not offered while it is the current epoch: an older daemon
    /// cannot take an answer, and a restart (a new epoch) gets another try.
    private(set) var answerRefusedAtEpoch: String?

    /// The epoch of the daemon that refused `sessions.saved_attention` as an unknown
    /// command. The read is not asked again while it is the current epoch, and a
    /// restart (a new epoch) gets another try.
    private var savedRefusedAtEpoch: String?

    /// When each session's oldest pending approval was raised, from `approval.read`.
    /// A session with no entry has no age, since an approval is never aged from a
    /// record that carries no raise time.
    private(set) var approvalRaised: [String: Int] = [:]

    /// What the worktree scan knows of each idle session, which decides who is under
    /// "To review". It is read one session at a time, off the poll, since a read may
    /// take the daemon several seconds.
    private(set) var reviewScan = ReviewScan()

    /// When this client last saw each session's activity change. The daemon reports
    /// no such time, so this is an observation, absent until a change is seen.
    private(set) var lastChanged: [String: Date] = [:]

    /// The choices of the last accepted creation, which a test reads to see what
    /// the new-session form actually sent.
    private(set) var lastCreation = ""

    /// Where the daemon is, once the host has opened it. A test sets it to attach a lane without a host.
    var endpoint: DaemonEndpoint?
    @ObservationIgnored var control: ControlClient?
    /// The hosted connection: it owns the socket, the poll saga and the reconnect, as decided by
    /// `LoomCore.Daemon`. The app acts on what it publishes.
    @ObservationIgnored private var host: DaemonHost?
    private var laneGeneration = 0
    private var running: Set<Daemon.Periodic> = []
    private var listener: Task<Void, Never>?

    /// The deployment read connects to every node, so it runs far less often
    /// than the catalogue poll.
    private static let deploymentEvery = Daemon.deploymentEvery

    /// The attention feed is a fresh observation on every call, and the daemon
    /// neither caches nor pushes it, so it is read about every 30 seconds beside
    /// the 2 second catalogue poll.
    private static let attentionEvery = Daemon.attentionEvery

    /// Projects are read about every eight seconds: the list and each board's page
    /// zero are fresh observations, and the daemon pushes no change.
    private static let projectsEvery = Daemon.projectsEvery

    /// The worktree scan starts at most one read about every six seconds, which
    /// keeps within the daemon's two reads in four seconds for a credential.
    private static let reviewEvery = Daemon.reviewEvery

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

    /// Where an invitee redeems a claim: this daemon's address and the claim path.
    /// It names no token, so it can be shown beside one.
    var claimAddress: String? {
        (try? endpoint?.url(path: "/v2/claim"))?.absoluteString
    }

    func start() {
        guard host == nil else { return }
        let source = self.source
        let host = DaemonHost(open: {
            let endpoint: DaemonEndpoint
            switch source {
            case .local(let root): endpoint = try DaemonDiscovery.discover(root: root)
            case .remote(let saved, let token): endpoint = try DaemonEndpoint(address: saved.address, token: token)
            }
            return (endpoint, WebSocket(url: try endpoint.url(path: "/v2/control"), bearer: endpoint.token))
        })
        self.host = host
        listener = Task { [weak self] in
            for await output in host.outputs {
                guard let self else { return }
                self.handle(output)
            }
        }
        Task { await host.start() }
    }

    func shutDown() {
        listener?.cancel()
        attached.values.forEach { $0.detach() }
        attached = [:]
        let host = self.host
        self.host = nil
        Task { await host?.stop() }
    }

    /// Carries out what the core decided about this connection.
    private func handle(_ output: DaemonHost.Output) {
        switch output {
        case .opened(let endpoint):
            self.endpoint = endpoint
        case .state(let next):
            switch next {
            case .connecting:
                state = .connecting
            case .connected:
                // Every command goes through the one host, so the client is a view of it.
                if control == nil, let host { control = ControlClient(exchange: host) }
                state = .connected
            case .unavailable(let words):
                control = nil
                state = .unavailable(words)
            }
        case .catalogue(let snapshot):
            apply(snapshot)
        case .attach(let id, let inheriting):
            let previous = attached[id]
            let next = attach(id)

            // A lane that is still live is not replaced, so there is nothing to inherit from itself.
            if inheriting == .previous, let previous, next !== previous { next?.inherit(from: previous) }
        case .detachAll:
            // A new epoch means every ephemeral fact is void (protocol section 6.7).
            attached.values.forEach { $0.detach() }
            attached = [:]
        case .due(let periodic):
            guard let control else { return }

            // A read slower than its cadence (a board read queued behind a review) is not started
            // again beside itself, or the older one could write last.
            guard running.insert(periodic).inserted else { return }
            let resident = sessions.filter { $0.state.isResident }.map(\.id)
            switch periodic {
            case .deployment: Task { await refreshDeployment(control); running.remove(.deployment) }
            case .attention: Task { await refreshAttention(control, resident: resident, activity: activity); running.remove(.attention) }
            case .review:
                scanReview(control, activity: activity)
                running.remove(.review)
            case .projects: Task { await refreshProjects(control); running.remove(.projects) }
            }
        }
    }

    /// Takes one poll's catalogue, as the old `refresh` did after its reads.
    private func apply(_ snapshot: DaemonHost.Snapshot) {
        if let body = snapshot.hello, hello == nil || hello?.epoch != body["epoch"]?.string {
            hello = DaemonHello(
                epoch: body["epoch"]?.string ?? "", principal: body["principal"]?.string ?? "",
                buildVersion: body["build_version"]?.string ?? "", buildCommit: body["build_commit"]?.string ?? ""
            )
        }
        if let body = snapshot.status { status = DaemonStatus(body) }
        let sorted = snapshot.sessions
        if self.sessions != sorted { self.sessions = sorted }
        if self.activity != snapshot.activity {
            for (id, row) in snapshot.activity where self.activity[id] != nil && self.activity[id] != row {
                lastChanged[id] = Date()
            }
            self.activity = snapshot.activity
        }
    }

    /// Reads the catalogue now and returns when that read has landed. The argument is the client
    /// the caller holds, which the host's own poll makes unnecessary; it stays so a caller keeps
    /// asking in the same words.
    func refresh(_ control: ControlClient) async throws {
        try await host?.refreshNow()
    }

    /// Starts the read of the next idle session whose worktree is due, when none is
    /// out. The read runs apart from the poll and records its answer on return.
    private func scanReview(_ control: ControlClient, activity: [String: SessionActivity]) {
        let candidates = ReviewScan.candidates(threads: inboxThreads(activity: activity))
        let now = Int(Date().timeIntervalSince1970 * 1000)
        guard let next = reviewScan.due(candidates, now: now) else { return }
        reviewScan.started(next.session, message: next.message, now: now)
        Task {
            let result: Result<ReviewRead, ReviewScan.Failure>
            do {
                result = .success(try await control.review(sessionID: next.session))
            } catch LoomError.server(let code, let message, _) {
                result = .failure(ReviewScan.Failure(code: code, message: message))
            } catch {
                result = .failure(.failed)
            }
            reviewScan.answered(next.session, message: next.message, read: result)
        }
    }

    /// This daemon's resident sessions as the inbox reads them.
    func inboxThreads(activity: [String: SessionActivity]) -> [InboxThread] {
        sessions.filter { $0.state.isResident }.compactMap { record in
            guard ProjectRule.listsThread(standing: record.standing, activity: activity[record.id], feed: attentionRows[record.id]) else { return nil }
            let name = record.standing.map { ProjectRule.threadName(standing: $0, projects: projects) } ?? record.title
            return InboxThread(id: record.id, name: name, activity: activity[record.id])
        }
    }

    /// Reads the projects now, for a pane that has just acted on a ticket.
    func readProjectsNow() async {
        guard let control else { return }
        await refreshProjects(control)
    }

    /// Reads the project list and each project's board. A daemon with no project
    /// table, or one that predates the commands, is not asked again in this epoch.
    /// Any other refusal leaves what was read in place, since it says nothing new
    /// about the tickets.
    private func refreshProjects(_ control: ControlClient) async {
        if projectsRefusedAtEpoch != nil, projectsRefusedAtEpoch == hello?.epoch { return }
        let listed: [ProjectSummary]
        do {
            listed = try await control.projects()
        } catch let error as LoomError {
            if error.isUnknownCommand || error.isNotFound {
                projectsRefusedAtEpoch = hello?.epoch
                if !projects.isEmpty { projects = [] }
                projectsAnswered = false
            }
            return
        } catch {
            return
        }
        projectsAnswered = true
        var next: [ProjectState] = []
        for summary in listed {
            let page = (try? await control.projectBoard(summary.id)) ?? projects.first { $0.id == summary.id }?.page
            next.append(ProjectState(summary: summary, page: page))
        }
        if projects != next { projects = next }
    }

    /// Reads the attention feed now, for a pane that has just settled a find.
    func readAttentionNow() async {
        guard let control else { return }
        let resident = sessions.filter { $0.state.isResident }.map(\.id)
        await refreshAttention(control, resident: resident, activity: activity)
    }

    /// Both reads are owner-only and absent from older daemons, so a refusal
    /// hides those views rather than failing the connection.
    private func refreshDeployment(_ control: ControlClient) async {
        if let next = try? await control.deployment(), deployment != next { deployment = next }
        if let next = try? await control.sessionsElsewhere(), elsewhere != next { elsewhere = next }
    }

    /// Whether this daemon has refused to take an answer to an ask, so the app says
    /// asks are answered on the session's page, as it did before the command existed.
    var cannotTakeAnswers: Bool {
        answerRefusedAtEpoch != nil && answerRefusedAtEpoch == hello?.epoch
    }

    /// Records that `attention.answer` is unknown to this daemon.
    func noteAnswersUnsupported() {
        answerRefusedAtEpoch = hello?.epoch
    }

    /// The saved sessions this daemon lists, which the catalogue's counts are read for.
    var savedSessionIDs: [String] {
        // A saved router or worker is counted nowhere, as a resident one is not.
        sessions.filter { $0.state == .saved && $0.standing == nil }.map(\.id)
    }

    /// Reads the attention feed for the resident sessions and the raise time of each
    /// pending approval. Both are reads that an older daemon refuses, and a refusal
    /// leaves the last answer in place rather than failing the connection.
    private func refreshAttention(_ control: ControlClient, resident: [String], activity: [String: SessionActivity]) async {
        if let rows = try? await control.attention(sessions: resident) {
            // Only sessions still resident keep a row, so a stopped session's old
            // asks do not linger. A resident session this read left out keeps its
            // last row, so its notices are not removed and posted again.
            let kept = InboxRule.keptFeed(previous: attentionRows, read: rows, resident: resident)
            if attentionRows != kept { attentionRows = kept }
        }
        await refreshSaved(control)
        var read: [String: Int] = [:]
        for row in activity.values where row.approvals > 0 {
            if let evidence = try? await control.approvalEvidence(sessionID: row.sessionID), let oldest = evidence.oldestRaised {
                read[row.sessionID] = oldest
            }
        }
        let raised = InboxRule.raisedTimes(
            previous: approvalRaised, read: read, approving: Set(activity.values.filter { $0.approvals > 0 }.map(\.sessionID))
        )
        if approvalRaised != raised { approvalRaised = raised }
    }

    /// Reads the catalogue's counts for the saved sessions, at the feed's cadence. A
    /// session the list holds and the daemon did not read has no entry and is counted
    /// as not checked. A daemon that does not know the command leaves the inbox saying
    /// saved sessions are not checked, and is not asked again until the epoch changes. Any other refusal leaves the last read in
    /// place, as the feed's refusals do.
    private func refreshSaved(_ control: ControlClient) async {
        if savedRefusedAtEpoch != nil, savedRefusedAtEpoch == hello?.epoch { return }
        let saved = savedSessionIDs
        guard !saved.isEmpty else {
            if savedReading != .unchecked { savedReading = .unchecked }
            return
        }
        do {
            let next = SavedReading.read(try await control.savedAttention(sessions: saved))
            if savedReading != next { savedReading = next }
        } catch let error as LoomError where error.isUnknownCommand {
            savedRefusedAtEpoch = hello?.epoch
            if savedReading != .unchecked { savedReading = .unchecked }
        } catch {
            // The last answer stays: a refusal says nothing new about the sessions.
        }
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

        // The core attaches an ended lane again at the next poll, so it is told when one ends.
        laneGeneration += 1
        let generation = laneGeneration
        let host = self.host
        controller.onEnded = { host?.laneEnded(sessionID, generation: generation) }
        host?.laneAttached(sessionID, generation: generation)
        controller.connect()
        return controller
    }

    func resume(_ sessionID: String) async throws {
        guard let control else { throw LoomError.closed("\(label) is not connected.") }
        _ = try await control.openUntilResident(sessionID: sessionID)
        try await refresh(control)
        attach(sessionID)
    }

    /// Stops a session. The lane stays until the daemon has answered, so a refused stop leaves the
    /// running session attached, and the caller reports the refusal.
    func stop(_ sessionID: String) async throws {
        guard let control else { return }
        try await control.stopSession(sessionID: sessionID)
        attached[sessionID]?.detach()
        attached[sessionID] = nil
        host?.forget(sessionID)
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
        requestKey: String,
        options: CreationOptions = CreationOptions()
    ) async throws -> String {
        guard let control else { throw LoomError.closed("\(label) is not connected.") }

        // The saga decides what follows each step. This function performs one effect at a
        // time and reports what it saw, so a failure at any step ends in an outcome the
        // sheet can word. The original error is kept so a caller still gets its own type.
        var saga = Dispatch(requestKey: requestKey, prompt: prompt)
        var queue = saga.start()
        var failure: Error?
        var outcome: Dispatch.Outcome?
        var controller: SessionController?
        var sessionID = ""
        while !queue.isEmpty {
            let effect = queue.removeFirst()
            var event: Dispatch.Event?
            switch effect {
            case .create:
                do {
                    let record = try await control.createSession(
                        requestKey: requestKey,
                        workspace: workspace,
                        name: name.isEmpty ? (workspace as NSString).lastPathComponent : name,
                        configuration: configuration,
                        placement: placement,
                        options: options
                    )
                    sessionID = record.id
                    lastCreation = "profile=\(options.profile ?? "") model=\(options.model ?? "") vision=\(options.pins["vision"] ?? "") shareable=\(options.isShareable)" + (record.worktree.map { " worktree=\($0.base) \($0.branch)" } ?? "")
                    event = .created(session: record.id)
                } catch let ignored as WorktreeNotHonoured {
                    failure = ignored
                    event = .createFailed(.worktreeNotHonoured(session: ignored.sessionID))
                } catch LoomError.outcomeUnknown(let command) {
                    failure = LoomError.outcomeUnknown(command: command)
                    event = .createFailed(.unknown)
                } catch {
                    failure = error
                    event = .createFailed(.refused(error.localizedDescription))
                }
            case .open(let id):
                do {
                    _ = try await control.openUntilResident(sessionID: id)
                    event = .opened
                } catch {
                    event = .openFailed(error.localizedDescription)
                }
            case .refresh:
                try? await refresh(control)
                event = .refreshed
            case .attach(let id):
                controller = attach(id)
                await controller?.waitUntilAdopted()
                event = .attached
            case .send(let text):
                if let controller {
                    do {
                        _ = try await controller.request("prompt", body: ["strand": .string(controller.focusedStrand), "text": .string(text)])
                        event = .sendSettled(.acknowledged)
                    } catch LoomError.outcomeUnknown {
                        event = .sendSettled(.unknown)
                    } catch {
                        event = .sendSettled(.refused(error.localizedDescription))
                    }
                } else {
                    event = .sendSettled(.refused("The session is not running."))
                }
            case .cleanUp(let id):
                // The daemon made the session without a worktree and may already be
                // opening it, so it is stopped before it is deleted: the daemon refuses
                // to delete a session that is opening or running, and the stop settles
                // within a few reads. A failed removal leaves it listed, which the
                // error does not hide.
                try? await control.stopSession(sessionID: id)
                for _ in 0..<20 {
                    if (try? await control.deleteSession(sessionID: id)) != nil { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await refresh(control)
                event = .cleanedUp
            case .finish(let result):
                outcome = result
            }
            if let event { queue += saga.apply(event) }
        }

        switch outcome {
        case .sent(let id)?: return id
        case .createdButUnsent(let id, let reason)?: throw CreatedButUnsent(sessionID: id, reason: reason)
        case .unknownCreate?, .failed?, nil:
            throw failure ?? LoomError.closed("The session could not be created.")
        }
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

    /// The one place a background read is started, for every view and model that polls.
    let reads = ReadHost()

    var destination: Destination? = .mission

    /// Rename, stop, archive and delete in flight, with the question each asks.
    let actions = SessionActions()
    var isDispatching = false
    var isAddingDaemon = false
    var isPaletteOpen = false
    #if DEBUG
    /// Bumped by the UI driver to scroll the transcript to its top through SwiftUI,
    /// as a person scrolling up would, rather than behind its back in AppKit.
    var debugScrollToTop = 0

    /// Bumped by the UI driver to scroll the transcript from top to bottom at a
    /// steady speed, for measuring frames while scrolling.
    var debugScrollSweep = 0

    /// What the inbox last drew, written by the view so the driver can read it: the
    /// folder shown, then each band drawn with its count, and the thread the pane
    /// reads. The list's rows and headings are not in the accessibility tree.
    var debugInboxDrawn: [String] = []
    var debugInboxPaneWidth = 0

    /// The Updates cards the owner expanded, and the order of the Watch all board.
    var debugBoard: [String] = []

    /// The row the list highlights, by identity, or empty when the open thread is
    /// outside the folder drawn. Written by the view from the value it binds.
    var debugInboxHighlighted = ""

    /// Set by the UI driver to choose a new agent's placement by title prefix.
    var debugPlacement = ""
    #endif

    /// Whether the inspector column is open, kept across launches with the rest of
    /// the window's layout.
    var showsInspector = UserDefaults.standard.bool(forKey: "showsInspector") {
        didSet { UserDefaults.standard.set(showsInspector, forKey: "showsInspector") }
    }

    /// The appearance a person chose. The system's own is the default.
    var appearance = AppearanceChoice.stored {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: AppearanceChoice.key)
            appearance.apply()
        }
    }

    /// Whether the sidebar column shows. The toolbar's control and ⌘B change the same value.
    ///
    /// It starts shown. With `.automatic` the system collapsed it in a narrow window,
    /// and a window that opens with no sidebar and an empty page reads as stuck.
    var sidebarVisibility: NavigationSplitViewVisibility = .all

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
        let targets = board.needingSessions
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

    /// What needs the owner, decided once by `InboxRule.board` and read by every
    /// surface: the Inbox's badge, the window subtitle, the Dock tile, the menu bar,
    /// the notifier, the jump to the next session, Mission Control, the sidebar and
    /// the inbox. It is recomputed when anything it reads changes, and never by a
    /// view, so two surfaces cannot show different counts. Row ages are counted to
    /// the time of the last change; a view that draws them calls `aged(now:)`.
    private(set) var board = InboxBoard.empty

    /// Computes the board and arms the next recomputation. Observation tracking
    /// reports a change before it lands, so the recomputation waits one main-actor
    /// turn and reads the new values.
    func trackBoard() {
        let (facts, place) = withObservationTracking {
            (boardFacts(), destination == .inbox ? AppCore.Place.inbox : destination.flatMap { dest -> AppCore.Place? in
                if case .session(let id) = dest { return .session(id) }
                return nil
            } ?? .other)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackBoard() }
        }

        // The core settles the board, the open thread, the folder, the project selection
        // and the notices in one step, from these facts, so the pane and the highlight never
        // see a board the selection has not met.
        // The facts come first: the place settles against them, so a selection made just before
        // (a project that was created and chosen) is judged against the board that holds it.
        run(core.apply(.facts(facts, now: Int(Date().timeIntervalSince1970 * 1000))))
        run(core.apply(.place(place)))
    }

    /// What the board and the unseen marks are computed from, as the shell holds it.
    private func boardFacts() -> AppCore.Facts {
        var facts = AppCore.Facts()
        facts.threads = inboxThreads
        facts.feed = attentionRows
        facts.raised = approvalRaised
        facts.reviewing = reviewing
        facts.saved = inboxSaved
        facts.projects = projectStates
        facts.machines = inboxMachines
        for (id, row) in activity { if let reply = row.lastMessage { facts.replies[id] = Self.replyDigest(reply) } }
        return facts
    }

    /// Copies what the core decided to the observed properties views read, and performs
    /// the effects it asked for.
    private func run(_ effects: [AppCore.Effect]) {
        if board != core.board { board = core.board }
        if inboxOpening != core.opening { inboxOpening = core.opening }
        if inboxFolder != core.folder { inboxFolder = core.folder }
        if projectSelection != core.selection { projectSelection = core.selection }
        for effect in effects {
            switch effect {
            case .persist(let key, let value):
                if case .object(let fields) = value { UserDefaults.standard.set(fields.compactMapValues(\.string), forKey: key) }
            case .notify(let plan):
                pendingNotices.append(plan)
            case .sweep(let keeping):
                pendingSweeps.append(keeping)
            case .dockBadge:
                break
            case .navigate:
                destination = .inbox
            }
        }
    }

    /// The notice plans and sweeps the core decided, for the notifier to carry out.
    @ObservationIgnored private var pendingNotices: [NoticePlan] = []
    @ObservationIgnored private var pendingSweeps: [Set<String>] = []

    func takePendingNotices() -> (sweeps: [Set<String>], plans: [NoticePlan]) {
        defer {
            pendingNotices = []
            pendingSweeps = []
        }
        return (pendingSweeps, pendingNotices)
    }

    @ObservationIgnored private var core = AppCore(
        seenReplies: UserDefaults.standard.dictionary(forKey: AppCore.repliesKey) as? [String: String] ?? [:]
    )

    /// The unhealthy machines the inbox lists under its own section.
    var inboxMachines: [String] { attention.filter { $0.kind == .machine }.map(\.id) }

    /// What the inbox has open. Only `chooseInbox`, `openInbox` and `chooseFolder`
    /// move it on the owner's behalf, and a refresh settles it without moving it.
    private(set) var inboxOpening = InboxOpening.none

    /// The folder the inbox list is narrowed to. The list draws `Everything` when
    /// the chosen folder has emptied.
    private(set) var inboxFolder: InboxFolder = .everything

    /// Whether the inbox's reading pane shows the "Watch all" board of the working
    /// sessions in place of the open thread. It is not saved.
    var inboxWatching = false

    /// The briefs the Updates cards and the board draw from, read while the inbox is
    /// on screen.
    let updateWatcher = UpdateWatcher()

    /// The Updates cards the owner expanded, by row identity. It is not saved.
    private(set) var expandedCards: Set<String> = []

    func toggleCard(_ id: String) {
        if expandedCards.contains(id) { expandedCards.remove(id) } else { expandedCards.insert(id) }
    }

    /// The thread whose message field the owner asked to write in, by row id. The
    /// pane that draws it takes the request, focuses its field and clears it, so a
    /// request made before the pane exists (a row's context menu opens the thread
    /// first) is still met when the pane appears.
    var messageRequest: String?

    /// The selections the inbox list draws, in its drawn order: the threads of the
    /// folder it shows, then the unhealthy machines. Next and previous step through
    /// exactly these.
    var inboxDrawn: [InboxSelection] {
        let sections = board.sections
        let shown = InboxRule.shownFolder(chosen: inboxFolder, sections: sections)
        return InboxRule.selectable(InboxRule.visible(sections, in: shown)).map { InboxSelection.thread($0.subject) }
            + inboxMachines.map { InboxSelection.machine($0) }
    }

    /// Moves the open thread one step through the list, as the owner's own choice.
    /// Past either end it does nothing.
    func stepInbox(_ step: InboxCommands.Step) {
        guard let next = InboxCommands.neighbor(of: inboxOpening.selection, in: inboxDrawn, step: step) else { return }
        chooseInbox(next)
    }

    /// The owner picked a row. A nil choice, which a list reports when its selection
    /// is cleared, leaves the open thread as it is.
    func chooseInbox(_ selection: InboxSelection?) {
        guard let selection else { return }
        inboxWatching = false
        run(core.apply(.chooseInbox(selection)))
    }

    /// The owner picked a folder, and the open thread follows only when the folder
    /// does not draw it.
    func chooseFolder(_ folder: InboxFolder) {
        run(core.apply(.chooseFolder(folder)))
    }

    /// Opens a thread in the inbox. A decision is made only beside its evidence,
    /// which the inbox's pane carries, so a row elsewhere goes there to decide. The
    /// folder returns to Everything so the row is among those drawn.
    func openInbox(_ subject: InboxSubject) {
        inboxWatching = false
        run(core.apply(.openInbox(subject)))
    }

    /// The one line a surface other than the inbox says about a row: an approval's
    /// requested authority when its card has been read, else the row's own line.
    func summary(of row: InboxRow) -> String {
        if row.kind == .approval, let line = controller(for: row.sessionID)?.escalations.first?.authorityLines.first {
            return line
        }
        return row.head
    }

    /// The approvals, failed runs and unhealthy machines `Mission.attention` holds,
    /// which the inbox's pane reads for a session's live approval card and for the
    /// machines section. It is not a count: the board is.
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

    /// The resident sessions as the inbox reads them: the display name beside the
    /// daemon's activity report, which is nil when it gave none.
    var inboxThreads: [InboxThread] {
        InboxRule.deduped(daemons.flatMap { $0.inboxThreads(activity: $0.activity) })
    }

    /// The rows whose retry is out, by row id. The pane's Retry and the menu's both
    /// read it, so a second press while one is out queues nothing.
    var retrying: Set<String> = []

    /// The sessions listed under "To review", across daemons.
    var reviewing: Set<String> {
        daemons.reduce(into: Set<String>()) { all, daemon in
            let candidates = ReviewScan.candidates(threads: inboxThreads.filter { daemon.activity[$0.id] != nil })
            all.formUnion(daemon.reviewScan.reviewing(candidates))
        }
    }

    /// The size of a session's change from the scan, for its current message.
    func reviewStat(of sessionID: String, message: String) -> ReviewStat? {
        daemon(holding: sessionID)?.reviewScan.stat(sessionID, message: message)
    }

    /// Whether every try at reading a session's worktree for its last message failed.
    func reviewIsUnreadable(of sessionID: String, message: String) -> Bool {
        daemon(holding: sessionID)?.reviewScan.isUnreadable(sessionID, message: message) ?? false
    }

    /// Sends a message from the inbox pane to a session's strand: a prompt, or a
    /// steer when the person chose one. It attaches a lane first, as a strip's
    /// message does, and returns the daemon's `admitted` or `queued`.
    func sendMessage(sessionID: String, strand: String, text: String, choice: ThreadSend.Choice) async throws -> String? {
        guard let controller = daemon(holding: sessionID)?.attach(sessionID) else {
            throw SendFailure(words: "The session is not running.")
        }
        await controller.waitUntilAdopted()
        guard !controller.isObserver else { throw SendFailure(words: SessionController.observerWords) }
        let reply = try await controller.request(choice.command, body: ["strand": .string(strand), "text": .string(text)])
        return reply.body["status"]?.string
    }

    /// Whether the sidebar draws Projects: a project exists, or a daemon answered with
    /// none, so a new person can reach New Project.
    var offersProjects: Bool {
        ProjectRule.offersEntry(projectCount: projectStates.count, daemonsAnswering: daemons.filter(\.projectsAnswered).count)
    }

    /// Every project on every daemon, each with its board's page zero.
    var projectStates: [ProjectState] {
        daemons.flatMap(\.projects)
    }

    /// The daemon that holds a project. A project id is a function of its workspace,
    /// so two daemons that hold the same folder hold the same id and the first wins.
    func daemon(holdingProject project: String) -> DaemonConnection? {
        daemons.first { daemon in daemon.projects.contains { $0.id == project } }
    }

    /// What the Projects destination has open: a project's page or one of its
    /// tickets. Only the owner's choice moves it, and a refresh that drops what it
    /// names settles it back to nothing.
    var projectSelection: ProjectSelection? {
        didSet {
            // A choice from a view goes to the core, which settles it against the boards.
            if projectSelection != core.selection { run(core.apply(.selectProject(projectSelection))) }
        }
    }

    /// An answer half written to a ticket's question, by ticket.
    var ticketDrafts: [ProjectSelection: String] = [:]

    /// What the last act on a ticket came to, by ticket. It outlives the inbox row the
    /// act was made from: a ticket that moves to a stage nobody waits on leaves the
    /// inbox, and the pane that stays says what was done.
    var ticketResults: [ProjectSelection: TicketResult] = [:]

    /// Text a project form holds, by field name (`post/<project>`, `check/<project>`,
    /// `new/folder`, and so on), so a half-written request survives a move through the
    /// list and a test can write a field without a key window.
    var projectFields: [String: String] = [:]

    /// Whether the new-project sheet is open.
    var isCreatingProject = false

    /// The daemon a new project is made on: the first one that holds a project table,
    /// else the first connected one.
    var projectDaemon: DaemonConnection? {
        daemons.first { $0.projectsAnswered && $0.control != nil } ?? daemons.first { $0.control != nil }
    }

    var attentionRows: [String: AttentionRow] {
        daemons.reduce(into: [:]) { $0.merge($1.attentionRows) { _, new in new } }
    }

    /// The saved sessions the counts took from the catalogue, across daemons. A daemon
    /// whose read has not answered, or does not know the command, adds none, so its
    /// saved sessions are not counted as "not checked" under a line that says they
    /// were read.
    var inboxSaved: InboxSaved {
        var listed: [String] = []
        var rows: [String: SavedAttention] = [:]
        var anyRead = false
        for daemon in daemons {
            guard case .read(let read) = daemon.savedReading else { continue }
            anyRead = true
            listed += daemon.savedSessionIDs
            rows.merge(read) { _, new in new }
        }
        return anyRead ? .read(listed: listed, rows: rows) : .unchecked
    }

    var approvalRaised: [String: Int] {
        daemons.reduce(into: [:]) { $0.merge($1.approvalRaised) { _, new in new } }
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

    /// A digest of the last reply a person saw in each session, kept across launches by the
    /// core. A session whose latest reply differs finished something while they were away.
    /// Only the digest is stored, since replies belong to the daemon and preferences are a
    /// plain file that backups and other programs can read.
    var seenReplies: [String: String] { core.seenReplies }

    private static func replyDigest(_ reply: String) -> String {
        SHA256.hash(data: Data(reply.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func hasUnseenReply(_ sessionID: String) -> Bool {
        guard let reply = activity[sessionID]?.lastMessage else { return false }
        if case .session(sessionID) = destination { return false }
        guard let seen = core.seenReplies[sessionID] else { return false }
        return seen != Self.replyDigest(reply)
    }

    /// Takes the first reply seen from each session as already read. A session that has
    /// never been looked at is not news, or every row would shout on first launch.
    func recordFirstReplies() {
        run(core.apply(.facts(boardFacts(), now: Int(Date().timeIntervalSince1970 * 1000))))
        run(core.apply(.recordFirstReplies))
    }

    /// Records what the open session shows, called as its activity changes.
    func markSeen(_ sessionID: String) {
        run(core.apply(.facts(boardFacts(), now: Int(Date().timeIntervalSince1970 * 1000))))
        run(core.apply(.markSeen(session: sessionID)))
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
        trackBoard()
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
        keep(saved, token: token)
    }

    /// Records a daemon whose credential is already in the keychain, and connects.
    private func keep(_ saved: SavedDaemon, token: String) {
        var all = Self.loadSaved()
        all.append(saved)
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        }
        let connection = DaemonConnection(id: saved.id.uuidString, source: .remote(saved, token: token))
        daemons.append(connection)
        connection.start()
    }

    #if DEBUG
    /// Connects a daemon for a test without saving it, so a run leaves no saved
    /// address or keychain item behind on the machine that ran it.
    func attachForTest(name: String, address: String, token: String) throws {
        _ = try DaemonEndpoint(address: address, token: token)
        let saved = SavedDaemon(id: UUID(), name: name, address: address)
        let connection = DaemonConnection(id: saved.id.uuidString, source: .remote(saved, token: token))
        daemons.append(connection)
        connection.start()
    }

    func detachForTest(name: String) {
        guard let connection = daemons.first(where: { $0.label == name && $0.isRemote }) else { return }
        removeDaemon(connection)
    }
    #endif

    /// Exchanges a claim token for a credential this app drew, then connects with it.
    /// The credential is in the keychain before the daemon hears its digest, so a
    /// lost reply is recovered by claiming again. A refused claim removes it.
    func claimDaemon(name: String, address: String, claim: String, credential: String) async throws {
        _ = try DaemonEndpoint(address: address, token: credential)
        let saved = SavedDaemon(id: UUID(), name: name, address: address)
        try CredentialStore.save(credential, for: saved.id)
        do {
            _ = try await Claim.redeem(address: address, claim: claim, credential: credential)
        } catch {
            CredentialStore.delete(for: saved.id)
            throw error
        }
        keep(saved, token: credential)
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

/// One attached session: the host of a `LoomCore.Session`.
///
/// The core decides: which command is in flight, when the lane refreshes, when the stream
/// is projected, and what becomes of a message whose reply is lost. This class is the
/// shell that carries those decisions out. It owns the socket, one ordered writer and one
/// timer armed for the core's `nextDue`, feeds each received frame to the core with a clock
/// reading, and performs the effects it returns in order.
///
/// The value `Conversation` stays out of observation. Each fact a view draws is its own
/// observed property, set only when it actually changes, so a streamed token invalidates
/// the stream view and leaves a 5,000-row transcript alone. The core asks for the stream
/// to be written once per flush window, and a push that is not a token never writes it.
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
    /// When the daemon recorded the input the running turn answers.
    private(set) var turnStartedAt: Date?
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
    #if DEBUG
    /// A role a scenario forces, because the cluster has one attachment and it is the owner.
    var debugRole: String?
    #endif
    private(set) var connectionID = ""
    /// Tokens a second of the focused strand's last timed generation.
    private(set) var outputRate: Int?
    /// The summarizer's labels for long reasoning, by reasoning row id.
    private(set) var summaries: [String: String] = [:]
    /// The newest request on the focused strand, which the cache outlook counts from.
    private(set) var cacheStamp: CacheStamp?
    private(set) var trace = TraceBoard(programs: [], omitted: 0)
    /// Why the connection ended, in words, once a lane has closed.
    private(set) var ended: EndingWords?
    /// Whether the side question panel is open above the composer.
    var showsSideQuestion = false
    /// Why a background read was refused, by command, for a panel to say.
    private(set) var readFailures: [String: String] = [:]

    /// The draft, the sent lines, notices and held-input edits. It lives here and
    /// not in the view so a draft survives the view being rebuilt.
    let composer = ComposerModel()

    var focusedStrand = "main" {
        didSet {
            if focusedStrand != oldValue { perform(core?.apply(.focus(focusedStrand), now: now()) ?? []) }
        }
    }

    #if DEBUG
    /// How many pushes of each kind arrived, so a scenario can tell a missing event from a missing reading.
    @ObservationIgnored private(set) var pushedEvents: [String: Int] = [:]
    #endif
    @ObservationIgnored private var core: Session?
    @ObservationIgnored private var projectedRevision = -1
    @ObservationIgnored private var olderCursor: Int?
    @ObservationIgnored private var hasReadDecisions = false
    @ObservationIgnored private let endpoint: DaemonEndpoint
    @ObservationIgnored private var socket: WebSocket?
    @ObservationIgnored private var writes: AsyncStream<String>.Continuation?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var waiters: [Int: CheckedContinuation<Session.Settlement, Never>] = [:]
    @ObservationIgnored private var nextTag = 1
    @ObservationIgnored private var notesAsked: Set<String> = []
    @ObservationIgnored private let origin = ContinuousClock.now
    @ObservationIgnored private var inheriting: Session?

    /// Called when this attachment's lane ends, so the host connection can attach again.
    @ObservationIgnored var onEnded: (() -> Void)?

    init(sessionID: String, endpoint: DaemonEndpoint) {
        self.sessionID = sessionID
        self.endpoint = endpoint
    }

    /// What the core folded so far, or an empty conversation before the lane starts.
    private var conversation: Conversation { core?.conversation ?? Conversation(sessionID: sessionID) }

    /// The highest record sequence `/clear` hid on each strand.
    var clearedThrough: [String: Int] { core?.clearedThrough ?? [:] }

    /// Whether this attachment may only watch: it sends nothing and answers nothing.
    var isObserver: Bool {
        #if DEBUG
        if let debugRole { return debugRole == "observer" }
        #endif
        return role == "observer"
    }

    var strand: Strand? { strands.first { $0.id == focusedStrand } }
    var isBusy: Bool { strand?.isBusy ?? false }
    var totalCost: Double? { usage["cost"]?["total"]?.double }
    var totalTokens: Int? { usage["totalTokens"]?.int }

    /// Milliseconds since this controller was made: the monotonic reading the core takes.
    private func now() -> Int {
        let elapsed = ContinuousClock.now - origin
        return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    func connect() {
        guard core == nil else { return }
        let url: URL
        do {
            url = try endpoint.url(path: "/v2/sessions/\(sessionID)/ws")
        } catch {
            isLive = false
            lastError = error.localizedDescription
            return
        }
        let socket = WebSocket(url: url, bearer: endpoint.token)
        self.socket = socket
        let (queue, writes) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        self.writes = writes
        let started = Session.start(sessionID: sessionID, inheriting: inheriting, now: now())
        core = started.session
        inheriting = nil
        perform(started.effects)
        writer = Task { [weak self] in
            for await text in queue {
                #if DEBUG
                if let delay = ComposerModel.debugSendDelay { try? await Task.sleep(for: delay) }
                #endif
                do {
                    try await socket.send(text)
                } catch {
                    self?.fail(error)
                }
            }
        }
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let text = try await socket.receive()
                    guard let self else { return }
                    self.perform(self.core?.receive(text, now: self.now()) ?? [])
                } catch {
                    self?.fail(error)
                    return
                }
            }
        }
    }

    /// Reports a transport failure to the core, which ends the lane and settles its callers.
    private func fail(_ error: Error) {
        let failure = (error as? LoomError) ?? .closed(error.localizedDescription)
        perform(core?.receive(failed: failure, now: now()) ?? [])
    }

    /// Takes over what the previous attachment to this session was showing, for a
    /// lane that was dropped and made again, which a configuration reload or a
    /// profile switch does. Until the new lane's first cut arrives the window keeps
    /// the transcript, the panels and the draft it had, so the reopen does not
    /// blank the page, move the scroll or lose what was being typed. The first cut
    /// replaces all of it with what the daemon reports.
    ///
    /// The core also inherits the sent drafts. One whose reply was lost stays out of the
    /// editor until the first cut settles it.
    func inherit(from previous: SessionController) {
        // The strand is set first because choosing one rebuilds the transcript.
        focusedStrand = previous.focusedStrand
        blocks = previous.blocks
        hasOlder = previous.hasOlder
        strands = previous.strands
        strandLines = previous.strandLines
        context = previous.context
        todo = previous.todo
        surfaces = previous.surfaces
        summaries = previous.summaries
        trace = previous.trace
        branch = previous.branch
        worktree = previous.worktree
        usage = previous.usage
        role = previous.role
        showsSideQuestion = previous.showsSideQuestion
        composer.draft = previous.composer.draft
        if let previousCore = previous.core {
            if core != nil {
                core?.inherit(from: previousCore)
                mirrorLedger()
            } else {
                inheriting = previousCore
            }
        }
    }

    func detach() {

        // Whoever closes a lane, the host is told it ended, so the core's table of lanes never holds
        // one that is gone. A caller that wants no new lane says so with `forget`, which follows the
        // end in the host's ordered channel and removes the session from the table.
        let ended = onEnded
        onEnded = nil
        reader?.cancel()
        isLive = false
        perform(core?.close(now: now()) ?? [])
        ended?()
    }

    // MARK: Carrying out the core's effects

    private func perform(_ effects: [Session.Effect]) {
        for effect in effects {
            switch effect {
            case .transmit(let text):
                writes?.yield(text)
            case .shut:
                writes?.finish()
                socket?.close()
            case .project(let projection):
                switch projection {
                case .all(let forced): syncAll(force: forced == .always)
                case .pushed: syncPushed()
                case .stream: setStream()
                }
            case .settled(let tag, let settlement):
                waiters.removeValue(forKey: tag)?.resume(returning: settlement)
            case .restoreDraft(let text):
                composer.restore(text)
            case .notice(let words, let tone):
                composer.say(words, tone == .warning ? .warning : .info)
            case .forgetImages(let text):
                composer.forgetImages(text)
            case .restoreReturned(let text, let strand, let attachments):
                composer.restoreReturned(text, strand: strand, attachments: attachments)
            case .ended(let error):
                isLive = false
                reader?.cancel()
                timer?.cancel()
                ended = EndingWords.notice(for: error)
                if let error { lastError = error.localizedDescription }
                onEnded?()
            case .pushedEvent(let event):
                #if DEBUG
                pushedEvents[event, default: 0] += 1
                #endif
                _ = event
            }
        }
        mirrorLedger()
        arm()
    }

    private func mirrorLedger() {
        guard let ledger = core?.ledger, composer.ledger != ledger else { return }
        composer.ledger = ledger
        composer.pruneImages()
    }

    /// Arms the one wake-up the core asks for. Nothing ticks on a fixed cadence.
    private func arm() {
        timer?.cancel()
        timer = nil
        guard let due = core?.nextDue else { return }
        let wait = max(1, due - now())
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.perform(self.core?.tick(now: self.now()) ?? [])
        }
    }

    // MARK: Commands

    /// Submits a command and waits for the core to say how it ended.
    private func submit(_ command: Lane.Command) async -> Session.Settlement {
        guard core != nil else { return .failed(.closed("this session is not attached")) }
        let tag = nextTag
        nextTag += 1
        return await withCheckedContinuation { resume in
            waiters[tag] = resume
            perform(core?.apply(.submit(command, tag: tag), now: now()) ?? [])
        }
    }

    /// The reply of a command, or the error that ended it. A lost reply is `outcomeUnknown`.
    private func call(_ command: Lane.Command) async throws -> EventEnvelope {
        switch await submit(command) {
        case .reply(let reply): return reply
        case .cut: throw LoomError.protocolViolation("\(command.name) answered with a transfer")
        case .refused(let code, let message, let details): throw LoomError.server(code: code, message: message, details: details)
        case .unknown(let name): throw LoomError.outcomeUnknown(command: name)
        case .failed(let error): throw error
        }
    }

    private func transfer(_ command: Lane.Command) async throws -> Cut {
        switch await submit(command) {
        case .cut(let cut): return cut
        case .reply: throw LoomError.protocolViolation("\(command.name) did not begin a transfer")
        case .refused(let code, let message, let details): throw LoomError.server(code: code, message: message, details: details)
        case .unknown(let name): throw LoomError.outcomeUnknown(command: name)
        case .failed(let error): throw error
        }
    }

    /// Sends a message from the composer. The core keeps it in the ledger until the daemon
    /// answers, and decides what becomes of the text if the answer is a refusal or is lost.
    func send(message text: String, delivery: Delivery, command: Lane.Command, confirming: String? = nil) {
        guard core != nil else {
            composer.restore(text)
            composer.say("The session is not attached.", .warning)
            return
        }
        perform(core?.apply(.send(text: text, delivery: delivery, command: command, confirming: confirming), now: now()) ?? [])
    }

    /// Hides everything this window has drawn on the focused strand. The records stay
    /// in the session, and a reopened window or another client shows them again.
    func clearTranscript() {
        perform(core?.apply(.clear, now: now()) ?? [])
    }

    /// The answered approvals, read again first so one just given is included.
    func decidedApprovals() async -> [Decision] {
        _ = try? await transfer(Lane.Command("escalations_decided", kind: .transfer))
        return Array(conversation.decisions.values)
    }

    private func setStream() {
        let next = conversation.streams[focusedStrand]
        if stream != next { stream = next }
    }

    /// Writes what a push can change. It never writes the stream: that is the flush's job,
    /// so a turn that streams while tool output and usage arrive changes `stream` once per
    /// flush window and not once per push.
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
        assign(\.connectionID, conversation.connectionID)
        assign(\.summaries, conversation.summaries)
        assign(\.outputRate, conversation.generation.rate(strand: focusedStrand))
        if todo == nil, let seeded = notesTodo() { todo = seeded }
    }

    private func syncAll(force: Bool = false) {
        // The strands come first because a turn is live while its strand is busy.
        assign(\.strands, conversation.strands)
        if force || projectedRevision != conversation.revision {
            projectedRevision = conversation.revision
            let cleared = clearedThrough[focusedStrand]
            let rows = conversation.rows(strand: focusedStrand, clearedThrough: cleared)
            assign(\.blocks, TranscriptBlock.group(rows, running: isBusy))

            // Older records are paged in from the chain, so a cleared window would
            // fetch and hide them again. It offers none.
            assign(\.hasOlder, cleared == nil && conversation.hasOlder(strand: focusedStrand))
            assign(\.cacheStamp, CacheStamp.newest(rows))
            askForSummaries(rows)
            assign(\.strandLines, conversation.strandLines())
            assign(\.trace, conversation.traceBoard(strand: focusedStrand))
            assign(\.todo, conversation.todoBoard(strand: focusedStrand) ?? notesTodo())
            askForNotesIfNoBoard()
            let input = rows.last { if case .user = $0.kind { return true }; return false }?.at
            assign(\.turnStartedAt, input.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
        let held = escalations.count
        assign(\.escalations, conversation.escalations)

        // The ledger of answered approvals is read when the session opens and
        // whenever a pending one goes away, since that is when it gains a row.
        if !hasReadDecisions || conversation.escalations.count < held { readDecisions() }
        assign(\.pendingInputs, conversation.pendingInputs)
        assign(\.branch, conversation.branch)
        assign(\.usage, conversation.usage)
        assign(\.isAdopted, conversation.hasAdoptedCut)
        syncPushed()
        setStream()

        // The elapsed time is this client's own observation of the run.
        if isBusy {
            if busySince == nil { busySince = Date() }
        } else if busySince != nil {
            busySince = nil
        }
    }

    /// Asks the daemon for the stored labels of long reasoning blocks this window holds.
    /// A daemon with no summarizer answers with none, and that claims nothing.
    private func askForSummaries(_ rows: [TranscriptRow]) {
        guard let wanted = core?.takeWantedSummaries(in: rows), !wanted.isEmpty else { return }
        read("block_summaries", body: ["blocks": .array(wanted.map { ["entry": .string($0.entry), "block": .int(Int64($0.block))] })])
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
    ///
    /// The message goes through the session's ledger like the composer's, so a refusal returns its
    /// text, and a lost reply keeps it out of the editor and says it may have been sent.
    func send(text: String) {
        let strand = focusedStrand
        let steer = isBusy
        send(
            message: text,
            delivery: steer ? .steer : .send,
            command: Lane.Command(steer ? "steer" : "prompt", body: ["strand": .string(strand), "text": .string(text)], kind: .mutation)
        )
    }

    /// Why an observer's command is not sent. The daemon would refuse it too.
    static let observerWords = "An observer can watch a session but cannot change it."

    func abort() {
        guard !isObserver else { lastError = Self.observerWords; return }
        let strand = focusedStrand
        fire { try await self.call(Lane.Command("abort", body: ["strand": .string(strand)], kind: .mutation)) }
    }

    /// Answers with the record the person is looking at, captured by the view.
    /// A stale answer is refused by sequence, and the next cut redraws it.
    func approve(_ record: Escalation, remember: Bool = false) {
        guard !isObserver else { lastError = Self.observerWords; return }
        guard isCurrent(record) else { return }
        var body: [String: JSONValue] = [
            "escalation_id": .string(record.id),
            "grants": .array(record.grants),
            "action": .string(record.action),
            "expected_seq": .int(Int64(record.seq)),
        ]
        if remember { body["scope"] = "session" }
        fire { try await self.call(Lane.Command("approve", body: .object(body), kind: .mutation)) }
    }

    func deny(_ record: Escalation) {
        guard !isObserver else { lastError = Self.observerWords; return }
        guard isCurrent(record) else { return }
        fire {
            try await self.call(Lane.Command("deny", body: [
                "escalation_id": .string(record.id),
                "expected_seq": .int(Int64(record.seq)),
            ], kind: .mutation))
        }
    }

    /// Whether the record a person answered is the one the session holds now. A
    /// record that changed under them is refused here with words, instead of
    /// being sent for the daemon to refuse by sequence.
    private func isCurrent(_ record: Escalation) -> Bool {
        if escalations.contains(record) { return true }
        lastError = Escalation.staleWords
        return false
    }

    /// Runs any session command. A snapshot reply lands in `surfaces` by its mode,
    /// and a refusal lands in `lastError`.
    func run(_ command: String, body: JSONValue = .object([:])) {
        guard core != nil else { return }
        lastError = nil
        Task {
            do {
                _ = try await call(Lane.Command(command, body: body, kind: .mutation))
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Reads a surface without disturbing `lastError`, for a panel that polls. A
    /// refusal is kept per command in `readFailures`, so the panel can say why it
    /// has nothing to show, and a later success clears it.
    func read(_ command: String, body: JSONValue = .object([:])) {
        guard core != nil else { return }
        Task {
            do {
                _ = try await call(Lane.Command(command, body: body, kind: .read))
                if readFailures[command] != nil { readFailures[command] = nil }
            } catch {
                readFailures[command] = error.localizedDescription
            }
        }
    }

    /// Sends a command and returns its reply, for a surface that keeps its own state
    /// beside the controller's. The credit's order is kept, because it goes through
    /// the core's lane.
    func exchange(_ command: String, body: JSONValue = .object([:])) async throws -> EventEnvelope {
        guard core != nil else { throw LoomError.closed("the session is not attached") }
        return try await call(Lane.Command(command, body: body, kind: .mutation))
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
        guard core != nil else { return }
        Task {
            do {
                _ = try await call(Lane.Command("worktree_diff", kind: .mutation))
            } catch LoomError.server(code: "busy", _, _) {
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Pages in older records by turns. Each request follows the strand's own
    /// parent links with `history_lineage`, so a long session costs one read per
    /// hundred of this strand's records however many another strand wrote between
    /// them. It stops once a whole earlier turn has arrived.
    func loadOlder() {
        guard !isLoadingOlder, core != nil else { return }
        isLoadingOlder = true
        let strand = focusedStrand
        Task {
            defer { isLoadingOlder = false }
            do {
                let wanted = conversation.inputCount(strand: strand) + 1
                var pages = 0
                while pages < 6, conversation.inputCount(strand: strand) < wanted {
                    pages += 1
                    guard let anchor = conversation.olderAnchor(strand: strand) else {
                        // A record too large to decode hides its parent, so the
                        // lineage walk cannot continue past it; page by sequence.
                        if let before = olderCursor ?? conversation.oldestSeq {
                            olderCursor = try await pageBySequence(before: before)
                        }
                        break
                    }
                    let cut = try await lineage(from: anchor)
                    if cut.entries.isEmpty { break }
                }
                syncAll(force: true)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Reads one page of a strand's records ending at `from`. A page whose newest record is
    /// another entry is refused, because it is not the path that was asked for.
    private func lineage(from: String) async throws -> Cut {
        let cut = try await transfer(Lane.Command("history_lineage", body: ["from": .string(from)], kind: .transfer))
        if let newest = cut.entries.last, newest["id"]?.string != from {
            throw LoomError.protocolViolation("history_lineage ended at another entry")
        }
        return cut
    }

    /// Loads the entries just below `before`, following `more_after` until the span is
    /// exhausted, and returns the lower bound it reached.
    private func pageBySequence(before: Int, span: Int = 400) async throws -> Int {
        let floor = max(0, before - span)
        var after = floor
        while true {
            let cut = try await transfer(Lane.Command("history", body: [
                "after_seq": .int(Int64(after)),
                "before_seq": .int(Int64(before)),
            ], kind: .transfer))
            guard let more = cut.moreAfter else { return floor }
            after = more
        }
    }

    private func readDecisions() {
        guard core != nil else { return }
        hasReadDecisions = true
        Task { _ = try? await transfer(Lane.Command("escalations_decided", kind: .transfer)) }
    }

    /// Sends any session command and returns its reply, applying a snapshot reply
    /// the way a push is. A refusal throws, and the caller words it.
    func request(_ command: String, body: JSONValue = .object([:])) async throws -> EventEnvelope {
        guard core != nil else { throw LoomError.closed("this session is not attached") }
        return try await call(Lane.Command(command, body: body, kind: .mutation))
    }

    /// The names the daemon has offered for `/model` and `/profile` completion.
    var catalogue: SlashCommand.Catalogue {
        SlashCommand.Catalogue(
            models: (surfaces["models"]?["models"]?.array ?? []).compactMap { $0["name"]?.string },
            profiles: (surfaces["profile"]?["available"]?.array ?? []).compactMap(\.string)
        )
    }

    /// Reads a page of a subagent running on another orchestrator.
    func peek(child: RemoteChild) {
        perform(core?.apply(.beginPeek(child: child.id), now: now()) ?? [])
        let id = child.id
        fire { try await self.call(Lane.Command("child_history", body: ["child": .string(id), "before": .int(0)], kind: .mutation)) }
    }

    func endPeek() {
        perform(core?.apply(.endPeek, now: now()) ?? [])
    }

    /// Runs one command and records a failure in `lastError`.
    private func fire(_ action: @escaping @MainActor () async throws -> EventEnvelope) {
        guard core != nil else { return }
        lastError = nil
        Task {
            do {
                _ = try await action()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
