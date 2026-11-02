import Foundation

/// A pending request for a person to approve a policy widening.
///
/// `grants`, `action` and `seq` are kept exactly as the record stated them,
/// because an approval echoes them to prove what the person actually saw.
public struct Escalation: Sendable, Equatable, Identifiable {
    public let id: String
    public let seq: Int
    public let status: String
    public let strand: String
    public let tool: String
    public let action: String
    public let preview: String
    public let reason: String
    public let source: String
    /// The requested widening in the wire vocabulary, which is what `approve`
    /// must echo. See `wireGrant`.
    public let grants: [JSONValue]
    /// Grants this client could not translate. An approval would be narrower
    /// than what was asked without the person seeing that, so it is withheld.
    public let untranslatableGrants: Int

    /// The orchestrator the question was raised on, when it is not this one.
    public let placement: String?
    /// Grants a remote child asked for that the spawner's ceiling does not admit.
    /// They are shown, and an approval cannot carry them.
    public let outsideCeiling: [String]

    /// A local approval must cover the whole request. A remote one may be
    /// narrower by rule, because the protocol limits it to the admitted grants.
    public var canApprove: Bool { untranslatableGrants == 0 && !grants.isEmpty }

    public init(
        id: String, seq: Int, status: String, strand: String, tool: String,
        action: String, preview: String, reason: String, source: String, grants: [JSONValue],
        untranslatableGrants: Int = 0,
        placement: String? = nil,
        outsideCeiling: [String] = []
    ) {
        self.id = id
        self.seq = seq
        self.status = status
        self.strand = strand
        self.tool = tool
        self.action = action
        self.preview = preview
        self.reason = reason
        self.source = source
        self.grants = grants
        self.untranslatableGrants = untranslatableGrants
        self.placement = placement
        self.outsideCeiling = outsideCeiling
    }

    /// Translates one durable grant, discriminated by `grant`, to its wire
    /// form, discriminated by `type`.
    ///
    /// The escalation cell holds the durable record, whereas `approve` decodes
    /// the protocol's vocabulary, so the reference client performs this same
    /// translation (`session_view/approval.wire_grant`). A kind this client
    /// does not know returns nil rather than being echoed in a guessed shape.
    static func wireGrant(_ durable: JSONValue) -> JSONValue? {
        guard let kind = durable["grant"]?.string else { return nil }
        let kept: [String: JSONValue]
        switch kind {
        case "writable_root", "readable_root":
            guard let path = durable["path"]?.string else { return nil }
            kept = ["path": .string(path)]
        case "env":
            guard let name = durable["name"]?.string else { return nil }
            kept = ["name": .string(name)]
        case "network":
            guard let network = durable["network"], case .object = network else { return nil }
            kept = ["network": network]
        case "limit":
            let names = ["cpu_s": "cpu_seconds", "wall_s": "wall_seconds", "mem_bytes": "mem_bytes",
                         "pids": "pids", "fsize_bytes": "fsize_bytes", "output_bytes": "output_bytes"]
            guard let field = durable["field"]?.string.flatMap({ names[$0] }),
                  let value = durable["value"], (value.int ?? -1) >= 0 else { return nil }
            kept = ["field": .string(field), "value": value]
        case "scratch":
            guard let target = durable["scratch"]?.string else { return nil }
            kept = ["scratch": target == "tmpfs" ? ["mode": "tmpfs"] : ["mode": "path", "path": .string(target)]]
        default:
            return nil
        }
        return .object(kept.merging(["type": .string(kind)]) { current, _ in current })
    }

    /// One literal line per grant, shown verbatim as the requested authority.
    public var authorityLines: [String] {
        grants.map(Self.describe)
    }

    /// The preview with every forgery primitive made visible.
    public var safePreview: String {
        Self.escapeForDisplay(preview)
    }

    /// Describes one grant without interpreting beyond what it states.
    static func describe(_ grant: JSONValue) -> String {
        switch grant["type"]?.string {
        case "writable_root": return "Write to \(grant["path"]?.string ?? "?")"
        case "readable_root": return "Read from \(grant["path"]?.string ?? "?")"
        case "network":
            let network = grant["network"]
            let hosts = network?["allow"]?.array?.compactMap(\.string).joined(separator: ", ") ?? ""
            let proxy = network?["proxy"]?.string.map { " via \($0)" } ?? ""
            return "Network \(network?["mode"]?.string ?? "?")" + (hosts.isEmpty ? "" : ": \(hosts)") + proxy
        case "env": return "Environment variable \(grant["name"]?.string ?? "?")"
        case "limit": return "Limit \(grant["field"]?.string ?? "?") = \(grant["value"]?.int ?? 0)"
        case "scratch": return "Scratch \(grant["scratch"]?["mode"]?.string ?? "?")"
        default: return grant.compactText
        }
    }

    /// Escapes rather than deletes every control and bidirectional character.
    ///
    /// The preview is model-controlled text inside the one prompt whose purpose
    /// is to be answered truthfully. Deleting a byte would hide that it was
    /// there, so `install\b\b evil` must not read like `install evil`
    /// (client protocol section 5.10, rule 1).
    public static func escapeForDisplay(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                // A line break is layout in this block, not a control trick,
                // and the block is bounded and set apart from the app's words.
                output.unicodeScalars.append(scalar)
            case 0x00...0x1F, 0x7F...0x9F, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                output += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}
