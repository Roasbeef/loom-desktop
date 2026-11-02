import Foundation

/// A schedule that fires text into a strand on a timer (protocol section 5.5).
/// Every field is model or configuration text, so the views draw it as text.
public struct ScheduleRow: Sendable, Equatable, Identifiable {
    public let name: String
    public let target: String
    public let owner: String
    /// The server's own rendering of the timing. It is displayed, never parsed.
    public let when: String
    public let wake: Bool
    public let fired: Int
    public let body: String
    public var id: String { "\(target)/\(name)" }

    /// An operator's `[[schedule]]` table is edited in the configuration file,
    /// so retiring it from here would be refused.
    public var isOperator: Bool { owner == "operator" }

    public static func list(_ snapshot: JSONValue?) -> [ScheduleRow]? {
        guard let rows = snapshot?["schedules"]?.array else { return nil }
        return rows.compactMap { row in
            guard let name = row["name"]?.string, let target = row["target"]?.string else { return nil }
            return ScheduleRow(
                name: name,
                target: target,
                owner: row["owner"]?.string ?? "",
                when: row["when"]?.string ?? "",
                wake: row["wake"]?.bool ?? false,
                fired: row["fired"]?.int ?? 0,
                body: row["body"]?.string ?? ""
            )
        }
    }
}

/// The background jobs a strand has running (protocol section 4.9.19). The
/// board is an observation as of `observedMs`, not a live feed, so every age is
/// measured against that stamp and the view says it is at the last refresh.
public struct JobsBoard: Sendable, Equatable {
    public struct Job: Sendable, Equatable, Identifiable {
        public let id: String
        public let state: String
        public let startedBy: String
        public let command: String
        public let ageMs: Int
        public let deadlineMs: Int
    }

    public let strand: String
    public let observedMs: Int
    public let jobs: [Job]
    public let total: Int
    public let omitted: Int

    public init?(_ board: JSONValue?) {
        guard let board, let strand = board["strand"]?.string, let rows = board["jobs"]?.array else { return nil }
        self.strand = strand
        observedMs = board["observed_at_ms"]?.int ?? 0
        total = board["total"]?.int ?? rows.count
        omitted = board["omitted"]?.int ?? 0
        jobs = rows.compactMap { row in
            guard let id = row["id"]?.string else { return nil }
            return Job(
                id: id,
                state: row["state"]?.string ?? "",
                startedBy: row["started_by"]?.string ?? "",
                command: row["command_excerpt"]?.string ?? "",
                ageMs: row["age_ms"]?.int ?? 0,
                deadlineMs: row["deadline_ms"]?.int ?? 0
            )
        }
    }

    /// When the job's wall falls, relative to the observation.
    public func deadline(_ job: Job) -> String {
        job.deadlineMs >= observedMs
            ? "deadline in \(PanelWords.age(milliseconds: job.deadlineMs - observedMs))"
            : "deadline passed \(PanelWords.age(milliseconds: observedMs - job.deadlineMs)) ago"
    }
}

/// The attachment-private side question and its answers (protocol section 4.9.31).
public struct SideBoard: Sendable, Equatable {
    public struct Exchange: Sendable, Equatable, Identifiable {
        public let question: String
        public let answer: String
        public var id: String { question + "\u{1}" + answer }
    }

    public let strand: String
    public let status: String
    public let notice: String
    public let model: String
    public let exchanges: [Exchange]

    public init?(_ board: JSONValue?) {
        guard let board, let status = board["status"]?.string else { return nil }
        strand = board["strand"]?.string ?? ""
        self.status = status
        notice = board["notice"]?.string ?? ""
        model = board["model"]?.string ?? ""
        exchanges = (board["exchanges"]?.array ?? []).map {
            Exchange(question: $0["question"]?.string ?? "", answer: $0["answer"]?.string ?? "")
        }
    }

    /// A running answer is polled until it settles.
    public var isRunning: Bool { status == "running" }
}

/// What the daemon remembers for the workspace and what each run receives of it
/// (protocol section 4.9.33).
public struct MemoryBoard: Sendable, Equatable {
    public struct Receives: Sendable, Equatable, Identifiable {
        public let file: String
        public let state: String
        public let bytes: Int
        public var id: String { file }
    }

    public struct Note: Sendable, Equatable, Identifiable {
        public let kind: String
        public let date: String
        public let title: String
        public let description: String
        public var id: String { date + kind + title }
    }

    public struct Rule: Sendable, Equatable, Identifiable {
        public let id: String
        public let approved: String
        public let line: String
    }

    public let inject: String
    public let receives: [Receives]
    public let notes: [Note]
    public let notesTotal: Int
    public let notesAvailable: Bool
    public let rules: [Rule]
    public let rulesTotal: Int
    public let rulesAvailable: Bool
    public let pendingProposals: Int?

    public init?(_ board: JSONValue?) {
        guard let board, let inject = board["inject"]?.string else { return nil }
        self.inject = inject
        receives = (board["receives"]?.array ?? []).compactMap { row in
            guard let file = row["file"]?.string else { return nil }
            return Receives(file: file, state: row["state"]?.string ?? "", bytes: row["bytes"]?.int ?? 0)
        }
        let notes = board["notes"]
        notesAvailable = notes?["state"]?.string == "ok"
        notesTotal = notes?["total"]?.int ?? 0
        self.notes = (notes?["rows"]?.array ?? []).map {
            Note(
                kind: $0["kind"]?.string ?? "",
                date: $0["date"]?.string ?? "",
                title: $0["title"]?.string ?? "",
                description: $0["description"]?.string ?? ""
            )
        }
        let rules = board["rules"]
        rulesAvailable = rules?["state"]?.string == "ok"
        rulesTotal = rules?["total"]?.int ?? 0
        self.rules = (rules?["rows"]?.array ?? []).compactMap { row in
            guard let id = row["id"]?.string else { return nil }
            return Rule(id: id, approved: row["approved"]?.string ?? "", line: row["line"]?.string ?? "")
        }
        let proposals = board["proposals"]
        pendingProposals = proposals?["state"]?.string == "ok" ? proposals?["pending"]?.int : nil
    }
}

/// Spend by children that ran on another orchestrator. Their tokens were spent
/// where this session's context cannot see them, so each orchestrator is its own
/// row, named from configuration and drawn as text.
public struct RemoteUsage: Sendable, Equatable, Identifiable {
    public let orchestrator: String
    public let input: Int
    public let output: Int
    public var id: String { orchestrator }

    public static func list(_ metadata: JSONValue) -> [RemoteUsage] {
        (metadata["remote_usage"]?.array ?? []).compactMap { row in
            guard let name = row["orchestrator"]?.string, !name.isEmpty else { return nil }
            return RemoteUsage(orchestrator: name, input: row["input"]?.int ?? 0, output: row["output"]?.int ?? 0)
        }
    }

    /// `studio in 12.0k out 3.4k`.
    public var words: String {
        "\(PanelWords.oneLine(orchestrator)) in \(PanelWords.count(input)) out \(PanelWords.count(output))"
    }
}
