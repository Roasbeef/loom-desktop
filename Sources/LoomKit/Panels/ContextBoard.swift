import Foundation

/// What the daemon says about a strand's model window, from the `context`
/// observation (protocol section 4.9.21).
///
/// A read is asked for and answered in two steps: a reply carrying
/// `status: pending`, then a pushed snapshot with the same `request_id` that
/// is `ready` or `failed`. Only a ready board is a figure. A failed one is
/// unavailable, never zero, and `Conversation` keeps the previous ready board
/// beside the failure so a refresh does not blank the bar.
public struct ContextBoard: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let category: String
        public let name: String
        public let tokens: Int
    }

    /// One part of the window as the stacked bar draws it.
    public struct Part: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable {
            case system, tools, messages, unattributed, reserve, free
        }

        public let kind: Kind
        public let tokens: Int
        public var id: Kind { kind }

        public var name: String {
            switch kind {
            case .system: return "System prompt"
            case .tools: return "Tools"
            case .messages: return "Messages"
            case .unattributed: return "Counted by the provider, not itemised"
            case .reserve: return "Compaction reserve"
            case .free: return "Free space"
            }
        }
    }

    public let requestID: Int
    public let strand: String
    public let asOf: Int
    public let model: String
    public let window: Int
    public let used: Int
    public let basis: String
    public let compactionUsed: Int
    public let checkpointAt: Int?
    public let reserve: Int
    public let categories: [Item]
    public let items: [Item]
    public let omitted: Int

    /// What one observation said.
    public enum Reading: Sendable, Equatable {
        case pending(requestID: Int)
        case ready(ContextBoard)
        case failed(requestID: Int, message: String)
    }

    /// Reads a `context` snapshot's board. It is total: a board that is
    /// inconsistent, as `session_view/context_view.decode` defines it, is a
    /// failure and not a figure.
    public static func reading(_ board: JSONValue?) -> Reading? {
        guard let board, let id = board["request_id"]?.int else { return nil }
        switch board["status"]?.string {
        case "pending":
            return .pending(requestID: id)
        case "failed":
            return .failed(requestID: id, message: board["message"]?.string ?? "The read failed.")
        case "ready":
            if let parsed = ContextBoard(board, id: id) { return .ready(parsed) }
            return .failed(requestID: id, message: "The context observation was inconsistent.")
        default:
            return nil
        }
    }

    init?(_ board: JSONValue, id: Int) {
        guard
            let strand = board["strand"]?.string, !strand.isEmpty,
            let asOf = board["as_of"]?.int,
            let model = board["model"]?.string, !model.isEmpty,
            let window = board["context_window"]?.int, window > 0,
            let used = board["used_tokens"]?.int,
            let basis = board["basis"]?.string,
            ["estimated", "reported_plus_estimate"].contains(basis),
            let compactionUsed = board["compaction_used_tokens"]?.int,
            let reserve = board["reserve_tokens"]?.int,
            let omitted = board["items_omitted"]?.int,
            let total = board["items_total"]?.int
        else { return nil }
        let items = (board["items"]?.array ?? []).compactMap { row -> Item? in
            guard let name = row["name"]?.string, let tokens = row["tokens"]?.int else { return nil }
            return Item(category: row["category"]?.string ?? "", name: name, tokens: tokens)
        }
        guard total == items.count + omitted else { return nil }
        requestID = id
        self.strand = strand
        self.asOf = asOf
        self.model = model
        self.window = window
        self.used = used
        self.basis = basis
        self.compactionUsed = compactionUsed
        checkpointAt = board["checkpoint_at"]?.int
        self.reserve = reserve
        categories = (board["categories"]?.array ?? []).compactMap { row in
            guard let name = row["name"]?.string, let tokens = row["tokens"]?.int else { return nil }
            return Item(category: name, name: name, tokens: tokens)
        }
        self.items = items
        self.omitted = omitted
    }

    // MARK: Words

    /// Whole percent of the window in use.
    public var percent: Int { used * 100 / window }

    /// The bar's figure, worded as the terminal words it: `ctx ~41%`.
    public var footer: String { "ctx ~\(percent)%" }

    /// The headline over the breakdown.
    public var headline: String {
        "Context window ~\(PanelWords.count(used)) / \(PanelWords.count(window)) (\(percent)%)"
    }

    /// Where the headline's number comes from, in plain words.
    public var basisWords: String {
        basis == "reported_plus_estimate"
            ? "The count the model provider reported for the last request, plus an estimate for the messages added since."
            : "An estimate from the prompt, the tools and the messages; the provider has reported no count yet."
    }

    /// How much room is left before the session compacts itself. The count it
    /// is measured against is the one compaction itself uses.
    public var untilCompaction: String {
        guard let checkpointAt else { return "Automatic compaction is off." }
        return PanelWords.count(max(0, checkpointAt - compactionUsed)) + " tokens until the session compacts itself."
    }

    // MARK: The bar

    private func category(_ name: String) -> Int {
        categories.first { $0.name == name }?.tokens ?? 0
    }

    /// Cuts the window into the parts the bar draws. A category the board does
    /// not name is zero, so an older daemon's board draws a smaller bar, and
    /// free space never goes below zero because estimates can exceed the window.
    public var parts: [Part] {
        let system = category("System prompt")
        let tools = category("Tools")
        let messages = category("Messages")
        let rows = system + tools + messages
        let occupied = max(used, rows)
        return [
            Part(kind: .system, tokens: system),
            Part(kind: .tools, tokens: tools),
            Part(kind: .messages, tokens: messages),
            Part(kind: .unattributed, tokens: max(0, used - rows)),
            Part(kind: .reserve, tokens: reserve),
            Part(kind: .free, tokens: max(0, window - occupied - reserve)),
        ].filter { $0.tokens > 0 }
    }

    /// A part's share of the window in words. A part too small for a whole
    /// percent says so rather than drawing zero beside a row holding tokens.
    public func share(_ part: Part) -> String {
        let whole = part.tokens * 100 / window
        return whole == 0 ? "<1%" : "\(whole)%"
    }

    // MARK: The item list

    /// A grouped row of the inventory: a label, the tokens and how many items.
    public struct Group: Sendable, Equatable, Identifiable {
        public let label: String
        public let tokens: Int
        public let count: Int
        public var id: String { label }
    }

    /// The tool definitions the board lists, largest first.
    public var tools: [Group] {
        Self.largestFirst(items.filter { $0.category == "Tools" }.map {
            Group(label: PanelWords.oneLine($0.name), tokens: $0.tokens, count: 1)
        })
    }

    /// The messages grouped by kind, largest first. An item's name begins with
    /// its place in the conversation (`12. Assistant`), which is dropped so
    /// every assistant message falls into one row.
    public var messageKinds: [Group] {
        var groups: [String: (Int, Int)] = [:]
        for item in items where item.category == "Messages" {
            var kind = PanelWords.oneLine(item.name)
            if let dot = kind.range(of: ". "), Int(kind[..<dot.lowerBound]) != nil {
                kind = String(kind[dot.upperBound...])
            }
            let current = groups[kind] ?? (0, 0)
            groups[kind] = (current.0 + item.tokens, current.1 + 1)
        }
        return Self.largestFirst(groups.map { Group(label: $0.key, tokens: $0.value.0, count: $0.value.1) })
    }

    /// Largest first, and equal rows by name so the order does not change
    /// between two draws of the same board.
    private static func largestFirst(_ rows: [Group]) -> [Group] {
        rows.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.label < $1.label }
    }
}
