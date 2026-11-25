import Foundation

/// Which durable entry a streamed response belongs to.
///
/// This mirrors Loom's `session_view/stream_identity.gleam`. A generation or poll
/// identity that names a reserved response entry is a JSON array of four items:
/// the kind (`generation` or `poll`), a step id, a non-negative attempt number and
/// the entry id. Provider completion precedes that entry's publication, so the end
/// of a stream cannot by itself remove text the reader has already seen. The
/// stream is handed to its reserved entry, and only that entry's arrival removes it.
///
/// Any other shape stays opaque. A malformed identifier cannot acquire ownership of
/// a durable transcript entry, and an older server or a summary request that
/// carries no response entry keeps the previous behaviour.
public enum StreamIdentity {
    /// The reserved response entry, or nil for an identity of another shape.
    ///
    /// ## Examples
    ///
    /// `["generation","step-1",0,"entry-9"]` names `entry-9`, and `legacy-request`
    /// names nothing.
    public static func responseEntry(_ identity: String?) -> String? {
        guard let identity,
              let parsed = try? JSONValue.parse(Data(identity.utf8)),
              let items = parsed.array, items.count == 4,
              let kind = items[0].string, kind == "generation" || kind == "poll",
              items[1].string != nil,
              case .int(let attempt) = items[2], attempt >= 0,
              let entry = items[3].string, !entry.isEmpty
        else { return nil }
        return entry
    }
}
