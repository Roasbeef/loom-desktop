import Foundation

/// Recognises the memory context the daemon attaches to a run.
///
/// The daemon writes the notes index as a user message of its own, ahead of the
/// prompt, and sessions saved by an older release may still hold the removed
/// distilled-memory digest. Neither was typed by the owner, so the transcript draws
/// them as a closed row and not as a prompt that repeats itself every turn. A message
/// is a memory context when it begins with one injector's lead sentence and carries
/// that injector's fence (`session_view/composer.memory_context_lines`).
public enum MemoryContext {
    private static let injectors: [(lead: String, fence: String)] = [
        ("Distilled memory from this repository's earlier ", "```loom-memory"),
        ("Notes saved in this repository by earlier ", "```loom-notes"),
    ]

    /// How many lines the fenced body holds, or nil when the text is no memory context.
    public static func lines(in text: String) -> Int? {
        for injector in injectors where text.hasPrefix(injector.lead) {
            guard let fence = text.range(of: injector.fence + "\n") else { continue }
            var body = String(text[fence.upperBound...])
            if body.hasSuffix("\n```") { body.removeLast(4) }
            return body.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        return nil
    }

    /// Whether the text is the strand's own notes digest, which the daemon puts in
    /// front of each run as an unauthored user message (Loom's `client/notes`).
    ///
    /// The terminal and web clients recognize it by the same opening and fence and
    /// draw no row for it, since the notes have a page of their own and the plan bar
    /// shows the todo board. A fresh copy arrives with every run, so a row for it
    /// would repeat the board above each answer.
    public static func isNotesDigest(_ text: String) -> Bool {
        text.hasPrefix("Your own notes for strand `") && text.contains("\n```agent-notes\n")
    }

    /// The closed row's words.
    public static func summary(lines: Int) -> String {
        "Memory context, \(lines) line\(lines == 1 ? "" : "s")"
    }
}
