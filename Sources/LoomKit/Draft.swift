import Foundation

/// How a draft reaches a strand that may be busy.
public enum Delivery: Sendable, Equatable {
    /// An idle strand takes the text as a new turn.
    case send
    /// The daemon holds the text and runs it after the current turn.
    case queue
    /// The text joins the turn already running.
    case steer
}

/// A draft the person has sent that the daemon has not yet answered.
///
/// It is drawn as a line above the editor until the daemon takes it, so a press
/// is acknowledged at once and the transcript still shows only what is durable.
public struct PendingDraft: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
    public let delivery: Delivery
    /// The strand the text was sent to, which is where the transcript will show it.
    public let strand: String
    /// Where the draft stands with the daemon.
    public var outcome: Outcome = .waiting

    /// What is known about a sent draft.
    public enum Outcome: Sendable, Equatable {
        /// The command is on the wire or waiting for it, and the reply may still come.
        case waiting
        /// No reply arrived, so the daemon may or may not have admitted the text. The
        /// transcript decides: `afterSeq` is the newest record the sender held when the
        /// reply was lost, so a user row with this text above it settles the line as
        /// delivered, and no such row in a window that reaches back to it settles it as
        /// not delivered. A count of equal texts would mistake old history for a new row.
        case unknown(afterSeq: Int)
    }

    /// Whether the person is told the text may have been sent.
    public var isUnknown: Bool {
        if case .unknown = outcome { return true }
        return false
    }
}

/// The sent drafts awaiting an answer.
///
/// A refusal returns the text so the editor can put it back, because the press
/// emptied the editor before the daemon had said yes.
public struct DraftLedger: Sendable, Equatable {
    public private(set) var lines: [PendingDraft] = []
    private var next = 1

    public init() {}

    /// Records a sent draft. A draft with no words shows no line, since an image
    /// alone has nothing to show.
    @discardableResult
    public mutating func sent(_ text: String, delivery: Delivery, strand: String = "main") -> Int? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = next
        next += 1
        lines.append(PendingDraft(id: id, text: text, delivery: delivery, strand: strand))
        return id
    }

    /// The daemon took the draft, so the durable record is on its way.
    public mutating func taken(_ id: Int) {
        lines.removeAll { $0.id == id }
    }

    /// The daemon refused the draft, or the command never reached the wire. Returns the
    /// text to put back. A refusal is definite, so the text is the person's again.
    public mutating func refused(_ id: Int) -> String? {
        guard let line = lines.first(where: { $0.id == id }) else { return nil }
        lines.removeAll { $0.id == id }
        return line.text
    }

    /// No reply arrived, so the outcome is unknown. The line stays, now marked, and the
    /// text is kept out of the editor: the daemon may have admitted it, and putting it
    /// back would leave it both in the transcript and one Return from a second send.
    public mutating func lost(_ id: Int, afterSeq: Int) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].outcome = .unknown(afterSeq: afterSeq)
    }

    /// Marks every line still waiting as unknown, for a session that replaced the one
    /// that sent them. Their replies can no longer arrive.
    public mutating func loseWaiting(afterSeq: (PendingDraft) -> Int) {
        for index in lines.indices where lines[index].outcome == .waiting {
            lines[index].outcome = .unknown(afterSeq: afterSeq(lines[index]))
        }
    }

    /// What the transcript just read says of one unknown line.
    public enum Verdict: Sendable, Equatable {
        /// A row with the text sits above the line's `afterSeq`: it arrived.
        case delivered
        /// The window reaches back to `afterSeq` and holds no such row: it did not arrive.
        case absent
        /// The window does not reach back far enough to say, so the line stays unknown.
        case undecided
    }

    /// Settles the unknown lines against the transcript that has just been read. A delivered
    /// line is dropped, an absent one is dropped and its text returned to be offered back, and
    /// an undecided one stays.
    public mutating func settleUnknown(_ verdict: (PendingDraft) -> Verdict) -> [String] {
        var offered: [String] = []
        for line in lines where line.isUnknown {
            switch verdict(line) {
            case .delivered: lines.removeAll { $0.id == line.id }
            case .absent:
                offered.append(line.text)
                lines.removeAll { $0.id == line.id }
            case .undecided: break
            }
        }
        return offered
    }

    /// Merges restored text into an editor that may have been typed into since.
    public static func restoring(_ text: String, into current: String) -> String {
        current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : text + "\n\n" + current
    }
}

/// An image the person attached to a draft.
public struct ImageAttachment: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let mimeType: String
    public let data: Data

    /// The most all the images of one message may weigh together, which is the limit
    /// the terminal client applies to a session lane. The web page's own 8 MiB bound
    /// comes from its frame size, so it does not apply here.
    public static let byteLimit = 20_971_520
    /// The most images one message carries, the same on every client.
    public static let countLimit = 4

    /// Identifies the format from its magic bytes. A declared type is a claim
    /// and not evidence, so an extension or a pasteboard type is never trusted.
    public static func mimeType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }

    /// Vets one candidate, returning the attachment or the sentence that refuses it.
    public static func vet(_ data: Data, name: String, already: Int, alreadyBytes: Int = 0) -> Result<ImageAttachment, ImageRefusal> {
        guard already < countLimit else {
            return .failure(.init(message: "\(name) was not attached: \(countLimit) of \(countLimit) images are attached, which is the most one message carries."))
        }
        guard let type = mimeType(of: data) else {
            return .failure(.init(message: "\(name) is not a PNG, JPEG, GIF or WebP image."))
        }
        guard alreadyBytes + data.count <= byteLimit else {
            return .failure(.init(message: "A message may attach at most \(byteLimit / 1_048_576) MiB of images, so \(name) was not attached."))
        }
        return .success(ImageAttachment(id: UUID(), name: name, mimeType: type, data: data))
    }
}

public struct ImageRefusal: Error, Sendable, Equatable {
    public let message: String
}

/// The body of a `prompt_content` command.
public enum PromptContent {
    /// Text first, then the images in the order they were attached.
    public static func body(strand: String, text: String, images: [ImageAttachment]) -> JSONValue {
        var blocks: [JSONValue] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.object(["type": "text", "text": .string(text)]))
        }
        for image in images {
            blocks.append(.object([
                "type": "image",
                "data": .string(image.data.base64EncodedString()),
                "mimeType": .string(image.mimeType),
            ]))
        }
        return .object(["strand": .string(strand), "content": .array(blocks)])
    }
}
