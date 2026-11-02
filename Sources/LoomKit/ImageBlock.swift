import Foundation

/// An image a message or a tool result carried, with what a caption states about it.
///
/// The record holds the bytes as base64 beside a declared type. The declared type is a
/// claim and not evidence, so the picture is drawn only when the bytes themselves say
/// the same type, which is the check the web page makes before it serves an image.
public struct ImageBlock: Sendable, Equatable, Identifiable {
    public let id: String
    public let mimeType: String
    public let data: Data

    public init(id: String, mimeType: String, data: Data) {
        self.id = id
        self.mimeType = mimeType
        self.data = data
    }

    /// Reads the image blocks of a message's content, in order.
    public static func read(blocks: [JSONValue], rowID: String) -> [ImageBlock] {
        blocks.enumerated().compactMap { index, block in
            guard block["type"]?.string == "image", let text = block["data"]?.string,
                  let data = Data(base64Encoded: text) else { return nil }
            return ImageBlock(id: "\(rowID)/image/\(index)", mimeType: block["mimeType"]?.string ?? "", data: data)
        }
    }

    /// Whether the bytes are an image of the type the record declared.
    public var isDrawable: Bool {
        ImageAttachment.mimeType(of: data) == mimeType
    }

    /// The width and height in pixels, read from the file's own header.
    public var pixelSize: (width: Int, height: Int)? {
        ImageHeader.size(of: data)
    }

    /// `image/png · 2 × 2 pixels · 70 bytes`, the line under a picture. A picture that
    /// is not drawn says why instead of giving figures it cannot vouch for.
    public var caption: String {
        guard isDrawable else { return "Not drawn: the bytes are not \(mimeType.isEmpty ? "a known image type" : mimeType)." }
        var parts = [mimeType]
        if let size = pixelSize { parts.append("\(size.width) × \(size.height) pixels") }
        parts.append(data.count.formatted(.byteCount(style: .file)))
        return parts.joined(separator: " · ")
    }
}

/// Reads an image's pixel size from its header, for the four types a prompt may carry.
public enum ImageHeader {
    public static func size(of data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(64 * 1024))
        switch ImageAttachment.mimeType(of: data) {
        case "image/png": return png(bytes)
        case "image/gif": return gif(bytes)
        case "image/jpeg": return jpeg(bytes)
        case "image/webp": return webp(bytes)
        default: return nil
        }
    }

    private static func big(_ bytes: [UInt8], _ at: Int, _ count: Int) -> Int {
        bytes[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
    }

    private static func little(_ bytes: [UInt8], _ at: Int, _ count: Int) -> Int {
        bytes[at..<at + count].reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    private static func png(_ bytes: [UInt8]) -> (Int, Int)? {
        guard bytes.count >= 24 else { return nil }
        return (big(bytes, 16, 4), big(bytes, 20, 4))
    }

    private static func gif(_ bytes: [UInt8]) -> (Int, Int)? {
        guard bytes.count >= 10 else { return nil }
        return (little(bytes, 6, 2), little(bytes, 8, 2))
    }

    /// The first frame header, which carries the size, is found by walking the markers.
    private static func jpeg(_ bytes: [UInt8]) -> (Int, Int)? {
        var at = 2
        while at + 9 < bytes.count {
            guard bytes[at] == 0xFF else { at += 1; continue }
            let marker = bytes[at + 1]
            if marker == 0xFF { at += 1; continue }
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                return (big(bytes, at + 7, 2), big(bytes, at + 5, 2))
            }
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { at += 2; continue }
            at += 2 + big(bytes, at + 2, 2)
        }
        return nil
    }

    private static func webp(_ bytes: [UInt8]) -> (Int, Int)? {
        guard bytes.count >= 30 else { return nil }
        switch String(decoding: bytes[12..<16], as: UTF8.self) {
        case "VP8X": return (little(bytes, 24, 3) + 1, little(bytes, 27, 3) + 1)
        case "VP8 ": return (little(bytes, 26, 2) & 0x3FFF, little(bytes, 28, 2) & 0x3FFF)
        case "VP8L":
            let bits = little(bytes, 21, 4)
            return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
        default: return nil
        }
    }
}
