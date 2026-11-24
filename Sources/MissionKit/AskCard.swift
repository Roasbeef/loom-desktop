import Foundation
import LoomKit

// The cards a session page draws above its composer for the asks that wait on the
// owner, and the mark the transcript puts on the turn that raised one.
//
// An ask ends the agent's turn, so the owner has to see it where they read and type.
// It used to live only in the Inbox and in the Inspector's rail, which starts hidden,
// and an owner who never opened either answered the agent's silence by typing
// "continue". The card is drawn whether or not the Inspector is open.
//
// The rule is pure: it reads the session's feed row and the transcript's blocks, and
// draws nothing. What the card's form accepts is `AnswerRule`, and whether it is
// offered at all (answered, observer, older daemon) is `AnswerRule.offer`, which the
// card's view asks once it has read the record.
//
// ## Flow
//
// `AskCardRule.cards` lists the open asks of the feed row, oldest first, and
// `AskCardRule.header` words one card's head. `AskCardRule.askingBlocks` names the
// transcript blocks of the turns that called `ask`.

/// One open ask routed to the owner, as the card needs it before the record is read.
public struct AskCard: Sendable, Equatable, Identifiable {
    /// The ask's identity, `ask-` and ten hexadecimal digits.
    public let id: String
    /// The strand that asked.
    public let strand: String
    /// When the ask was recorded, in Unix milliseconds.
    public let since: Int
    /// The first question's prompt as the daemon cut it. Model text.
    public let head: String
    /// How many questions the ask holds.
    public let questions: Int
}

/// The cards the page draws for a session and how many open asks it leaves to the Inbox.
public struct AskShelf: Sendable, Equatable {
    public let cards: [AskCard]
    /// Open asks without a card: those past the limit and those the daemon shed from the row.
    public let more: Int

    /// "2 more in the Inbox", or nil when every open ask has a card.
    public var moreWords: String? { more > 0 ? "\(more) more in the Inbox" : nil }
}

public enum AskCardRule {
    /// The most cards a page draws. Each is as tall as its questions, so more than two
    /// outgrow the window and clip the oldest, which is the one drawn first.
    public static let shelfLimit = 2

    /// The first `shelfLimit` cards, oldest first, and the count of the rest. The
    /// section's count includes the asks the daemon shed from the row to keep it
    /// bounded, so an ask the page cannot list is still counted.
    public static func shelf(feed: AttentionRow?) -> AskShelf {
        let all = cards(feed: feed)
        let cards = Array(all.prefix(shelfLimit))
        return AskShelf(cards: cards, more: max(feed?.asks.count ?? 0, all.count) - cards.count)
    }

    /// The asks the feed row holds, longest waiting first and ending in the identity
    /// so the same row in any order gives the same cards. A session whose feed was
    /// not read has none, and an ask that was answered or closed has left the feed,
    /// so it has no card either.
    public static func cards(feed: AttentionRow?) -> [AskCard] {
        (feed?.asks.items ?? [])
            .map { AskCard(id: $0.id, strand: $0.strand, since: $0.createdAt, head: $0.head, questions: $0.questions) }
            .sorted { lhs, rhs in lhs.since == rhs.since ? lhs.id < rhs.id : lhs.since < rhs.since }
    }

    /// The card's head, "Ask · waiting since 13:40 · main". `strand` is the name the
    /// page draws for the asking strand.
    public static func header(_ card: AskCard, strand: String, clock: (Int) -> String = ClockTime.local) -> String {
        "Ask \u{00B7} waiting since \(clock(card.since)) \u{00B7} \(strand)"
    }

    /// The ids of the blocks the transcript marks with "Ask": for each turn that asked
    /// the owner, the last message the strand wrote before the call outside the turn's
    /// fold, or the fold that holds the call. A model usually writes its question
    /// before it calls the tool, and `TranscriptBlock.group` folds that prose as
    /// narration, so the fold is the common case. A message after the call is the
    /// turn's summary and is never marked, nor is a turn that asked a strand.
    public static func askingBlocks(in blocks: [TranscriptBlock]) -> Set<String> {
        var marked: Set<String> = []
        var turn: [TranscriptBlock] = []

        func close() {
            defer { turn = [] }
            guard let asked = turn.firstIndex(where: Self.asksOwner) else { return }
            let before = turn[..<asked].last { block in
                if case .row(let row) = block, case .assistant = row.kind { return true }
                return false
            }
            marked.insert((before ?? turn[asked]).id)
        }
        for block in blocks {
            if case .row(let row) = block, row.kind.opensTurn { close() } else { turn.append(block) }
        }
        close()
        return marked
    }

    /// Whether the block holds a call that puts a question to the owner: the `ask`
    /// tool with no `to`, or a `code_mode` program whose source calls `attention.ask`.
    /// A program's routing is an argument inside its source, which is not read, so a
    /// program that asks a strand is marked too. Every tool row is inside a fold,
    /// since a turn with a tool call always has work to fold, so a bare row is never
    /// one.
    private static func asksOwner(_ block: TranscriptBlock) -> Bool {
        func isOwnerAsk(_ row: TranscriptRow) -> Bool {
            guard case .tool(let name, let arguments, _, _) = row.kind else { return false }
            switch name {
            case "ask": return arguments["to"] == nil || arguments["to"] == .null
            case "code_mode": return arguments["program"]?.string?.contains("attention.ask(") == true
            default: return false
            }
        }
        guard case .fold(let fold) = block else { return false }
        return fold.rows.contains(where: isOwnerAsk)
    }
}
