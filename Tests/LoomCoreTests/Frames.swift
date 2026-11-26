import Foundation
import LoomKit

/// Builds the frames a daemon writes on a session socket, as text.
///
/// The simulation and the lane's own tests share these so that a frame means one
/// thing everywhere. They follow the v2 envelope the client decodes: `v`, `event`,
/// an optional `reply_to` and `seq`, and a `body`.
enum Frames {
    /// Compact JSON with sorted keys. A direct serializer, because `JSONEncoder` over
    /// `JSONValue` dominated the cost of a simulated schedule.
    static func text(_ value: JSONValue) -> String {
        var out = ""
        write(value, to: &out)
        return out
    }

    private static func write(_ value: JSONValue, to out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .int(let number): out += String(number)
        case .double(let number): out += String(number)
        case .string(let text): writeString(text, to: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                write(item, to: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            for (index, key) in fields.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                writeString(key, to: &out)
                out += ":"
                if let field = fields[key] { write(field, to: &out) }
            }
            out += "}"
        }
    }

    private static func writeString(_ text: String, to out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
    }

    static func envelope(replyTo: Int?, event: String, seq: Int? = nil, body: JSONValue = .object([:])) -> String {
        var fields: [String: JSONValue] = ["v": 2, "event": .string(event), "body": body]
        if let replyTo { fields["reply_to"] = .int(Int64(replyTo)) }
        if let seq { fields["seq"] = .int(Int64(seq)) }
        return text(.object(fields))
    }

    static func begin(replyTo: Int, snapshot: String, window: String, nextSeq: Int, session: String, role: String = "owner", epoch: String = "e1", oldestSeq: Int? = nil) -> String {
        var fields: [String: JSONValue] = ["oldest_seq": oldestSeq.map { .int(Int64($0)) } ?? .null]
        fields["_"] = nil
        return envelope(replyTo: replyTo, event: "snapshot_begin", body: .object(fields.merging([
            "snapshot_id": .string(snapshot),
            "next_seq": .int(Int64(nextSeq)),
            "window": .string(window),
            "session_id": .string(session),
            "epoch": .string(epoch),
            "incarnation": "i1",
            "connection_id": "c1",
            "role": .string(role),
            "complete_history": .bool(false),
            "fragment_bytes_limit": .int(Int64(TransferAssembler.fragmentLimit)),
            "record_bytes_limit": .int(Int64(TransferAssembler.recordLimit)),
        ], uniquingKeysWith: { $1 })))
    }

    /// One whole record in one chunk. `kind` is `metadata` or `entry`.
    static func chunk(replyTo: Int, snapshot: String, index: Int, kind: String, record: String, seq: Int?, payload: JSONValue) -> String {
        let data = Data(text(payload).utf8)
        var body: [String: JSONValue] = [
            "snapshot_id": .string(snapshot),
            "index": .int(Int64(index)),
            "record_id": .string(record),
            "kind": .string(kind),
            "total_bytes": .int(Int64(data.count)),
            "offset": 0,
            "data": .string(data.base64EncodedString()),
        ]
        if let seq { body["record_seq"] = .int(Int64(seq)) }
        return envelope(replyTo: replyTo, event: "snapshot_chunk", body: .object(body))
    }

    static func end(replyTo: Int, snapshot: String, nextSeq: Int, moreAfter: Int? = nil) -> String {
        var body: [String: JSONValue] = ["snapshot_id": .string(snapshot), "next_seq": .int(Int64(nextSeq))]
        if let moreAfter { body["more_after"] = .int(Int64(moreAfter)) }
        return envelope(replyTo: replyTo, event: "snapshot_end", body: .object(body))
    }

    static func error(replyTo: Int, code: String, message: String = "") -> String {
        envelope(replyTo: replyTo, event: "error", body: ["code": .string(code), "message": .string(message)])
    }

    static func decode(command text: String) -> (id: Int, cmd: String, body: JSONValue)? {
        guard let value = try? JSONValue.parse(Data(text.utf8)), let id = value["id"]?.int, let cmd = value["cmd"]?.string else {
            return nil
        }
        return (id, cmd, value["body"] ?? .object([:]))
    }
}
