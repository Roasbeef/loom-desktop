import Foundation

extension Escalation {
    /// What a request asks to do, in words a reader would write: `run a command`.
    /// The tools named here are the harness's own, so the words are fixed. Any
    /// other tool is `use <tool>`, and the tool's name is the caller's to draw
    /// as text (`session_view/approval.wants`).
    public var wants: String {
        switch tool {
        case "bash", "shell": return "run a command"
        case "fs_read": return "read a file"
        case "fs_write": return "write a file"
        case "fs_edit": return "edit a file"
        case "": return "make a request"
        default: return "use \(tool)"
        }
    }

    /// The sentence heading the card: who asks, and what for.
    public func sentence(asker: String) -> String {
        "\(asker) wants to \(wants)"
    }

    /// The question the card puts to the person.
    public var question: String {
        switch tool {
        case "bash", "shell": return "Allow this command?"
        case "fs_read": return "Allow this file read?"
        case "fs_write": return "Allow this file write?"
        case "fs_edit": return "Allow this file edit?"
        case "": return "Allow this request?"
        default: return "Allow \(tool) to proceed?"
        }
    }

    /// Why an answer was refused without being sent, in words, when the record
    /// the person looked at is not the record the session holds now.
    public static let staleWords =
        "That request changed before your answer was sent, so nothing was answered. Check the request shown now."
}

extension Decision {
    /// How the ledger records an answer, as a person says it.
    public var outcomeWord: String {
        switch outcome {
        case "rejected": return "denied"
        case "consumed": return "allowed once"
        default: return "allowed"
        }
    }

    /// One line: what was asked, the answer, and the id a `/approvals <id>` names.
    public var line: String {
        "\(outcomeWord.prefix(1).uppercased() + outcomeWord.dropFirst()): \(summary) (\(tool.isEmpty ? "request" : tool), \(id))"
    }

    /// The reply to `/approvals [id]`. With an id prefix it names that one answer, and
    /// without it the answers in the order they were given.
    public static func ledgerWords(_ decisions: [Decision], matching prefix: String?) -> String {
        let ordered = decisions.sorted { $0.seq < $1.seq }
        if let prefix {
            guard let found = ordered.first(where: { $0.id.hasPrefix(prefix) }) else {
                return "No answered request starts with \(prefix)."
            }
            return found.line
        }
        return ordered.isEmpty ? "No request has been answered in this session." : ordered.map(\.line).joined(separator: "\n")
    }
}
