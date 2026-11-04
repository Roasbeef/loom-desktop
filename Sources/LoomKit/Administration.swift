import Foundation

// Owner commands on the control socket beyond creating and stopping a session:
// naming, archiving, deleting, sharing and moving sessions, and the people who
// hold access. Decoding lives in these value types so unit tests can feed it
// frames, and every decoder ignores fields it does not know, as the protocol
// requires of a client (section 3.21).

// MARK: Creation options

/// What a new session may choose beyond its place: a model profile, a main model
/// and whether its box can be shared. All three are optional because an absent
/// field means the configuration's defaults.
public struct CreationOptions: Sendable, Equatable {
    /// A `[profiles.<name>]` table of the configuration the session will load.
    public var profile: String?
    /// A `[models.<name>]` key, which replaces the profile's main model.
    public var model: String?
    /// A shareable session keeps its memory to itself, which is what lets the
    /// owner invite someone later (`domain_scope: session_only`).
    public var isShareable: Bool
    /// Roles other than `main` pinned to one `[models.<key>]` entry each
    /// (Loom's protocol-change/108), such as `vision`. `main` is pinned by `model`.
    public var pins: [String: String]

    public init(profile: String? = nil, model: String? = nil, isShareable: Bool = false, pins: [String: String] = [:]) {
        self.profile = profile
        self.model = model
        self.isShareable = isShareable
        self.pins = pins
    }

    func add(to fields: inout [String: JSONValue]) {
        if let profile, !profile.isEmpty { fields["profile"] = .string(profile) }
        if let model, !model.isEmpty { fields["model"] = .string(model) }
        if isShareable { fields["domain_scope"] = .string("session_only") }

        // Sent only when a pin was chosen: a daemon from before protocol-change/108
        // refuses the field as malformed, so a plain creation must not carry it.
        let chosen = pins.filter { !$0.value.isEmpty && $0.key != "main" }
        if !chosen.isEmpty {
            fields["roles"] = .object(chosen.mapValues { .string($0) })
        }
    }
}

/// The models a configuration defines and which of them read images, as the
/// daemon's `models.list` answers, or as far as a local file can say.
///
/// Whether an entry reads images is decided by Loom's catalogue, not by a line
/// in the file, so only the daemon's answer carries it. Read from a file, every
/// entry's `readsImages` is nil and the form offers no vision choice.
public struct ModelCatalogue: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let key: String
        public let modelID: String?
        public let readsImages: Bool?
        public let roles: [String]
        public var id: String { key }

        public init(key: String, modelID: String? = nil, readsImages: Bool? = nil, roles: [String] = []) {
            self.key = key
            self.modelID = modelID
            self.readsImages = readsImages
            self.roles = roles
        }
    }

    public let models: [Entry]
    public let profiles: [String]

    public init(models: [Entry] = [], profiles: [String] = []) {
        self.models = models
        self.profiles = profiles
    }

    /// The daemon's reply. A body that is not the documented shape gives nil,
    /// never a partial list, so the form falls back rather than offering half.
    public init?(reply body: JSONValue) {
        guard let rows = body["models"]?.array, let names = body["profiles"]?.array else { return nil }
        var models: [Entry] = []
        for row in rows {
            guard let key = row["key"]?.string, !key.isEmpty, case .bool(let vision)? = row["vision"] else { return nil }
            let roles = row["roles"]?.array?.compactMap(\.string) ?? []
            models.append(Entry(key: key, modelID: row["model_id"]?.string, readsImages: vision, roles: roles))
        }
        let profiles = names.compactMap(\.string)
        guard profiles.count == names.count else { return nil }
        self.init(models: models, profiles: profiles)
    }

    /// What a local file's headers name, with nothing said about images.
    public init(file choices: ConfigurationChoices) {
        self.init(models: choices.models.map { Entry(key: $0) }, profiles: choices.profiles)
    }

    /// The entries a vision pin may name. Empty unless the daemon said which read images.
    public var imageReaders: [Entry] { models.filter { $0.readsImages == true } }
}

/// The profiles and models a configuration file defines. The daemon judges the
/// choice again (`unknown_profile`, `unknown_model`), so this only has to offer
/// the names a person can pick, and reading table headers is enough for that.
public struct ConfigurationChoices: Sendable, Equatable {
    public var profiles: [String]
    public var models: [String]

    public init(profiles: [String] = [], models: [String] = []) {
        self.profiles = profiles
        self.models = models
    }

    /// Reads `[profiles.<name>…]` and `[models.<name>…]` headers from TOML text.
    public static func parse(_ text: String) -> ConfigurationChoices {
        var profiles: [String] = []
        var models: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), !line.hasPrefix("[["), let close = line.firstIndex(of: "]") else { continue }
            let header = line[line.index(after: line.startIndex)..<close]
            let parts = header.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let name = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard !name.isEmpty else { continue }
            switch parts[0] {
            case "profiles" where !profiles.contains(name): profiles.append(name)
            case "models" where !models.contains(name): models.append(name)
            default: break
            }
        }
        return ConfigurationChoices(profiles: profiles, models: models)
    }

    public static func read(at url: URL) -> ConfigurationChoices {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ConfigurationChoices() }
        return parse(text)
    }
}

// MARK: Folder judgement

/// Whether a typed folder is worth sending, judged before the daemon is asked.
/// The daemon canonicalizes and judges again, so this exists only to say what is
/// wrong while a person is still typing.
public enum FolderCheck: Sendable, Equatable {
    case empty
    case ok(String)
    case missing
    case notAFolder
    case notWritable

    public static func judge(_ typed: String, fileManager: FileManager = .default) -> FolderCheck {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let path = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .notAFolder }
        guard fileManager.isWritableFile(atPath: path) else { return .notWritable }
        return .ok(path)
    }

    /// What to tell the person, or nil when there is nothing to say.
    public var words: String? {
        switch self {
        case .empty, .ok: return nil
        case .missing: return "That folder doesn't exist."
        case .notAFolder: return "That path is a file, not a folder."
        case .notWritable: return "You can't write to that folder."
        }
    }

    public var isUsable: Bool {
        if case .ok = self { return true }
        return false
    }
}

// MARK: Refusal words

/// Plain sentences for the refusal codes of the owner commands. A code a client
/// does not know keeps the daemon's own message.
public enum Refusal {
    public static func words(code: String, message: String? = nil) -> String? {
        // The daemon also answers  for a strand too short to compact,
        // which has nothing to do with the session being busy.
        if code == "conflict", message == "there is nothing to compact" {
            return "Nothing to compact yet."
        }
        switch code {
        case "busy": return "That session is running or still has a runtime. Stop it first."
        case "not_found": return "The daemon has no such session."
        case "forbidden": return "Only the owner can do that."
        case "stale_epoch": return "The daemon restarted. Try again."
        case "invalid_name": return "That name isn't allowed."
        case "invalid_workspace": return "The daemon can't use that folder."
        case "invalid_configuration": return "The daemon can't read that configuration."
        case "unknown_profile": return "That profile isn't defined in the configuration."
        case "unknown_model": return "That model isn't defined in the configuration."
        case "isolation_required": return "That session shares memory with its folder. Make it shareable first."
        case "moving": return "That session is being moved."
        case "not_movable": return "That session can't be moved."
        case "unavailable": return "The daemon can't do that right now."
        case "conflict": return "That can't happen while the session is working. Wait for it to stop, then try again."
        case "executor_unknown": return "That executor is not in the daemon's configuration. Check its name."
        case "pool_unknown": return "That pool is not in the daemon's configuration. Check its name."
        case "not_initialized": return "That session never finished being created. Create it again."
        case "not_owner": return "That session belongs to another orchestrator."
        case "stale_operation": return "The daemon no longer holds that operation. Look at the session's state."
        default: return nil
        }
    }
}

extension Refusal {
    /// What to tell a person when a session was created and did not open. The
    /// daemon's reason keeps its own words, minus the protocol codes in front.
    public static func unopened(reason: String) -> String {
        var cause = reason
        for code in ["start_failed: ", "executor_unavailable: "] where cause.hasPrefix(code) {
            cause.removeFirst(code.count)
        }
        return "The session was created but did not open. It is in the list: resume it there once the cause is corrected, or delete it. The daemon said: \(cause)"
    }
}

// MARK: People and sharing

/// A member's role in one session.
public enum MemberRole: String, Sendable, Equatable, CaseIterable, Identifiable {
    case operator_ = "operator"
    case observer

    public var id: Self { self }

    public var title: String {
        switch self {
        case .operator_: return "Operator"
        case .observer: return "Observer"
        }
    }

    public var summary: String {
        switch self {
        case .operator_: return "Can prompt, steer and answer approvals."
        case .observer: return "Can read the session and cannot change it."
        }
    }
}

/// One person with access to a session, from `sessions.members`.
public struct SessionMember: Sendable, Equatable, Identifiable {
    public let principalID: String
    public let name: String
    public let role: String
    public var id: String { principalID }

    init?(_ body: JSONValue) {
        guard let id = body["principal_id"]?.string else { return nil }
        principalID = id
        name = body["name"]?.string ?? id
        role = body["role"]?.string ?? "observer"
    }
}

/// What a session's member list says, with whether it can be shared at all.
public struct SessionMembers: Sendable, Equatable {
    /// `session_only` when invitations are possible, otherwise the folder's scope.
    public let scope: String
    public let members: [SessionMember]

    public var isShareable: Bool { scope == "session_only" }
}

/// The state of one person's credential, from `principals.list`.
public struct CredentialSummary: Sendable, Equatable {
    public let state: String
    public let fingerprint: String?
    public let expiresInMs: Int?

    init(_ body: JSONValue?) {
        state = body?["state"]?.string ?? "none"
        fingerprint = body?["fingerprint"]?.string
        expiresInMs = body?["expires_in_ms"]?.int
    }

    /// A sentence for the state, in the words a person would use.
    public var words: String {
        switch state {
        case "active": return fingerprint.map { "Signed in (\($0))" } ?? "Signed in"
        case "claim_open": return "Invitation not yet accepted"
        case "claim_expired": return "Invitation expired"
        default: return "No credential"
        }
    }
}

/// One principal, from `principals.list`.
public struct Principal: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isOwner: Bool
    public let credential: CredentialSummary
    public let logins: Int

    init?(_ body: JSONValue) {
        guard let id = body["principal_id"]?.string else { return nil }
        self.id = id
        name = body["name"]?.string ?? id
        isOwner = body["kind"]?.string == "owner"
        credential = CredentialSummary(body["credential"])
        logins = body["logins"]?.int ?? 0
    }
}

/// A session a principal belongs to, from `principals.memberships`.
public struct Membership: Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let name: String
    public let role: String
    public var id: String { sessionID }

    init?(_ body: JSONValue) {
        guard let id = body["session_id"]?.string else { return nil }
        sessionID = id
        name = body["name"]?.string ?? ""
        role = body["role"]?.string ?? "observer"
    }
}

/// A browser login of one principal. The fingerprint names it and proves nothing.
public struct Signin: Sendable, Equatable, Identifiable {
    public let fingerprint: String
    public let issuedAt: Date
    public let lastResumedAt: Date?
    public let expiresAt: Date?
    public var id: String { fingerprint }

    init?(_ body: JSONValue) {
        guard let fingerprint = body["fingerprint"]?.string else { return nil }
        self.fingerprint = fingerprint
        issuedAt = Date(timeIntervalSince1970: Double(body["issued_at_ms"]?.int ?? 0) / 1000)
        lastResumedAt = body["last_resumed_ms"]?.int.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        expiresAt = body["expires_in_ms"]?.int == nil
            ? body["expires_at_ms"]?.int.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            : nil
    }
}

/// The result of an invitation or a rotation: who now holds a claim, and the
/// claim itself. The claim is a bearer for one redemption, so it prints as a
/// placeholder anywhere a value is described, and the type is not `Codable`.
public struct Invitation: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let principalID: String
    public let name: String
    public let claim: String
    public let expiresInMs: Int

    init?(_ body: JSONValue) {
        guard let id = body["principal_id"]?.string, let claim = body["claim"]?.string else { return nil }
        principalID = id
        name = body["name"]?.string ?? id
        self.claim = claim
        expiresInMs = body["expires_in_ms"]?.int ?? 0
    }

    public var description: String { "Invitation(\(principalID), claim: <hidden>)" }
    public var debugDescription: String { description }

    /// The command a collaborator with `loom` runs. It names the address and never
    /// the claim, which they type when asked, so the command can be shown or logged.
    public func command(address: String) -> String {
        "loom claim --addr \(address)"
    }
}

// MARK: Peers

/// A link between two strands that lets one message the other.
public struct PeerLink: Sendable, Equatable, Identifiable {
    public enum Direction: Sendable, Equatable { case outgoing, incoming }

    public let direction: Direction
    public let sessionID: String
    public let strand: String
    public let sessionName: String
    public let wakes: Bool?
    public var id: String { "\(direction)/\(sessionID)/\(strand)" }

    init?(_ body: JSONValue, direction: Direction) {
        let sessionKey = direction == .outgoing ? "session" : "source_session"
        let strandKey = direction == .outgoing ? "target_strand" : "source_strand"
        guard let session = body[sessionKey]?.string, let strand = body[strandKey]?.string else { return nil }
        self.direction = direction
        sessionID = session
        self.strand = strand
        sessionName = body["metadata"]?["name"]?.string ?? ""
        switch body["wake"]?.string {
        case "may_wake": wakes = true
        case "busy_only": wakes = false
        default: wakes = nil
        }
    }
}

// MARK: Moves

/// One orchestrator a session might move to, with whether it can take it.
public struct MoveCandidate: Sendable, Equatable, Identifiable {
    public let name: String
    /// A sentence saying why not, or nil when the move can be asked for.
    public let refusal: String?
    public var id: String { name }
    public var isEligible: Bool { refusal == nil }

    /// Judges every other orchestrator the deployment lists, by the rule in
    /// `session_view/move_candidates`: reached, then accepting moved sessions,
    /// then serving the session's executor. A session with no executor cannot
    /// move at all, which the caller states rather than listing reasons.
    public static func choose(from deployment: Deployment, executor: String?) -> [MoveCandidate] {
        deployment.others.map { other in
            if other.state == "down" { return MoveCandidate(name: other.name, refusal: "is not reachable") }
            guard let imports = other.imports else { return MoveCandidate(name: other.name, refusal: "gave no report") }
            if imports != "receiving" { return MoveCandidate(name: other.name, refusal: "does not accept moved sessions") }
            if let executor, !other.serves.contains(executor) {
                return MoveCandidate(name: other.name, refusal: "does not serve this session's executor")
            }
            return MoveCandidate(name: other.name, refusal: nil)
        }
    }

    public static let noExecutorWords = "Only a session on an executor can move."
}

// MARK: Commands

extension ControlClient {
    private func sessionBody(_ sessionID: String, _ extra: [String: JSONValue] = [:]) throws -> JSONValue {
        var fields = extra
        fields["session_id"] = .string(sessionID)
        fields["epoch"] = .string(try currentEpoch())
        return .object(fields)
    }

    /// Gives a session a name a person chose. The reply is the catalogue record.
    public func renameSession(sessionID: String, name: String) async throws {
        _ = try await request("sessions.rename", body: try sessionBody(sessionID, ["name": .string(name)]))
    }

    /// Hides a saved session from the list. The daemon refuses a resident one.
    public func archiveSession(sessionID: String) async throws {
        _ = try await request("sessions.archive", body: try sessionBody(sessionID))
    }

    public func restoreSession(sessionID: String) async throws {
        _ = try await request("sessions.restore", body: try sessionBody(sessionID))
    }

    /// Removes a saved session and its conversation for good. The daemon refuses
    /// anything but a saved session with `busy`.
    public func deleteSession(sessionID: String) async throws {
        _ = try await request("sessions.delete", body: try sessionBody(sessionID))
    }

    /// Asks for a session on an executor to move to another orchestrator.
    public func moveSession(sessionID: String, to orchestrator: String) async throws {
        _ = try await request("sessions.move", body: try sessionBody(sessionID, ["to": .string(orchestrator)]))
    }

    public func abandonMove(sessionID: String) async throws {
        _ = try await request("sessions.move", body: try sessionBody(sessionID, ["abandon": .bool(true)]))
    }

    /// Lets a private session be shared by giving it a memory of its own. The
    /// daemon stops, isolates and resumes it, and requires the acknowledgement
    /// that the existing transcript becomes visible to whoever is invited.
    public func makeShareable(sessionID: String) async throws {
        _ = try await request("sessions.isolate", body: try sessionBody(sessionID, ["transcript": .string("share_existing")]))
    }

    /// Reads who may use a session and whether it can take more people.
    public func sessionMembers(sessionID: String) async throws -> SessionMembers {
        var members: [SessionMember] = []
        var scope = ""
        var after = ""
        while true {
            // An empty cursor is refused, so the first page names none.
            var fields: [String: JSONValue] = ["session_id": .string(sessionID)]
            if !after.isEmpty { fields["after"] = .string(after) }
            let page = try await request("sessions.members", body: .object(fields))
            scope = page["scope"]?.string ?? scope
            members += (page["members"]?.array ?? []).compactMap(SessionMember.init)
            guard let next = page["after"]?.string, !next.isEmpty else { break }
            after = next
        }
        return SessionMembers(scope: scope, members: members)
    }

    /// Invites a new person to one session. `principalID` names them for the
    /// daemon and must be new. The reply carries a claim token, shown once.
    public func invite(sessionID: String, principalID: String, name: String, role: MemberRole, claimLifetime: Duration = .seconds(3600)) async throws -> Invitation {
        let milliseconds = Int64(claimLifetime.components.seconds * 1000)
        let body = try await request("sessions.invite", body: try sessionBody(sessionID, [
            "principal_id": .string(principalID),
            "name": .string(name),
            "role": .string(role.rawValue),
            "claim_ttl_ms": .int(milliseconds),
        ]))
        guard let invitation = Invitation(body) else {
            throw LoomError.protocolViolation("sessions.invite returned no claim")
        }
        return invitation
    }

    public func setRole(sessionID: String, principalID: String, role: MemberRole) async throws {
        _ = try await request("sessions.set_role", body: try sessionBody(sessionID, [
            "principal_id": .string(principalID),
            "role": .string(role.rawValue),
        ]))
    }

    public func revokeMembership(sessionID: String, principalID: String) async throws {
        _ = try await request("sessions.revoke", body: try sessionBody(sessionID, ["principal_id": .string(principalID)]))
    }

    public func principals() async throws -> [Principal] {
        var rows: [Principal] = []
        var after = ""
        while true {
            let page = try await request("principals.list", body: after.isEmpty ? .object([:]) : ["after": .string(after)])
            rows += (page["principals"]?.array ?? []).compactMap(Principal.init)
            guard let next = page["after"]?.string, !next.isEmpty else { return rows }
            after = next
        }
    }

    public func memberships(principalID: String) async throws -> [Membership] {
        let page = try await request("principals.memberships", body: ["principal_id": .string(principalID)])
        return (page["memberships"]?.array ?? []).compactMap(Membership.init)
    }

    /// Names a principal. Omitting the principal renames the caller itself.
    public func renamePrincipal(principalID: String?, name: String) async throws {
        var fields: [String: JSONValue] = ["name": .string(name), "epoch": .string(try currentEpoch())]
        if let principalID { fields["principal_id"] = .string(principalID) }
        _ = try await request("principals.rename", body: .object(fields))
    }

    /// Replaces a person's credential with a fresh claim, which the reply carries.
    public func rotateCredential(principalID: String, claimLifetime: Duration = .seconds(3600)) async throws -> Invitation {
        let body = try await request("credentials.rotate", body: .object([
            "principal_id": .string(principalID),
            "claim_ttl_ms": .int(Int64(claimLifetime.components.seconds * 1000)),
            "epoch": .string(try currentEpoch()),
        ]))
        guard let invitation = Invitation(body) else {
            throw LoomError.protocolViolation("credentials.rotate returned no claim")
        }
        return invitation
    }

    public func revokeCredentials(principalID: String) async throws {
        _ = try await request("credentials.revoke", body: .object([
            "principal_id": .string(principalID),
            "epoch": .string(try currentEpoch()),
        ]))
    }

    public func signins(principalID: String?) async throws -> [Signin] {
        let body: JSONValue = principalID.map { ["principal_id": .string($0)] } ?? .object([:])
        let page = try await request("credentials.signins", body: body)
        return (page["signins"]?.array ?? []).compactMap(Signin.init)
    }

    public func revokeLogin(principalID: String?, fingerprint: String) async throws {
        var fields: [String: JSONValue] = ["fingerprint": .string(fingerprint), "epoch": .string(try currentEpoch())]
        if let principalID { fields["principal_id"] = .string(principalID) }
        _ = try await request("credentials.revoke_login", body: .object(fields))
    }

    /// Reads the peer links of one strand of one resident session.
    public func peerLinks(sessionID: String, strand: String) async throws -> [PeerLink] {
        let page = try await request("peers.inspect", body: .object([
            "source_session": .string(sessionID),
            "source_strand": .string(strand),
            "epoch": .string(try currentEpoch()),
        ]))
        return (page["outgoing"]?.array ?? []).compactMap { PeerLink($0, direction: .outgoing) }
            + (page["incoming"]?.array ?? []).compactMap { PeerLink($0, direction: .incoming) }
    }

    public func linkPeers(sessionID: String, strand: String, targetSession: String, targetStrand: String, wakes: Bool) async throws {
        _ = try await request("peers.link", body: .object([
            "source_session": .string(sessionID),
            "source_strand": .string(strand),
            "target_session": .string(targetSession),
            "target_strand": .string(targetStrand),
            "wake": .string(wakes ? "may_wake" : "busy_only"),
            "epoch": .string(try currentEpoch()),
        ]))
    }

    public func unlinkPeers(sessionID: String, strand: String, targetSession: String, targetStrand: String) async throws {
        _ = try await request("peers.unlink", body: .object([
            "source_session": .string(sessionID),
            "source_strand": .string(strand),
            "target_session": .string(targetSession),
            "target_strand": .string(targetStrand),
            "epoch": .string(try currentEpoch()),
        ]))
    }
}

// MARK: Operator commands

/// The commands an operator runs in a terminal on the machine that holds the
/// authority key. The app prints them and runs none, as the web page does, since
/// the key must not be on the machine that draws the interface.
public enum OperatorCommands {
    /// Quotes a name for a shell, or nil when it could not be a name at all: empty,
    /// too long, with a control character, or starting with a dash.
    public static func quote(_ name: String) -> String? {
        guard !name.isEmpty, name.utf8.count <= 128, !name.hasPrefix("-"),
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let bare = name.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic && scalar.isASCII || ("0"..."9").contains(Character(scalar)) || "-_.@:/".unicodeScalars.contains(scalar)
        }
        return bare ? name : "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func renew(_ machine: String) -> String? {
        quote(machine).map { "loom distribution renew \($0)" }
    }

    public static func revoke(_ machine: String) -> String? {
        quote(machine).map { "loom distribution revoke \($0) --reason 'REASON'" }
    }

    public static func enroll(_ machine: String, node: String, role: String, links: String) -> String? {
        guard let machine = quote(machine), let node = quote(node), let links = quote(links) else { return nil }
        return "loom distribution enroll \(machine) --node \(node) --role \(role) --links \(links)"
    }

    /// Releases the scope of a session that did not close cleanly on an executor.
    public static func release(session: String) -> String? {
        quote(session).map { "loomd executor release \($0)" }
    }
}
