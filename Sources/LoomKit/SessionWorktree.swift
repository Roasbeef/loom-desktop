import Foundation

// A session in a Git worktree of its own, chosen when the session is created
// (loom's protocol-change/133). The choice travels in `sessions.create` as
// `worktree: {base?}`, and a daemon that has the feature answers with
// `worktree: {base, branch}` on the create reply and on every `sessions.list`
// record of such a session. The record's `workspace` stays the folder.

/// The worktree a session works in, as the daemon reports it.
public struct SessionWorktree: Sendable, Equatable {
    /// The commit-ish the session's branch was started from.
    public let base: String
    /// The branch the session works on, `loom/<session id>`.
    public let branch: String

    public init(base: String, branch: String) {
        self.base = base
        self.branch = branch
    }

    /// Reads the member of a record. A member that is absent, or that does not
    /// name a branch, is no worktree: a session without one omits the member.
    init?(_ value: JSONValue?) {
        guard let value, let branch = value["branch"]?.string, !branch.isEmpty else { return nil }
        self.init(base: value["base"]?.string ?? "HEAD", branch: branch)
    }
}

/// A request that a new session work in its own worktree. The presence of the
/// request is the choice, so the form holds an optional value and not a flag.
public struct WorktreeRequest: Sendable, Equatable {
    /// What the branch starts from. Nil, or text with nothing but spaces, asks
    /// for the daemon's default, `HEAD`.
    public var base: String?

    public init(base: String? = nil) {
        self.base = base
    }

    /// The base to send, or nil to leave the default to the daemon.
    var sentBase: String? {
        let text = base?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// The member `sessions.create` takes: `{}` for the default base.
    var wire: JSONValue {
        guard let sentBase else { return .object([:]) }
        return .object(["base": .string(sentBase)])
    }
}

/// What a person is told about a worktree choice, before and after a request.
public enum WorktreeWords {
    /// Why the base cannot be used, or nil when it can. This is the daemon's own
    /// rule (`catalogue.is_worktree_base`): non-empty, at most 255 bytes, not
    /// starting with a dash, and no space or control character. An empty base is
    /// fine here, since it means `HEAD`.
    public static func problem(withBase base: String) -> String? {
        let text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.utf8.count > 255 { return "That base is too long. Use a branch, tag or commit name." }
        if text.hasPrefix("-") { return "A base cannot start with a dash." }
        // The daemon refuses code points up to 32 (space and the controls) and 127.
        if text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }) {
            return "A base cannot hold a space or a control character. Use a branch, tag or commit name."
        }
        return nil
    }

    /// The daemon's refusal of a folder that is not the top of a primary
    /// checkout: a subfolder, a bare repository, a linked worktree, or no
    /// repository at all.
    public static let notARepository = "A worktree needs the top folder of a Git repository. Choose that folder, or start without a worktree."

    /// Whether a folder on this Mac can hold a worktree: the top of a primary
    /// checkout is a folder with a `.git` directory. The daemon decides again
    /// after canonicalizing, so this only spares a person the round trip.
    public static func judge(folder: String) -> String? {
        var isDirectory: ObjCBool = false
        let git = (folder as NSString).appendingPathComponent(".git")
        let exists = FileManager.default.fileExists(atPath: git, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? nil : notARepository
    }

    /// Said when the daemon created the session but did not report a worktree,
    /// which is how a daemon from before the feature answers: it ignores a key
    /// it does not know and starts the session in the folder.
    public static let daemonTooOld = "This daemon is too old to start a session in its own worktree, so no session was started. Update the daemon, or start without a worktree."
}

/// A creation that asked for a worktree and was answered without one. The
/// session exists in the daemon's catalogue but was never opened, so the caller
/// removes it rather than let it run in the folder.
public struct WorktreeNotHonoured: Error, LocalizedError, Sendable, Equatable {
    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    public var errorDescription: String? { WorktreeWords.daemonTooOld }
}

extension SessionRecord {
    /// The folder and, for a session in its own worktree, the branch it works
    /// on, as the session page's header says them. `liveBranch` is what the
    /// session's own Git observation reports, which covers a session that was
    /// not started with a worktree.
    public func placeLine(liveBranch: String?) -> String {
        if let worktree { return "\(workspaceName) · worktree \(worktree.branch)" }
        return [workspaceName, liveBranch].compactMap { $0 }.joined(separator: " · ")
    }

    /// The sidebar row's tooltip for a session in its own worktree.
    public var worktreeHelp: String? {
        worktree.map { "Works in its own worktree on branch \($0.branch), started from \($0.base)" }
    }
}
