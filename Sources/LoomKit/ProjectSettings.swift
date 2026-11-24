import Foundation

// What a person does to set a project up and to give it work (loom
// docs/client-protocol.md section 3.32): `projects.create` makes the project for a
// workspace, `projects.propose` reads its repository and suggests a check and a
// setup (it runs nothing), `projects.settings` reads the settings in force and
// `projects.set_settings` changes them, and `projects.post` adds a request to the
// router from the composer. The decoders are total, as `ProjectBoard.swift`'s are,
// and every string is external text made safe once.

/// The reply of `projects.create`.
public struct ProjectCreated: Sendable, Equatable {
    public let project: String
    public let workspace: String
    public let routerSession: String?

    init?(_ value: JSONValue) {
        guard let project = value["project"]?.string, !project.isEmpty else { return nil }
        self.project = project
        workspace = ProjectText.safe(value["workspace"]?.string ?? "", limit: 1024)
        routerSession = value["router_session"]?.string
    }
}

/// The reply of `projects.post`.
public struct ProjectPostReceipt: Sendable, Equatable {
    public let trigger: String
    /// True when the same request id was posted before and this changed nothing.
    public let isRepeat: Bool

    init?(_ value: JSONValue) {
        guard let trigger = value["trigger"]?.string else { return nil }
        self.trigger = trigger
        isRepeat = value["repeated"]?.bool ?? false
    }
}

/// Where a setting's value in force comes from.
public enum ProjectSettingSource: Sendable, Equatable {
    /// The project holds it.
    case project
    /// `[project]` in the daemon's configuration sets it.
    case file
    /// Nobody set it and the default holds.
    case unset
    /// A source this client does not know, kept as text.
    case unknown(String)

    init(word: String) {
        switch word {
        case "project": self = .project
        case "file": self = .file
        case "default": self = .unset
        default: self = .unknown(ProjectText.safe(word, limit: 32))
        }
    }
}

/// One key of the settings in force.
public struct ProjectSetting: Sendable, Equatable {
    public let key: String
    /// The words in force: one for a command, the mode or the count, any number for
    /// `protected_paths`, and none for a `check` or `setup` that nobody set.
    public let value: [String]
    public let source: ProjectSettingSource
    public let changedBy: String?
    public let changedMs: Int?

    init?(_ value: JSONValue) {
        guard let key = value["key"]?.string else { return nil }
        self.key = key
        self.value = (value["value"]?.array ?? []).compactMap { $0.string.map { ProjectText.safe($0, limit: 4096) } }
        source = ProjectSettingSource(word: value["source"]?.string ?? "")
        changedBy = value["changed_by"]?.string.map { ProjectText.safe($0, limit: 128) }
        changedMs = value["changed_ms"]?.natural
    }
}

/// The reply of `projects.settings` and of `projects.set_settings`.
public struct ProjectSettings: Sendable, Equatable {
    public let project: String
    /// The number of changes the project has had. A write names the one it read.
    public let revision: Int
    /// Where a published branch would go, or nil when the project has no remote.
    public let publishURL: String?
    public let settings: [ProjectSetting]

    public init?(_ value: JSONValue) {
        guard let project = value["project"]?.string, let revision = value["revision"]?.natural else { return nil }
        self.project = project
        self.revision = revision
        publishURL = value["publish_url"]?.string.map { ProjectText.safe($0, limit: 2048) }
        settings = (value["settings"]?.array ?? []).compactMap(ProjectSetting.init)
    }

    /// The setting for `key`, if the daemon sent it.
    public func setting(_ key: String) -> ProjectSetting? { settings.first { $0.key == key } }
}

/// One command the proposal suggests, and the marker it came from.
public struct ProposedCommand: Sendable, Equatable {
    public let command: String
    public let because: String

    init?(_ value: JSONValue?) {
        guard let value, let command = value["command"]?.string else { return nil }
        self.command = ProjectText.safe(command, limit: 4096)
        because = ProjectText.safe(value["because"]?.string ?? "", limit: 400)
    }
}

/// The reply of `projects.propose`. Nothing is applied: a client shows it and sends
/// `projects.set_settings` when the person confirms.
public struct ProjectProposal: Sendable, Equatable {
    public let project: String
    public let check: ProposedCommand?
    public let setup: ProposedCommand?
    /// Marker files that were present and not read.
    public let notes: [String]

    public init?(_ value: JSONValue) {
        guard let project = value["project"]?.string else { return nil }
        self.project = project
        check = ProposedCommand(value["check"])
        setup = ProposedCommand(value["setup"])
        notes = (value["notes"]?.array ?? []).compactMap { $0.string.map { ProjectText.safe($0, limit: 400) } }
    }
}

/// One key to change. A nil value gives the key back to the configuration file.
public struct SettingChange: Sendable, Equatable {
    public let key: String
    public let value: [String]?

    public init(key: String, value: [String]?) {
        self.key = key
        self.value = value
    }

    var json: JSONValue {
        ["key": .string(key), "value": value.map { .array($0.map { .string($0) }) } ?? .null]
    }
}

extension ControlClient {
    /// Makes the project for a workspace on the daemon's machine. The id is a
    /// function of the canonical workspace, so creating twice answers the first.
    public func createProject(workspace: String, name: String) async throws -> ProjectCreated {
        let body = try await request("projects.create", body: ["workspace": .string(workspace), "name": .string(name)])
        guard let made = ProjectCreated(body) else { throw LoomError.protocolViolation("projects.create returned no project") }
        return made
    }

    /// Adds a request to the project from the composer. Posting a request id again
    /// changes nothing and answers `isRepeat`.
    public func postToProject(_ project: String, requestID: String, text: String) async throws -> ProjectPostReceipt {
        let body = try await request("projects.post", body: [
            "project": .string(project), "request_id": .string(requestID), "text": .string(text),
        ])
        guard let receipt = ProjectPostReceipt(body) else { throw LoomError.protocolViolation("projects.post returned no trigger") }
        return receipt
    }

    /// The settings in force for a project.
    public func projectSettings(_ project: String) async throws -> ProjectSettings {
        let body = try await request("projects.settings", body: ["project": .string(project)])
        guard let settings = ProjectSettings(body) else { throw LoomError.protocolViolation("projects.settings returned no settings") }
        return settings
    }

    /// Changes keys at the revision read. An older revision is refused `conflict` and
    /// nothing is written. Turning `publish` on needs `publishTo` to equal the
    /// `publish_url` the read showed. The reply is the settings now in force.
    public func setProjectSettings(
        _ project: String, revision: Int, changes: [SettingChange], publishTo: String? = nil
    ) async throws -> ProjectSettings {
        var fields: [String: JSONValue] = [
            "project": .string(project), "revision": .int(Int64(revision)), "changes": .array(changes.map(\.json)),
        ]
        if let publishTo { fields["publish_to"] = .string(publishTo) }
        let body = try await request("projects.set_settings", body: .object(fields))
        guard let settings = ProjectSettings(body) else { throw LoomError.protocolViolation("projects.set_settings returned no settings") }
        return settings
    }

    /// Reads the project's repository and suggests a check and a setup. It runs nothing.
    public func proposeProject(_ project: String) async throws -> ProjectProposal {
        let body = try await request("projects.propose", body: ["project": .string(project)])
        guard let proposal = ProjectProposal(body) else { throw LoomError.protocolViolation("projects.propose returned no proposal") }
        return proposal
    }
}
