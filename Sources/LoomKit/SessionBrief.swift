import Foundation

// A bounded account of one running session's recent work, from `session.brief`
// (loom protocol-change/125). It is a read for the inbox's reading pane. The
// decoder is total, as the ones in `AttentionFeed.swift` are.

/// Text that a model or another session wrote.
///
/// It is a type of its own so that a view cannot draw it by accident as though it
/// were the app's own words: the daemon marks each such text `"trust":"untrusted"`,
/// and the reading pane draws it with `Text(verbatim:)` under a label that says
/// whose words they are. It is never parsed as markup and never used as a key, a
/// path or a URL.
public struct UntrustedText: Sendable, Equatable, Hashable {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }
}

/// The assistant's latest text, which may belong to a turn that is still running.
public struct BriefAssistant: Sendable, Equatable {
    public let text: UntrustedText
    public let at: Int
}

/// One recent tool step.
public struct BriefStep: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        case running, succeeded, failed
    }

    public let at: Int
    /// The name the model gave the call. Model text.
    public let tool: UntrustedText
    /// The step as one line, such as `Ran make check-core`. Model-influenced text.
    public let words: UntrustedText
    /// What the result envelope reported, and no claim about what a command meant.
    public let outcome: Outcome
}

/// One strand of the session and what it is doing.
public struct BriefStrand: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable, Equatable {
        case working, idle
        /// Nothing is running and the last run failed.
        case stopped
    }

    public let name: String
    public let state: State
    /// When it last changed state; absent when there is nothing to read.
    public let since: Int?
    public var id: String { name }
}

/// The session's goal and what it has spent. Both words are the operator's.
public struct BriefGoal: Sendable, Equatable {
    public let objective: String
    /// `active`, `paused`, `limited` or `complete`.
    public let status: String
    public let tokensUsed: Int
    public let tokenBudget: Int
}

/// One peer message the session received.
public struct BriefPeer: Sendable, Equatable {
    public let session: String
    public let strand: String
    public let at: Int
    public let text: UntrustedText
}

/// The last shell command the main strand ran and how it ended. It is worded as a
/// fact, "last command: X, exit N", and never as the result of a check.
public struct BriefCommand: Sendable, Equatable {
    public let command: UntrustedText
    public let exit: Int
    public let at: Int
}

/// One session's brief. Each section is omitted by the daemon when it has nothing,
/// and a damaged section reads as absent while the others are kept.
public struct SessionBrief: Sendable, Equatable {
    public let assistant: BriefAssistant?
    public let steps: [BriefStep]
    public let strands: [BriefStrand]
    public let goal: BriefGoal?
    public let peers: [BriefPeer]
    public let command: BriefCommand?

    init?(_ body: JSONValue) {
        guard let brief = body["brief"], brief.members != nil else { return nil }
        assistant = brief["assistant"].flatMap { value in
            guard let text = value["text"]?.string, let at = value["at"]?.natural else { return nil }
            return BriefAssistant(text: UntrustedText(text), at: at)
        }
        steps = (brief["steps"]?.array ?? []).compactMap { value in
            guard let at = value["at"]?.natural, let tool = value["tool"]?.string, let words = value["words"]?.string,
                  let outcome = value["outcome"]?.string.flatMap(BriefStep.Outcome.init(rawValue:))
            else { return nil }
            return BriefStep(at: at, tool: UntrustedText(tool), words: UntrustedText(words), outcome: outcome)
        }
        strands = (brief["strands"]?.array ?? []).compactMap { value in
            guard let name = value["name"]?.string, let state = value["state"]?.string.flatMap(BriefStrand.State.init(rawValue:))
            else { return nil }
            return BriefStrand(name: name, state: state, since: value["since"]?.natural)
        }
        goal = brief["goal"].flatMap { value in
            guard let objective = value["objective"]?.string, let status = value["status"]?.string,
                  let used = value["tokens_used"]?.natural, let budget = value["token_budget"]?.natural
            else { return nil }
            return BriefGoal(objective: objective, status: status, tokensUsed: used, tokenBudget: budget)
        }
        peers = (brief["peers"]?.array ?? []).compactMap { value in
            guard let session = value["session"]?.string, let strand = value["strand"]?.string,
                  let at = value["at"]?.natural, let text = value["text"]?.string
            else { return nil }
            return BriefPeer(session: session, strand: strand, at: at, text: UntrustedText(text))
        }
        command = brief["command"].flatMap { value in
            // The exit status is a whole number the result reported, and anything
            // else is no command.
            guard let command = value["command"]?.string, case .int(let exit)? = value["exit"],
                  let at = value["at"]?.natural
            else { return nil }
            return BriefCommand(command: UntrustedText(command), exit: Int(exit), at: at)
        }
    }
}
