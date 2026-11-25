import LoomKit

/// A dispatch as a saga: create a session, open it, attach a lane, send its first prompt.
///
/// `DaemonConnection.dispatch` was straight-line async code with a retry loop inside. This
/// value decides what happens after each step and names the next effect, so a test can fail
/// every step and check what the person is told. The host performs one effect at a time and
/// reports what it saw as an event.
///
/// ## What the person is told
///
/// - `sent`: the session exists and its first prompt was acknowledged.
/// - `createdButUnsent`: the session exists, and the prompt was not acknowledged. Before this
///   saga the first prompt was fire and forget (audit finding H2): `dispatch` returned the
///   session as a success while the prompt could be lost with an error nobody saw. Now a
///   refused or unknown first prompt ends the dispatch as `createdButUnsent`, naming the
///   session, so the sheet can say so. The prompt is never sent a second time.
/// - `unknownCreate`: no reply to `sessions.create`. The session may exist, so the form
///   keeps its `request_key` and a retry recovers the original session instead of making a
///   second (O4).
/// - `failed`: nothing was created, or what was created was removed.
///
/// ## Invariants
///
/// `DispatchModelTests` checks them: one terminal outcome per run, the same request key on
/// every attempt of one form, at most one session per key, and the first prompt written at
/// most once.
public struct Dispatch: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case sent(session: String)
        case createdButUnsent(session: String, reason: String)
        case unknownCreate(requestKey: String)
        case failed(String)
    }

    public enum CreateFailure: Sendable, Equatable {
        case refused(String)
        /// The reply was lost.
        case unknown
        /// The daemon made the session without the worktree that was asked for.
        case worktreeNotHonoured(session: String)
    }

    public enum SendResult: Sendable, Equatable {
        case acknowledged
        case refused(String)
        case unknown
    }

    public enum Effect: Sendable, Equatable {
        case create(requestKey: String)
        case open(session: String)
        case refresh
        /// Attach a lane and wait for its first cut.
        case attach(session: String)
        case send(prompt: String)
        /// Stop the session, then delete it, trying again while the daemon says it is busy.
        case cleanUp(session: String)
        case finish(Outcome)
    }

    public enum Event: Sendable, Equatable {
        case created(session: String)
        case createFailed(CreateFailure)
        case opened
        case openFailed(String)
        case refreshed
        case attached
        case sendSettled(SendResult)
        case cleanedUp
    }

    private enum Step: Sendable, Equatable {
        case creating
        case opening(session: String)
        case refreshing(session: String)
        case failingToOpen(session: String, reason: String)
        case attaching(session: String)
        case sending(session: String)
        case cleaning
        case finished
    }

    public let requestKey: String
    public let prompt: String
    private var step: Step = .creating

    public init(requestKey: String, prompt: String) {
        self.requestKey = requestKey
        self.prompt = prompt
    }

    /// The first effect.
    public func start() -> [Effect] { [.create(requestKey: requestKey)] }

    public var isFinished: Bool { step == .finished }

    /// Reduces what the host saw, and returns the next effect. An event that does not
    /// belong to the step the saga is in is ignored.
    public mutating func apply(_ event: Event) -> [Effect] {
        switch (step, event) {
        case (.creating, .created(let session)):
            step = .opening(session: session)
            return [.open(session: session)]
        case (.creating, .createFailed(.refused(let words))):
            return end(.failed(words))
        case (.creating, .createFailed(.unknown)):
            return end(.unknownCreate(requestKey: requestKey))
        case (.creating, .createFailed(.worktreeNotHonoured(let session))):
            step = .cleaning
            return [.cleanUp(session: session)]
        case (.cleaning, .cleanedUp):
            return end(.failed("The daemon did not create the session in a worktree of its own."))
        case (.opening(let session), .opened):
            step = .refreshing(session: session)
            return [.refresh]
        case (.opening(let session), .openFailed(let reason)):
            step = .failingToOpen(session: session, reason: reason)
            return [.refresh]
        case (.failingToOpen(let session, let reason), .refreshed):
            return end(.createdButUnsent(session: session, reason: reason))
        case (.refreshing(let session), .refreshed):
            step = .attaching(session: session)
            return [.attach(session: session)]
        case (.attaching(let session), .attached):
            step = .sending(session: session)
            return [.send(prompt: prompt)]
        case (.sending(let session), .sendSettled(let result)):
            switch result {
            case .acknowledged: return end(.sent(session: session))
            case .refused(let words): return end(.createdButUnsent(session: session, reason: words))
            case .unknown: return end(.createdButUnsent(session: session, reason: "No reply came to the first message, so it may not have arrived."))
            }
        default:
            return []
        }
    }

    private mutating func end(_ outcome: Outcome) -> [Effect] {
        step = .finished
        return [.finish(outcome)]
    }
}
