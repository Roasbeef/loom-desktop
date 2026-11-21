import Foundation

/// A parser for one JSON document, straight from its bytes to a `JSONValue`.
///
/// `JSONDecoder` reaches a `JSONValue` by asking a value container for a `Bool`,
/// then an `Int64`, a `Double` and a `String`, each failing with a thrown error
/// that carries its coding path. A string value therefore threw three errors
/// before it decoded, and a snapshot is mostly strings. This reads the byte
/// that starts each value and goes straight to the right case, so a document
/// costs the allocations of the values it holds and nothing for the ones it
/// rules out.
///
/// A number that is whole and fits `Int64` is `.int`, and any other number is
/// `.double`, as it was. Nesting deeper than `maxDepth` is refused, so a hostile document
/// cannot exhaust the stack.
struct JSONParser {
    static let maxDepth = 512

    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0

    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw in
            var parser = JSONParser(bytes: raw.bindMemory(to: UInt8.self))
            parser.skipSpace()
            let value = try parser.value(depth: 0)
            parser.skipSpace()
            guard parser.index == parser.bytes.count else { throw parser.fail("data after the document") }
            return value
        }
    }

    private init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    private func fail(_ why: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "invalid JSON at byte \(index): \(why)"))
    }

    private mutating func skipSpace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth <= Self.maxDepth else { throw fail("nested too deeply") }
        guard index < bytes.count else { throw fail("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try number()
        }
    }

    private mutating func literal(_ word: StaticString) throws {
        let count = word.utf8CodeUnitCount
        guard index + count <= bytes.count else { throw fail("unexpected end") }
        for offset in 0..<count where bytes[index + offset] != word.utf8Start[offset] {
            throw fail("expected \(word)")
        }
        index += count
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        index += 1
        var fields: [String: JSONValue] = [:]
        skipSpace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(fields)
        }
        while true {
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("expected a key") }
            let key = try string()
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("expected ':'") }
            index += 1
            skipSpace()
            fields[key] = try value(depth: depth + 1)
            skipSpace()
            guard index < bytes.count else { throw fail("unexpected end") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(fields) }
            throw fail("expected ',' or '}'")
        }
    }

    private mutating func array(depth: Int) throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipSpace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipSpace()
            items.append(try value(depth: depth + 1))
            skipSpace()
            guard index < bytes.count else { throw fail("unexpected end") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw fail("expected ',' or ']'")
        }
    }

    private mutating func number() throws -> JSONValue {
        let start = index
        var isInteger = true
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        let digits = index
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        guard index > digits else { throw fail("expected a value") }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            let fraction = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            guard index > fraction else { throw fail("expected digits after '.'") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            let exponent = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            guard index > exponent else { throw fail("expected digits in the exponent") }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        if isInteger, let whole = Int64(text) { return .int(whole) }
        guard let real = Double(text) else { throw fail("a number out of range") }

        // A number written with a fraction or exponent that is a whole number in
        // range reads as an integer, as it did through `JSONDecoder`, so `1e3` and
        // `1000` are the same value to everything that reads them.
        if real.rounded() == real, abs(real) < 9_223_372_036_854_775_808 { return .int(Int64(real)) }
        return .double(real)
    }

    /// Reads a string whose opening quote is at `index`.
    private mutating func string() throws -> String {
        index += 1
        let start = index

        // Most strings carry no escape, so they are one slice of the input.
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                index += 1
                return text
            }
            if byte == UInt8(ascii: "\\") { break }
            guard byte >= 0x20 else { throw fail("a control character in a string") }
            index += 1
        }
        guard index < bytes.count else { throw fail("an unterminated string") }

        var scalars = [UInt8](bytes[start..<index])
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: scalars, as: UTF8.self)
            }
            guard byte >= 0x20 else { throw fail("a control character in a string") }
            if byte != UInt8(ascii: "\\") {
                scalars.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { throw fail("an unterminated string") }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): scalars.append(0x22)
            case UInt8(ascii: "\\"): scalars.append(0x5C)
            case UInt8(ascii: "/"): scalars.append(0x2F)
            case UInt8(ascii: "b"): scalars.append(0x08)
            case UInt8(ascii: "f"): scalars.append(0x0C)
            case UInt8(ascii: "n"): scalars.append(0x0A)
            case UInt8(ascii: "r"): scalars.append(0x0D)
            case UInt8(ascii: "t"): scalars.append(0x09)
            case UInt8(ascii: "u"): scalars.append(contentsOf: Array(String(try unicodeEscape()).utf8))
            default: throw fail("an unknown escape")
            }
        }
        throw fail("an unterminated string")
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw fail("a short \\u escape") }
        var code: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
            default: throw fail("a bad \\u escape")
            }
            code = code << 4 | digit
            index += 1
        }
        return code
    }

    /// Reads the code after `\u`, joining a surrogate pair into one scalar. A lone
    /// surrogate becomes U+FFFD, as it did with `JSONDecoder`.
    private mutating func unicodeEscape() throws -> Character {
        let first = try hex4()
        guard (0xD800...0xDBFF).contains(first) else {
            return Character(Unicode.Scalar(first) ?? "\u{FFFD}")
        }
        guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
            return "\u{FFFD}"
        }
        let save = index
        index += 2
        let second = try hex4()
        guard (0xDC00...0xDFFF).contains(second) else {
            index = save
            return "\u{FFFD}"
        }
        let scalar = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
        return Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")
    }
}
