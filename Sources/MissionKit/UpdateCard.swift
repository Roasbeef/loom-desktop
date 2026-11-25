import Foundation
import LoomKit

// The cards the inbox draws for its Updates group, and the board that lays them out
// side by side. An update is a session that is working and asks nothing of the
// owner, so the card says what it is doing now: the state and how long it has been in
// the turn, the agent's latest message, the step it is on, and one line of what is
// around it (its strands, a failed command, the machine it runs on).
//
// The rule is pure. It reads no clock and draws nothing: the caller hands it the
// time, the row, the activity the daemon streams for every resident session, and the
// digest of the last brief read, so a test states every card with fixed inputs.
//
// ## Flow
//
// `UpdateDigest` keeps the part of a `session.brief` a card draws, cut to
// `maxSteps` steps. `UpdateWatch.targets` picks which sessions the app reads a brief
// for, at most `readCap` of them and the ones never read first. `UpdateCard.make`
// puts a row, its activity and its digest into one card. `UpdateBoard.order` keeps
// the board's cards where they were when the set changes.
//
// ## Why the reads are bounded
//
// The daemon allows six `session.brief` reads in four seconds for a credential, and
// the open thread's pane reads one too. The app reads one brief at a time, one every
// `UpdateWatch.gapMs`, over at most `readCap` sessions, so the cards add under one
// read each 1.5 s whatever the number of sessions, and a session past the cap is
// drawn from the activity alone.

/// What a card keeps of one session's brief: the last few steps, the strands, the
/// last command and the agent's latest message. The brief holds more (peer messages,
/// the goal), which a card never draws, so none of it is kept.
public struct UpdateDigest: Sendable, Equatable {
    /// The most steps a digest holds, which is what the expanded card and the board
    /// draw. A compact card draws `UpdateCard.compactSteps` of them.
    public static let maxSteps = 5

    public let assistant: BriefAssistant?
    /// The last steps, oldest first.
    public let steps: [BriefStep]
    public let strands: [BriefStrand]
    public let command: BriefCommand?

    public init(brief: SessionBrief) {
        assistant = brief.assistant
        steps = Array(brief.steps.suffix(Self.maxSteps))
        strands = brief.strands
        command = brief.command
    }

    init(assistant: BriefAssistant?, steps: [BriefStep], strands: [BriefStrand], command: BriefCommand?) {
        self.assistant = assistant
        self.steps = Array(steps.suffix(Self.maxSteps))
        self.strands = strands
        self.command = command
    }
}

/// Which sessions the app reads a brief for, and how fast.
public enum UpdateWatch {
    /// The most sessions read. Rows past it are drawn from the streamed activity.
    public static let readCap = 8
    /// The wait between two reads, in milliseconds.
    public static let gapMs = 1_500

    /// The wait after each read when `count` sessions are read in turn: the gap, or
    /// longer for few sessions, so one session is read about every six seconds and
    /// not every gap.
    public static func pause(count: Int) -> Int { max(gapMs, 6_000 / max(count, 1)) }

    /// The sessions to read, in the order to read them: those with no digest yet
    /// first, then the rest in list order, cut to `readCap`.
    public static func targets(rows: [InboxRow], held: Set<String>) -> [String] {
        var seen: Set<String> = []
        let ids = rows.filter { $0.group == .updates && !$0.isTicket }.map(\.sessionID).filter { seen.insert($0).inserted }
        let capped = Array(ids.prefix(readCap))
        return capped.filter { !held.contains($0) } + capped.filter { held.contains($0) }
    }
}

/// One step as a card draws it.
public struct UpdateStepLine: Sendable, Equatable {
    public let tool: String
    public let words: String
    public let outcome: BriefStep.Outcome
    public let at: Int
}

/// One strand of the expanded card, with what the activity's glance says of it.
public struct UpdateStrandLine: Sendable, Equatable {
    public let name: String
    public let state: String
    public let glance: String?
}

/// One card.
public struct UpdateCard: Sendable, Equatable, Identifiable {
    /// How many steps a compact card holds. The expanded card holds `maxSteps`.
    public static let compactSteps = 3

    public var id: String
    public let sessionID: String
    public let name: String
    /// `working · 2 min into a turn`.
    public let state: String
    /// The agent's latest message, which is model text.
    public let message: String?
    public let messageAt: Int?
    /// The step the session is on: the running one, else the last.
    public let step: UpdateStepLine?
    /// The last steps, oldest first.
    public let steps: [UpdateStepLine]
    /// `2 strands · advisor idle`, or nil when the session has only main.
    public let strandsLine: String?
    public let strands: [UpdateStrandLine]
    /// The last command and its exit, as the brief reports them.
    public let command: String?
    public let commandExit: Int?
    /// `last command failed, exit 2`, only for a failed command.
    public let failure: String?
    /// Where the session runs, only when it is not on the machine the app talks to.
    public let machine: String?
    /// When the session last did something, for ordering the board.
    public let lastActivity: Int

    public static func make(
        row: InboxRow, activity: SessionActivity?, digest: UpdateDigest?, machine: String?, now: Int
    ) -> UpdateCard {
        let lines = (digest?.steps ?? []).map {
            UpdateStepLine(tool: $0.tool.text, words: InboxRule.oneLine($0.words.text), outcome: $0.outcome, at: $0.at)
        }
        let current = lines.last { $0.outcome == .running } ?? lines.last

        // The brief's latest text may belong to the turn still running, so it is
        // preferred over the activity's last finished message.
        let briefText = digest?.assistant.flatMap { $0.text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let message = briefText?.text.text ?? activity.flatMap(InboxRule.said)
        let messageAt = briefText?.at ?? activity?.lastMessageAt

        let delegates = (digest?.strands ?? []).filter { $0.name != "main" }
        let glances = activity?.glances ?? []
        let strands: [UpdateStrandLine] = delegates.map { strand in
            UpdateStrandLine(
                name: strand.name, state: strand.state.rawValue,
                glance: glances.first { $0.strand == strand.name }.map(\.summary).flatMap { $0.isEmpty ? nil : InboxRule.oneLine($0) }
            )
        }
        let others = glances.filter { $0.strand != "main" }
        var strandsLine: String?
        if let first = delegates.first {
            strandsLine = "\(delegates.count + 1) strands \u{00B7} \(first.name) \(first.state.rawValue)"
        } else if let first = others.first {
            strandsLine = "\(others.count + 1) strands \u{00B7} \(first.title)"
        }

        let exit = digest?.command?.exit
        let command = digest?.command.map { InboxRule.oneLine($0.command.text) }
        let failure = exit.flatMap { $0 == 0 ? nil : "last command failed, exit \($0)" }

        let stamps = [messageAt, row.since, lines.last?.at].compactMap { $0 }
        return UpdateCard(
            id: row.id, sessionID: row.sessionID, name: row.name,
            state: stateWords(row: row, now: now), message: message, messageAt: messageAt,
            step: current, steps: Array(lines.suffix(UpdateDigest.maxSteps)),
            strandsLine: strandsLine, strands: strands, command: command, commandExit: exit, failure: failure,
            machine: machine, lastActivity: stamps.max() ?? 0
        )
    }

    /// The steps a compact card draws: the last `compactSteps`.
    public var compact: [UpdateStepLine] { Array(steps.suffix(Self.compactSteps)) }

    /// `working · 2 min into a turn` for a working row, and `waiting 1m` for any
    /// other row that carries an age.
    static func stateWords(row: InboxRow, now: Int) -> String {
        if row.kind == .working {
            return "working \u{00B7} " + (row.since.map { ThreadRule.turnWords(started: $0, now: now) } ?? "no turn open")
        }
        return row.age.map { "waiting \($0.words)" } ?? "waiting"
    }
}

/// The board's order. A card keeps its place while its session stays in Updates, so
/// a card never moves under the cursor. A session new to the board goes last, and the
/// first order is the most recently active first.
public enum UpdateBoard {
    public static func order(previous: [String], cards: [UpdateCard]) -> [String] {
        let present = Set(cards.map(\.id))
        let kept = previous.filter(present.contains)
        let fresh = cards.filter { !kept.contains($0.id) }.sorted { $0.lastActivity > $1.lastActivity }.map(\.id)
        return kept + fresh
    }
}
