import Foundation

/// A strand's notes, from the `notes` snapshot (protocol section 4.9.16).
///
/// A board is a bounded observation: values are cut at 4096 bytes and a row is
/// marked `excerpt` when it was, and `total` may exceed the rows held. A
/// client must say so, and must not read an excerpt as the whole note.
public struct NotesBoard: Sendable, Equatable {
    public struct Note: Sendable, Equatable, Identifiable {
        public let key: String
        public let seq: Int
        public let text: String
        public let isExcerpt: Bool
        public var id: String { key }

        /// The `todo` note holds the todo board and is drawn by that surface.
        public var isTodo: Bool { key == "todo" }

        /// The text as formatted JSON when it is JSON, for the Readable view.
        public var readable: String {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let pretty = try? JSONSerialization.data(
                    withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let output = String(data: pretty, encoding: .utf8) else { return text }
            return output
        }

        /// Whether the note's text is a structured value, so that Readable and
        /// Raw differ.
        public var isStructured: Bool { readable != text }

        /// One entry of a note that is a JSON object, in key order.
        public struct Field: Sendable, Equatable, Identifiable {
            public enum Value: Sendable, Equatable {
                /// A string, number or boolean, drawn as prose that wraps.
                case text(String)
                /// An array of scalars, drawn as a list.
                case items([String])
                /// Anything nested deeper, drawn as formatted JSON.
                case structure(String)
            }

            public let key: String
            public let value: Value
            public var id: String { key }
        }

        /// The note's entries when it is a JSON object, or nil when it is not.
        ///
        /// Agents commonly write a note as a flat object of sentences, which reads
        /// badly as indented JSON in a narrow pane. Laid out as fields, each value
        /// wraps, and only a value with structure of its own keeps the JSON form.
        public var fields: [Field]? {
            guard !isExcerpt, let data = text.data(using: .utf8),
                  case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data),
                  !object.isEmpty else { return nil }
            return object.keys.sorted().map { key in Field(key: key, value: Self.value(object[key] ?? .null)) }
        }

        private static func value(_ json: JSONValue) -> Field.Value {
            if let scalar = scalar(json) { return .text(scalar) }
            if case .array(let elements) = json {
                let scalars = elements.compactMap(scalar)
                if scalars.count == elements.count { return .items(scalars) }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let pretty = (try? encoder.encode(json)).flatMap { String(data: $0, encoding: .utf8) }
            return .structure(pretty ?? json.compactText)
        }

        private static func scalar(_ json: JSONValue) -> String? {
            switch json {
            case .string(let value): return value
            case .int(let value): return String(value)
            case .double(let value): return String(value)
            case .bool(let value): return value ? "true" : "false"
            case .null: return "null"
            case .array, .object: return nil
            }
        }

        /// One line of the note for a list row.
        public var summary: String { PanelWords.clip(PanelWords.oneLine(text), 120) }
    }

    public let strand: String
    public let asOf: Int
    public let total: Int
    public let notes: [Note]

    public init?(_ board: JSONValue?) {
        guard let board, let strand = board["strand"]?.string, let rows = board["notes"]?.array else { return nil }
        self.strand = strand
        asOf = board["as_of"]?.int ?? 0
        total = board["total"]?.int ?? rows.count
        notes = rows.compactMap { row in
            guard let key = row["key"]?.string else { return nil }
            return Note(
                key: key,
                seq: row["seq"]?.int ?? 0,
                text: row["text"]?.string ?? "",
                isExcerpt: row["extent"]?.string == "excerpt"
            )
        }
    }

    /// The notes whose key or text contains `query`, ignoring case. Search
    /// covers the notes held, which `omitted` says may be fewer than `total`.
    public func matching(_ query: String) -> [Note] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return notes }
        return notes.filter {
            $0.key.localizedCaseInsensitiveContains(needle) || $0.text.localizedCaseInsensitiveContains(needle)
        }
    }

    public var omitted: Int { max(0, total - notes.count) }

    /// The todo board stored in the `todo` note, when the note is complete.
    /// An excerpt is never parsed.
    public var todo: TodoBoard? {
        guard let note = notes.first(where: \.isTodo), !note.isExcerpt else { return nil }
        return TodoBoard.from(noteText: note.text)
    }
}
