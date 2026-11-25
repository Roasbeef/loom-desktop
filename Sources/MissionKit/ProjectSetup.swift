import Foundation
import LoomKit

// The rule behind setting a project up and giving it work: what a settings form
// shows, which keys a Save sends, what turning on publishing needs, how a
// proposal prefills the form, and what a posted request is made of. It is pure.
// The daemon checks every value by the rules `loom.toml` is checked by and answers
// a refusal in the file's own words, so this rule checks only what the wire needs
// and never judges a command.
//
// ## Flow
//
// `draft` → `plan` → `refusal`
//
// 1. `draft` makes the form's fields from the settings in force, or from a
//    proposal where nothing is set yet.
// 2. `plan` compares the fields with what is in force and names only the keys
//    that differ, at most five, with the `publish_to` a publish needs.
// 3. `refusal` words the daemon's answer to a write that did not go through.

/// Whether the host may push a ticket's branch and open a pull request.
public enum PublishMode: String, Sendable, Equatable, CaseIterable {
    /// Nothing goes outward: a ticket waits for a person.
    case off
    /// The host pushes a verified commit and opens a pull request.
    case pullRequest = "pull_request"

    /// The words beside the choice.
    public var title: String {
        switch self {
        case .off: return "Off"
        case .pullRequest: return "Pull request"
        }
    }
}

/// The settings form's fields. Text is what a person typed, and an empty command
/// says none.
public struct SettingsDraft: Sendable, Equatable {
    public var check: String
    public var setup: String
    public var maxWorkers: String
    public var publish: PublishMode
    /// One literal path or `dir/**` for each line.
    public var protectedPaths: String

    public init(check: String = "", setup: String = "", maxWorkers: String = "", publish: PublishMode = .off, protectedPaths: String = "") {
        self.check = check
        self.setup = setup
        self.maxWorkers = maxWorkers
        self.publish = publish
        self.protectedPaths = protectedPaths
    }
}

/// What a Save sends.
public struct SettingsPlan: Sendable, Equatable {
    public let changes: [SettingChange]
    /// The URL a publish change confirms, which must equal the one the read showed.
    public let publishTo: String?
}

/// Why a Save was not sent.
public enum SettingsRefusal: Error, Sendable, Equatable {
    /// Publishing was turned on for a project with no remote.
    case noRemote
    /// Publishing is turned on beside other keys, which the daemon refuses whole.
    case publishAlone

    public var words: String {
        switch self {
        case .noRemote: return "This project has no remote, so there is nothing to publish to."
        case .publishAlone: return "Turning publishing on is saved on its own. Save the other settings first."
        }
    }
}

public enum ProjectSetup {
    public static let keys = ["check", "setup", "max_workers", "publish", "protected_paths"]

    // MARK: The form

    /// The fields for the settings in force.
    public static func draft(_ settings: ProjectSettings) -> SettingsDraft {
        SettingsDraft(
            check: settings.setting("check")?.value.first ?? "",
            setup: settings.setting("setup")?.value.first ?? "",
            maxWorkers: settings.setting("max_workers")?.value.first ?? "",
            publish: settings.setting("publish")?.value.first.flatMap(PublishMode.init(rawValue:)) ?? .off,
            protectedPaths: (settings.setting("protected_paths")?.value ?? []).joined(separator: "\n")
        )
    }

    /// The fields for a new project: the proposal's command for each of check and
    /// setup that nothing sets yet, and what is in force for every other field. A
    /// command already set is never overwritten by a suggestion.
    public static func draft(_ settings: ProjectSettings, proposal: ProjectProposal?) -> SettingsDraft {
        var draft = draft(settings)
        if draft.check.isEmpty, let suggested = proposal?.check { draft.check = suggested.command }
        if draft.setup.isEmpty, let suggested = proposal?.setup { draft.setup = suggested.command }
        return draft
    }

    /// Where a value in force comes from, in words.
    public static func sourceWords(_ source: ProjectSettingSource) -> String {
        switch source {
        case .project: return "set for this project"
        case .file: return "from loom.toml"
        case .unset: return "default"
        case .unknown(let word): return word
        }
    }

    /// The labelled name of a key.
    public static func title(_ key: String) -> String {
        switch key {
        case "check": return "Check"
        case "setup": return "Setup"
        case "max_workers": return "Workers at once"
        case "publish": return "Publish"
        case "protected_paths": return "Protected paths"
        default: return ProjectText.safe(key, limit: 64)
        }
    }

    /// The form after the settings were read again. A field the owner has not touched,
    /// which still holds what the last read gave, takes the new value; a field the owner
    /// changed keeps what was typed. Only the owner's own edits survive, so a save never
    /// sends back a field another writer changed in the meantime.
    public static func rebase(_ draft: SettingsDraft, from old: SettingsDraft, onto new: SettingsDraft) -> SettingsDraft {
        func field<T: Equatable>(_ keyPath: KeyPath<SettingsDraft, T>) -> T {
            draft[keyPath: keyPath] == old[keyPath: keyPath] ? new[keyPath: keyPath] : draft[keyPath: keyPath]
        }
        return SettingsDraft(
            check: field(\.check), setup: field(\.setup), maxWorkers: field(\.maxWorkers), publish: field(\.publish),
            protectedPaths: field(\.protectedPaths)
        )
    }

    // MARK: Save

    /// The lines of a protected-paths field: trimmed, and with blank lines dropped.
    public static func paths(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The keys a Save sends: only those that differ from what is in force. An empty
    /// command is sent as `nil`, which gives a key the project holds back to the
    /// file, and is not sent for a key the file or the default holds, since there is
    /// nothing to give back. A key left as it is writes nothing.
    public static func plan(_ settings: ProjectSettings, draft: SettingsDraft) -> Result<SettingsPlan, SettingsRefusal> {
        var changes: [SettingChange] = []

        func command(_ key: String, _ typed: String) {
            let now = settings.setting(key)
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                if now?.source == .project { changes.append(SettingChange(key: key, value: nil)) }
            } else if now?.value != [text] {
                changes.append(SettingChange(key: key, value: [text]))
            }
        }
        command("check", draft.check)
        command("setup", draft.setup)

        // An empty count gives back a count the project holds, as an empty command does,
        // and is nothing to send for one the file or the default holds.
        let workers = draft.maxWorkers.trimmingCharacters(in: .whitespacesAndNewlines)
        if workers.isEmpty {
            if settings.setting("max_workers")?.source == .project { changes.append(SettingChange(key: "max_workers", value: nil)) }
        } else if settings.setting("max_workers")?.value != [workers] {
            changes.append(SettingChange(key: "max_workers", value: [workers]))
        }

        let paths = paths(draft.protectedPaths)
        if paths != (settings.setting("protected_paths")?.value ?? []) {
            changes.append(SettingChange(key: "protected_paths", value: paths))
        }

        let inForce = settings.setting("publish")?.value.first.flatMap(PublishMode.init(rawValue:)) ?? .off
        var publishTo: String?
        if draft.publish != inForce {
            if draft.publish == .pullRequest {
                guard let url = settings.publishURL else { return .failure(.noRemote) }
                guard changes.isEmpty else { return .failure(.publishAlone) }
                publishTo = url
            }
            changes.append(SettingChange(key: "publish", value: [draft.publish.rawValue]))
        }
        return .success(SettingsPlan(changes: changes, publishTo: publishTo))
    }

    /// The words for a write the daemon refused. A `bad_request` carries the file's
    /// own sentence about the value, which is shown as it came.
    public static func refusal(code: String, message: String) -> String {
        switch code {
        case "conflict": return "The settings changed since they were read. They are read again; check them and save again."
        case "forbidden": return "Only the owner can change a project's settings."
        case "not_found": return "The project is gone."
        case "bad_request":
            let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return said.isEmpty || said == "request refused" ? "The daemon refused those settings." : ProjectText.safe(said, limit: 600)
        default: return "The daemon refused it (\(ProjectText.safe(code, limit: 32)))."
        }
    }

    // MARK: Creating

    /// The name a project is made with: what a person typed, else the folder's name.
    public static func projectName(typed: String, folder: String) -> String {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (folder as NSString).lastPathComponent : name
    }

    /// The words for a create the daemon refused.
    public static func createRefusal(code: String, message: String) -> String {
        switch code {
        case "forbidden": return "Only the owner can make a project."
        case "not_found": return "This daemon has project mode off."
        case "bad_request":
            let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return said.isEmpty || said == "request refused" ? "The daemon refused that folder." : ProjectText.safe(said, limit: 600)
        default: return "The daemon refused it (\(ProjectText.safe(code, limit: 32)))."
        }
    }

    /// What a proposal says, in a line for each command it suggests, or the words
    /// for a repository that suggests nothing.
    public static func proposalWords(_ proposal: ProjectProposal) -> [String] {
        var lines: [String] = []
        if let check = proposal.check { lines.append("Check: \(check.command) (\(check.because))") }
        if let setup = proposal.setup { lines.append("Setup: \(setup.command) (\(setup.because))") }
        if lines.isEmpty { lines.append("The repository suggests no check and no setup.") }
        lines += proposal.notes.map { "Present and not read: \($0)" }
        return lines
    }
}

/// A request from the composer.
public enum ProjectPost {
    /// The most characters a request carries. The daemon bounds the text itself; this
    /// keeps one paste from a request that cannot be sent.
    public static let limit = 16_000

    /// The request's text, trimmed, or nil when there is none to send or it is longer than
    /// a request may be. Text is never cut, since a request that lost its end would be
    /// posted as something the owner did not write.
    public static func text(_ typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.count > limit ? nil : text
    }

    /// Why the typed text cannot be posted, when it is too long.
    public static func problem(_ typed: String) -> String? {
        let count = typed.trimmingCharacters(in: .whitespacesAndNewlines).count
        return count > limit ? "That is \(count - limit) characters over the \(limit) a request may hold." : nil
    }

    /// A request id of at most 64 letters, digits, `_`, `-` and `.`. The same id sent
    /// again changes nothing, so one is made when a request is composed and kept
    /// until it is accepted, and a retry after a lost reply is safe.
    public static func requestID(_ nonce: UUID) -> String {
        "desktop-" + nonce.uuidString.lowercased()
    }

    /// The words for a request the daemon took.
    public static func receiptWords(_ receipt: ProjectPostReceipt) -> String {
        receipt.isRepeat ? "That request was already posted." : "Posted. The router reads it next."
    }

    /// The words for a request the daemon refused.
    public static func refusal(code: String, message: String) -> String {
        switch code {
        case "forbidden": return "Only the owner can post to a project."
        case "not_found": return "The project is gone."
        case "unavailable": return "The daemon could not take it now. Try again."
        case "bad_request":
            let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return said.isEmpty || said == "request refused" ? "The daemon refused that request." : ProjectText.safe(said, limit: 600)
        default: return "The daemon refused it (\(ProjectText.safe(code, limit: 32)))."
        }
    }
}
