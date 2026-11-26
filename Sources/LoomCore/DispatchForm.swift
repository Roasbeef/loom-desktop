import LoomKit

/// The new-session form as a value.
///
/// `DispatchSheet` held the form in nineteen `@State` fields, and the rules about it (when
/// Dispatch is allowed, what the hint says, when the idempotency key changes) in its body,
/// so the only test of them was a UI scenario (NS-23). This value holds the fields and
/// decides those rules from them, and the sheet draws it.
///
/// ## The request key
///
/// `sessions.create` is idempotent on `request_key`: a retry with the same key recovers the
/// session the first attempt made, which is what makes a retry after a lost reply safe. That
/// is only safe if the key names the whole request. The sheet changed the key when the
/// daemon, the placement, the profile, the models, the sharing or the worktree changed, but
/// not when the folder or the name did, so a retry after a lost reply and a new folder would
/// have recovered the session made for the old folder (O4). The key here is derived from a
/// seed the host supplies once and a generation that moves on every change to any field the
/// create carries, the folder and the name included. The prompt moves it only through the name:
/// with no name typed, the session is named for the prompt's first line. Otherwise the prompt is
/// not a create parameter, and it is sent afterwards, once.
///
/// ## What the host supplies
///
/// The disk is the host's. It judges a typed folder and a worktree against the file system and
/// reports the result with the edit that made it, so the form never holds a judgement of a
/// path other than the one it shows.
public struct DispatchForm: Sendable, Equatable {
    public enum Worktree: Sendable, Equatable {
        case folder
        case ownTree
    }

    /// Where the folder is: on this Mac's disk, where the app can judge it, or on a machine
    /// whose folders only the daemon can judge.
    public enum Disk: Sendable, Equatable {
        case thisMac
        case elsewhere
    }

    public struct Fields: Sendable, Equatable {
        public var daemon = "local"
        public var disk: Disk = .thisMac
        public var placement = PlacementChoice.local
        public var workspace = ""
        public var configuration = ""
        public var prompt = ""
        public var name = ""
        public var profile = ""
        public var model = ""
        public var vision = ""
        public var isShareable = false
        public var worktree = Worktree.folder
        public var worktreeBase = ""

        public init() {}
    }

    public enum Edit: Sendable, Equatable {
        case daemon(String, disk: Disk)
        case placement(PlacementChoice)
        case workspace(String, folder: FolderCheck, worktreeProblem: String?)
        case configuration(String)
        case prompt(String)
        case name(String)
        case profile(String)
        case model(String)
        case vision(String)
        case shareable(Bool)
        case worktree(Worktree)
        case worktreeBase(String, problem: String?)
    }

    /// What the host sends as `sessions.create` and then the first prompt.
    public struct Request: Sendable, Equatable {
        public let requestKey: String
        public let daemon: String
        public let workspace: String
        public let name: String
        public let prompt: String
        public let placement: PlacementChoice
        public let configuration: String
        public let profile: String?
        public let model: String?
        public let vision: String?
        public let isShareable: Bool
        public let worktreeBase: String?
        public let wantsWorktree: Bool

        /// Everything `sessions.create` carries, which the key must name.
        public var createParameters: [String] {
            [daemon, workspace, name, "\(placement)", configuration, profile ?? "", model ?? "", vision ?? "", "\(isShareable)", "\(wantsWorktree)", worktreeBase ?? ""]
        }
    }

    public enum Result: Sendable, Equatable {
        case sent(session: String)
        case createdButUnsent(session: String, words: String)
        /// The daemon ignored the worktree and the session it made was removed.
        case worktreeIgnored(words: String)
        case failed(words: String)
    }

    public enum Event: Sendable, Equatable {
        case edit(Edit)
        case submit
        case finished(Result)
    }

    public enum Effect: Sendable, Equatable {
        case dispatch(Request)
        /// The form is done: show this session.
        case close(session: String)
        /// Remember this folder for the next form.
        case rememberWorkspace(String)
    }

    public private(set) var fields = Fields()
    public private(set) var isSending = false
    /// The session a dispatch made without sending its prompt, which the form offers instead
    /// of sending again.
    public private(set) var createdID: String?
    public private(set) var error: String?

    private let seed: String
    private var generation = 0
    private var folder: FolderCheck = .empty
    private var worktreeProblemWords: String?
    private var baseProblemWords: String?

    /// `seed` names this form, once: the host passes a fresh identifier.
    public init(seed: String, daemon: String = "local", disk: Disk = .thisMac) {
        self.seed = seed
        fields.daemon = daemon
        fields.disk = disk
    }

    /// The key every attempt of this form's current request carries.
    public var requestKey: String { "\(seed)-\(generation)" }

    // MARK: Rules

    /// The folder as the form judges it: on this Mac's disk by what the host reported, and
    /// elsewhere not at all, because the daemon judges those.
    public var folderJudgement: FolderCheck {
        guard fields.placement == .local, fields.disk == .thisMac else {
            return fields.workspace.isEmpty ? .empty : .ok(fields.workspace)
        }
        return folder
    }

    /// What the worktree choice is worth: the base to send, and the sentence that says why it
    /// cannot be sent, if there is one. The choice applies to a folder on the agent's machine
    /// and not to an executor's workspace, which chooses its own mode.
    public var worktreeJudgement: (wanted: Bool, problem: String?) {
        guard fields.worktree == .ownTree, fields.placement == .local else { return (false, nil) }
        if let problem = baseProblemWords { return (false, problem) }
        if fields.disk == .thisMac, !fields.workspace.isEmpty, case .ok = folderJudgement, let problem = worktreeProblemWords {
            return (false, problem)
        }
        return (true, nil)
    }

    /// Whether Dispatch is allowed.
    public var canDispatch: Bool {
        if isSending || createdID != nil || fields.workspace.isEmpty || fields.prompt.isEmpty { return false }
        if worktreeJudgement.problem != nil { return false }
        let judgedOnThisMac = fields.placement == .local && fields.disk == .thisMac
        return !(judgedOnThisMac && !folderJudgement.isUsable)
    }

    /// Why the button is disabled, so a person is not left to guess.
    public var hint: String {
        if fields.prompt.isEmpty { return "Describe the work to dispatch." }
        if fields.workspace.isEmpty { return "Choose a folder to dispatch (\u{2318}O)." }
        if let words = folderJudgement.words { return words }
        if let words = worktreeJudgement.problem { return words }
        return "\u{2318}\u{21A9} to dispatch"
    }

    // MARK: Events

    public mutating func apply(_ event: Event) -> [Effect] {
        switch event {
        case .edit(let edit):
            change(edit)
            return []
        case .submit:
            guard canDispatch else { return [] }
            isSending = true
            error = nil
            return [.dispatch(request())]
        case .finished(let result):
            isSending = false
            switch result {
            case .sent(let session):
                return [.rememberWorkspace(fields.workspace), .close(session: session)]
            case .createdButUnsent(let session, let words):
                // Sending again would create a second session, so the form offers the one that exists.
                createdID = session
                error = words
            case .worktreeIgnored(let words):
                // That session was removed, so the same key must not recover it.
                generation += 1
                error = words
            case .failed(let words):
                error = words
            }
            return []
        }
    }

    private mutating func change(_ edit: Edit) {
        switch edit {
        case .daemon(let daemon, let disk):
            guard daemon != fields.daemon || disk != fields.disk else { return }
            fields.daemon = daemon
            fields.disk = disk

            // A different machine means a different meaning for every field that names one of its things.
            fields.placement = .local
            fields.workspace = ""
            fields.profile = ""
            fields.model = ""
            fields.vision = ""
            folder = .empty
            worktreeProblemWords = nil
            generation += 1
        case .placement(let placement):
            guard placement != fields.placement else { return }
            fields.placement = placement

            // Changing where it runs changes what the workspace field means.
            fields.workspace = ""
            folder = .empty
            worktreeProblemWords = nil
            generation += 1
        case .workspace(let text, let judged, let problem):
            // The disk may have changed under the same text (a folder made, a repository
            // initialised), so the judgement is always taken. Only a new text moves the key.
            folder = judged
            worktreeProblemWords = problem
            guard text != fields.workspace else { return }
            fields.workspace = text
            generation += 1
        case .configuration(let text):
            guard text != fields.configuration else { return }
            fields.configuration = text
            generation += 1
        case .prompt(let text):
            // With no name typed, the session is named for the first line of the prompt, so
            // editing that line changes a create parameter and must move the key.
            let before = effectiveName
            fields.prompt = text
            if effectiveName != before { generation += 1 }
        case .name(let text):
            guard text != fields.name else { return }
            fields.name = text
            generation += 1
        case .profile(let text):
            guard text != fields.profile else { return }
            fields.profile = text
            generation += 1
        case .model(let text):
            guard text != fields.model else { return }
            fields.model = text
            generation += 1
        case .vision(let text):
            guard text != fields.vision else { return }
            fields.vision = text
            generation += 1
        case .shareable(let on):
            guard on != fields.isShareable else { return }
            fields.isShareable = on
            generation += 1
        case .worktree(let choice):
            guard choice != fields.worktree else { return }
            fields.worktree = choice
            generation += 1
        case .worktreeBase(let text, let problem):
            guard text != fields.worktreeBase else { return }
            fields.worktreeBase = text
            baseProblemWords = problem
            generation += 1
        }
    }

    /// The name the session is created with: the one typed, or the first line of the prompt.
    public var effectiveName: String {
        let typed = fields.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = fields.prompt.split(separator: "\n").first.map { String($0.prefix(60)) } ?? ""
        return typed.isEmpty ? firstLine : typed
    }

    private func request() -> Request {
        let wanted = worktreeJudgement.wanted
        let workspace: String
        if case .ok(let path) = folderJudgement, fields.placement == .local, fields.disk == .thisMac {
            workspace = path
        } else {
            workspace = fields.workspace
        }
        return Request(
            requestKey: requestKey,
            daemon: fields.daemon,
            workspace: workspace,
            name: effectiveName,
            prompt: fields.prompt,
            placement: fields.placement,
            configuration: fields.configuration,
            profile: fields.profile.isEmpty ? nil : fields.profile,
            model: fields.model.isEmpty ? nil : fields.model,
            vision: fields.vision.isEmpty ? nil : fields.vision,
            isShareable: fields.isShareable,
            worktreeBase: wanted ? fields.worktreeBase : nil,
            wantsWorktree: wanted
        )
    }
}
