import Foundation

/// A strand's todo board, as the `todo` tool leaves it (`core/todo_list`).
///
/// Every successful `todo` call settles with the landed board in its result's
/// `details.todo`, so the newest such result on a strand's chain is its board.
/// The same board is also stored as the `todo` note, which lets a client that
/// attached after the last call, with the call outside its window, still draw
/// it. The decoder is total: anything that is not a board is nil, never a
/// partial board.
public struct TodoBoard: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case pending, active, done, dropped
        case blocked(reason: String?)

        /// A closed task is no longer ahead of the agent.
        public var isClosed: Bool {
            switch self {
            case .done, .dropped: return true
            case .pending, .active, .blocked: return false
            }
        }

        public var word: String {
            switch self {
            case .pending: return "pending"
            case .active: return "active"
            case .done: return "done"
            case .dropped: return "dropped"
            case .blocked: return "blocked"
            }
        }
    }

    public struct Task: Sendable, Equatable, Identifiable {
        public let text: String
        public let status: Status
        /// A task's text is its identity on the board, which the tool enforces.
        public var id: String { text }
    }

    public struct Phase: Sendable, Equatable, Identifiable {
        public let name: String
        public let tasks: [Task]
        public var id: String { name }

        /// Closed tasks and total tasks in this phase.
        public var tally: (closed: Int, total: Int) {
            (tasks.filter(\.status.isClosed).count, tasks.count)
        }
    }

    public let phases: [Phase]

    public init?(_ value: JSONValue?) {
        guard let rows = value?["phases"]?.array else { return nil }
        var phases: [Phase] = []
        for row in rows {
            guard let name = row["name"]?.string, let tasks = row["tasks"]?.array else { return nil }
            var decoded: [Task] = []
            for task in tasks {
                guard let text = task["text"]?.string, let word = task["status"]?.string else { return nil }
                let status: Status
                switch word {
                case "pending": status = .pending
                case "active": status = .active
                case "done": status = .done
                case "dropped": status = .dropped
                case "blocked": status = .blocked(reason: task["reason"]?.string)
                default: return nil
                }
                decoded.append(Task(text: text, status: status))
            }
            phases.append(Phase(name: name, tasks: decoded))
        }
        self.phases = phases
    }

    /// The board a `todo` tool result carries, or nil for any other message.
    /// A failed call leaves the board where it was, so an error result carries
    /// nothing here even when it has details.
    public static func from(toolResult message: JSONValue?) -> TodoBoard? {
        guard
            message?["role"]?.string == "toolResult",
            message?["toolName"]?.string == "todo",
            message?["isError"]?.bool != true
        else { return nil }
        return TodoBoard(message?["details"]?["todo"])
    }

    /// The board in a `todo` note's text, which is the board's JSON.
    public static func from(noteText: String) -> TodoBoard? {
        guard let value = try? JSONValue.parse(Data(noteText.utf8)) else { return nil }
        return TodoBoard(value)
    }

    /// Closed and total tasks across the whole board.
    public var tally: (closed: Int, total: Int) {
        let all = phases.flatMap(\.tasks)
        return (all.filter(\.status.isClosed).count, all.count)
    }

    /// The active task with its phase, if any task is active.
    public var active: (phase: Phase, task: Task)? {
        for phase in phases {
            if let task = phase.tasks.first(where: { $0.status == .active }) { return (phase, task) }
        }
        return nil
    }

    /// The phase a reader looks at first: the one holding the active task,
    /// else the first with open work, else the last phase.
    public var focus: Phase? {
        if let active { return active.phase }
        return phases.first { $0.tasks.contains { !$0.status.isClosed } } ?? phases.last
    }

    public var isEmpty: Bool { tally.total == 0 }

    /// `3/8 done`, the progress the transcript row and the dock both say.
    public var progress: String {
        let counts = tally
        return "\(counts.closed)/\(counts.total) done"
    }
}
