import LoomKit
import Markup
import SwiftUI

/// One changed file from the worktree observation, folded under its path with the
/// added and removed counts, and its patch drawn as red and green hunks when open.
///
/// The session's Changes tab draws one per entry. It lives in its own file so the
/// inbox's review thread can share the same header without reaching into the
/// session screen.
struct FileChange: View {
    let entry: JSONValue
    @State private var isOpen = true

    /// The status as one of a few fixed words, from the two porcelain letters.
    private var statusWord: String {
        switch (entry["index_status"]?.string ?? "", entry["worktree_status"]?.string ?? "") {
        case ("?", _): return "new"
        case (_, "D"), ("D", _): return "deleted"
        case ("A", _): return "added"
        default: return "modified"
        }
    }

    var body: some View {
        let path = entry["path"]?.string ?? ""
        let summary = Diff.parse(entry["patch"]?.string ?? "")
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.smooth(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(path).font(.system(size: 12, weight: .medium).monospaced()).lineLimit(1).truncationMode(.head)
                    Text(statusWord).font(Theme.caption).foregroundStyle(.tertiary)
                    Spacer(minLength: 6)
                    if summary.added > 0 {
                        Text("+\(summary.added)").font(Theme.meta).foregroundStyle(Theme.addedText)
                    }
                    if summary.removed > 0 {
                        Text("−\(summary.removed)").font(Theme.meta).foregroundStyle(Theme.removedText)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(path), \(summary.added) added, \(summary.removed) removed, \(statusWord)")

            if isOpen {
                DiffView(summary: summary, language: Syntax.language(forPath: path))
            }
        }
    }
}
