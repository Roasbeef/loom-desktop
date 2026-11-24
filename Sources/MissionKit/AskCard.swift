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

    /// The ids of the blocks the transcript marks with "Ask": for each turn that
    /// called `ask`, the last message the strand wrote outside the turn's fold, or the
    /// fold itself when the turn wrote none. A model usually writes its question
    /// before it calls the tool, and that prose is folded as narration, so the fold is
    /// the common case.
    public static func askingBlocks(in blocks: [TranscriptBlock]) -> Set<String> {
        var marked: Set<String> = []
        var turn: [TranscriptBlock] = []

        func close() {
            defer { turn = [] }
            guard turn.contains(where: Self.callsAsk) else { return }
            let message = turn.last { block in
                if case .row(let row) = block, case .assistant = row.kind { return true }
                return false
            }
            if let message {
                marked.insert(message.id)
            } else if let fold = turn.first(where: { if case .fold = $0 { return true }; return false }) {
                marked.insert(fold.id)
            }
        }
        for block in blocks {
            if case .row(let row) = block, row.kind.opensTurn { close() } else { turn.append(block) }
        }
        close()
        return marked
    }

    private static func callsAsk(_ block: TranscriptBlock) -> Bool {
        func isAsk(_ row: TranscriptRow) -> Bool {
            if case .tool(let name, _, _, _) = row.kind { return name == "ask" }
            return false
        }
        switch block {
        case .row(let row): return isAsk(row)
        case .fold(let fold): return fold.rows.contains(where: isAsk)
        }
    }
}
