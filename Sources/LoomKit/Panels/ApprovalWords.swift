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
