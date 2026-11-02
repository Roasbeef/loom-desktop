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
    public mutating func sent(_ text: String, delivery: Delivery) -> Int? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = next
        next += 1
        lines.append(PendingDraft(id: id, text: text, delivery: delivery))
        return id
    }

    /// The daemon took the draft, so the durable record is on its way.
    public mutating func taken(_ id: Int) {
        lines.removeAll { $0.id == id }
    }

    /// The daemon refused the draft. Returns the text to put back.
    public mutating func refused(_ id: Int) -> String? {
        guard let line = lines.first(where: { $0.id == id }) else { return nil }
        lines.removeAll { $0.id == id }
        return line.text
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

    /// The most one image may weigh, as the daemon's own reader accepts.
    public static let byteLimit = 20_971_520
    /// The most images one message carries.
    public static let countLimit = 8

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
    public static func vet(_ data: Data, name: String, already: Int) -> Result<ImageAttachment, ImageRefusal> {
        guard already < countLimit else { return .failure(.init(message: "At most \(countLimit) images go in one message.")) }
        guard let type = mimeType(of: data) else {
            return .failure(.init(message: "\(name) is not a PNG, JPEG, GIF or WebP image."))
        }
        guard data.count <= byteLimit else {
            return .failure(.init(message: "\(name) is larger than \(byteLimit / 1_048_576) MB."))
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
