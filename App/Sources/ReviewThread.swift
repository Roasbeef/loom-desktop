import LoomKit
import Markup
import MissionKit
import SwiftUI

// The review thread of the inbox's reading pane: the size of a finished session's
// change, the agent's last message, a verdict, the finds that name no shown file, and
// the files with their hunks, each find at the line it names. Beneath it the outbox
// bar lists what the owner staged and sends it as one prompt. The layout and the
// staging are `ReviewRule` and `ReviewOutbox`, which are pure and tested; this file
// draws them. It mirrors the web view's `view/review_thread.gleam`.
//
// Every word a repository or a model wrote (a path, a hunk line, a find's text, a
// last command) is drawn with `Text(verbatim:)`, and a comment is the owner's own.
// The daemon merges the commits a session made into the same file list as its working
// tree, with nothing on the wire that says which hunk is which, so this thread draws
// them as one list, as the web does.
//
// Only an open file builds its hunks, so a review of many files costs rows for the
// first file alone until the reader opens another, and the decoder's own bounds (24
// files, 12 hunks a file, 80 lines a hunk) cap the rest.
//
// ## Flow
//
// `ReviewThread` is the body: `ReviewFileView` draws one file and `ReviewFindCard` one
// find. `OutboxBar` is the bar at the pane's foot. `ReviewDrawing` turns a hunk of the
// review into the lines `DiffView` draws, and says which line each find sits under.

// MARK: What was read of a find

/// What the pane knows of one find's revision, which a close names.
enum FindRead: Equatable {
    /// The record's read is out.
    case reading
    /// The record was read at this revision, and the daemon says whether this
    /// principal may close it.
    case read(revision: Int, mayClose: Bool)
    /// The record could not be read, so the find cannot be closed from here.
    case unread(String)
}

// MARK: The body

/// The review as the pane draws it, over a message slot the pane fills with the
/// agent's last message.
struct ReviewThread<Message: View>: View {
    let review: ReviewRead?
    /// The daemon's words when the read was refused or failed.
    let words: String?
    let commandWords: String?
    let finds: [AttentionFind]
    let reads: [String: FindRead]
    /// Whether this connection may stage and send, which an observer may not.
    let acting: Bool
    @Binding var outbox: ReviewOutbox
    let readAgain: () -> Void
    @ViewBuilder let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let review {
                loaded(review)
            } else if let words {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary)
                    Button("Read again", action: readAgain).buttonStyle(.bordered)
                }
                message
            } else {
                Text("Reading the worktree\u{2026}").font(Theme.caption).foregroundStyle(.secondary)
                message
            }
        }
    }

    @ViewBuilder
    private func loaded(_ review: ReviewRead) -> some View {
        let files = ReviewRule.ordered(review.files)
        let pins = finds.map { ReviewPin(id: $0.id, path: $0.path, line: $0.line) }
        let placed = ReviewRule.place(files: files, pins: pins)

        stat(review)
        message
        if acting { verdict }
        if !placed.unplaced.isEmpty {
            PaneSection("Noticed along the way \u{00B7} \(placed.unplaced.count)") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(placed.unplaced, id: \.self) { find(id: $0) }
                }
            }
        }
        if !files.isEmpty {
            PaneSection("Files \u{00B7} source, then tests, then docs") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(zip(files, placed.files).enumerated()), id: \.element.0.path) { index, entry in
                        ReviewFileView(
                            file: entry.0, pins: entry.1, isOpenAtFirst: ReviewRule.opensOnArrival(index: index),
                            files: files.map(\.path), acting: acting, outbox: $outbox, finds: finds, reads: reads
                        )
                    }
                }
            }
        }
    }

    private func stat(_ review: ReviewRead) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                pill("+\(review.stat.added)", color: Theme.addedText)
                pill("\u{2212}\(review.stat.removed)", color: Theme.removedText)
                pill("\(review.stat.files) \(review.stat.files == 1 ? "file" : "files")", color: .secondary)
                if let commandWords {
                    Text(verbatim: commandWords).font(Theme.code).textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 3).surface(radius: Theme.radiusInner)
                }
            }
            ForEach(ReviewRule.notices(review), id: \.self) { words in
                Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pill(_ words: String, color: Color) -> some View {
        Text(verbatim: words).font(Theme.meta).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.tintStrong, in: .capsule)
    }

    /// The verdict as a segmented control. No segment is selected until the owner stages
    /// one, so the control never reads as a decision nobody made. Choosing another
    /// segment replaces the verdict; Clear in the outbox takes it back.
    private var verdict: some View {
        PaneSection("Your verdict") {
            Picker("Your verdict", selection: Binding<ReviewVerdict?>(
                get: { outbox.verdict },
                set: { chosen in
                    if let chosen, chosen != outbox.verdict { outbox.toggle(chosen) }
                }
            )) {
                ForEach([ReviewVerdict.approve, .requestChanges, .comment], id: \.label) { choice in
                    Text(choice.label).tag(Optional(choice))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(outbox.isSending)
        }
    }

    @ViewBuilder
    private func find(id: String) -> some View {
        if let found = finds.first(where: { $0.id == id }) {
            ReviewFindCard(find: found, read: reads[id], acting: acting, outbox: $outbox)
        }
    }
}

// MARK: One file

/// A file's summary line, then its finds, hunks and comment form. The first file of a
/// review is open when it arrives and the rest are folded.
private struct ReviewFileView: View {
    let file: ReviewRead.File
    let pins: ReviewFilePins
    let isOpenAtFirst: Bool
    let files: [String]
    let acting: Bool
    @Binding var outbox: ReviewOutbox
    let finds: [AttentionFind]
    let reads: [String: FindRead]
    @State private var isOpen: Bool
    @State private var draft = ""

    init(
        file: ReviewRead.File, pins: ReviewFilePins, isOpenAtFirst: Bool, files: [String], acting: Bool,
        outbox: Binding<ReviewOutbox>, finds: [AttentionFind], reads: [String: FindRead]
    ) {
        self.file = file
        self.pins = pins
        self.isOpenAtFirst = isOpenAtFirst
        self.files = files
        self.acting = acting
        _outbox = outbox
        self.finds = finds
        self.reads = reads
        _isOpen = State(initialValue: isOpenAtFirst)
    }

    private var staged: ReviewFileComment? { outbox.comments.first { $0.path == file.path } }

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pins.loose, id: \.self) { id in
                    if let found = finds.first(where: { $0.id == id }) {
                        ReviewFindCard(find: found, read: reads[id], acting: acting, outbox: $outbox)
                    }
                }
                content
                if acting { commentForm }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: file.path).font(.system(size: 12, weight: .medium).monospaced())
                    .lineLimit(1).truncationMode(.head)
                Text(verbatim: marks).font(Theme.caption).foregroundStyle(Theme.attention)
                Spacer(minLength: 6)
                Text(verbatim: "\(ReviewRule.changeWords(file)) \u{00B7} \(ReviewRule.counts(file))")
                    .font(Theme.meta).foregroundStyle(.secondary)
            }
            // A disclosure group opens from its triangle alone, so the whole label row
            // opens it too, as the row did before it was a disclosure group.
            .contentShape(.rect)
            .onTapGesture { isOpen.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isOpen.toggle() }
            .accessibilityLabel(Text(verbatim: "\(file.path), \(ReviewRule.changeWords(file)), \(ReviewRule.counts(file))"))
            .accessibilityIdentifier("review-file/\(file.path)")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }

    /// "2 finds · comment staged", or nothing.
    private var marks: String {
        var words: [String] = []
        if pins.count > 0 { words.append("\(pins.count) \(pins.count == 1 ? "find" : "finds")") }
        if staged != nil { words.append("comment staged") }
        return words.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private var content: some View {
        if let notice = ReviewRule.contentNotice(file) {
            Text(verbatim: notice).font(Theme.caption).foregroundStyle(.secondary)
        } else {
            ForEach(Array(file.hunks.enumerated()), id: \.offset) { index, hunk in
                VStack(alignment: .leading, spacing: 4) {
                    DiffView(summary: ReviewDrawing.summary(of: hunk, index: index), below: below(hunk: index))
                    ForEach(ReviewRule.hunkNotices(hunk), id: \.self) { words in
                        Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(ReviewRule.cutNotices(file), id: \.self) { words in
                Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The finds anchored under a line of one hunk. The line's id is its position among
    /// the hunk's lines, which is what the pins name.
    private func below(hunk: Int) -> (DiffHunk.Line) -> AnyView? {
        { line in
            let ids = pins.at(hunk: hunk, line: line.id)
            guard !ids.isEmpty else { return nil }
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ids, id: \.self) { id in
                        if let found = finds.first(where: { $0.id == id }) {
                            ReviewFindCard(find: found, read: reads[id], acting: acting, outbox: $outbox)
                        }
                    }
                }
                .padding(.vertical, 6)
            )
        }
    }

    private var commentForm: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(text: $draft, prompt: Text("Comment on this file"), axis: .vertical) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .accessibilityLabel("Comment on this file")
                .onAppear { draft = staged?.text ?? "" }
            Button(staged == nil ? "Stage the comment" : "Update the comment") {
                outbox.comment(files: files, path: file.path, text: draft)
            }
            .buttonStyle(.bordered)
            .disabled(outbox.isSending || (staged == nil && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
    }
}

// MARK: One find

/// A find at the place it names: its kind, its text as the agent's, its path and line,
/// and for an owner or an operator the way to stage closing it.
private struct ReviewFindCard: View {
    let find: AttentionFind
    let read: FindRead?
    let acting: Bool
    @Binding var outbox: ReviewOutbox
    @State private var note = ""

    private var staged: ReviewFindAction? { outbox.finds.first { $0.id == find.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: ReviewRule.marker(find.kind))
                    .font(Theme.code.weight(.bold))
                    .frame(width: 18, height: 18)
                    .background(find.kind == .risk ? Theme.failure.opacity(0.2) : Theme.tintStrong, in: .circle)
                QuoteBox(source: "The agent noticed (\(find.kind.rawValue)), untrusted text", words: find.head)
            }
            if let path = find.path {
                Text(verbatim: find.line.map { "\(path):\($0)" } ?? path).font(Theme.code).textSelection(.enabled)
            }
            if acting { action }
        }
    }

    @ViewBuilder
    private var action: some View {
        if let staged {
            Text(verbatim: "Staged: close as \(staged.outcome.rawValue)" + (staged.standing == .applied ? " (applied)" : ""))
                .font(Theme.caption).foregroundStyle(Theme.attention)
        }
        switch read {
        case .read(let revision, let mayClose):
            if mayClose, staged?.standing != .applied {
                TextField(text: $note, prompt: Text("A note for the agent (optional)"), axis: .vertical) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityLabel("A note for the agent about this find")
                HStack(spacing: 8) {
                    stage("Close as Fixed", .fixed, revision)
                    stage("Filed", .filed, revision)
                    stage("Dismiss", .dismissed, revision)
                }
            } else if !mayClose {
                Text("Only the owner or an operator can close a find.").font(Theme.caption).foregroundStyle(.secondary)
            }
        case .unread(let words):
            Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary)
        case .reading, nil:
            Text("Reading the find\u{2026}").font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private func stage(_ label: String, _ outcome: FindOutcome, _ revision: Int) -> some View {
        Button(label) { outbox.close(find: find.id, revision: revision, outcome: outcome, note: note) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(outbox.isSending)
    }
}

// MARK: The outbox bar

/// The bar at the foot of a review thread: what is staged and for whom, why the last
/// stage was refused, what the last Send did, Clear and Send. A connection that may not
/// send says so in its place.
struct OutboxBar: View {
    let name: String
    let acting: Bool
    let outbox: ReviewOutbox
    let clear: () -> Void
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if acting {
                VStack(alignment: .leading, spacing: 6) {
                    // A session's name is text a person or a model wrote.
                    Text(verbatim: headline).font(Theme.label)
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        Text(verbatim: chip).font(Theme.caption).lineLimit(2)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Theme.tintStrong, in: .rect(cornerRadius: 4))
                    }
                    HStack(spacing: 8) {
                        Text(verbatim: words).font(Theme.caption).foregroundStyle(.secondary).lineLimit(4)
                        Spacer(minLength: 8)
                        Button("Clear", action: clear).buttonStyle(.bordered)
                            .disabled(!outbox.hasStaged || outbox.isSending)
                        Button("Send", action: send).buttonStyle(.borderedProminent)
                            .disabled(!outbox.hasStaged || outbox.isSending)
                            .accessibilityIdentifier("review-send")
                    }
                }
            } else {
                Text("Only the owner or an operator can send a review.").font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
        .accessibilityIdentifier("review-outbox")
    }

    private var headline: String {
        switch outbox.progress {
        case .settled: return "Sent."
        default: return outbox.hasStaged ? "To \(name) \u{00B7} \(chips.count) staged." : "Not sent."
        }
    }

    /// The staged items, one line each.
    private var chips: [String] {
        var lines: [String] = []
        if let verdict = outbox.verdict { lines.append("Verdict: \(verdict.words)") }
        lines += outbox.comments.map { "Comment on \($0.path): \($0.text)" }
        lines += outbox.finds.map { action in
            "Close \(action.id) as \(action.outcome.rawValue)" + (action.note.map { ": \($0)" } ?? "")
                + (action.standing == .applied ? " (applied)" : "")
        }
        return lines
    }

    /// The refusal of the last stage, the outcome of the last Send, or what happens to
    /// the staged items.
    private var words: String {
        if let problem = outbox.problem { return problem }
        switch outbox.progress {
        case .sending: return "Sending\u{2026}"
        case .settled(let receipt): return receipt.lines.joined(separator: " ")
        case .resting:
            return outbox.hasStaged
                ? "Staged items are discarded if you open another thread."
                : "Nothing is staged. Nothing is sent until you press Send."
        }
    }
}

// MARK: Drawing a hunk

/// Turns a hunk of the review into the lines `DiffView` draws. A line's id is its
/// position among the hunk's lines, which is how `ReviewFilePins` names it, and a
/// "no newline at end of file" note has no row of its own, as in the session's diff.
enum ReviewDrawing {
    static func summary(of hunk: ReviewRead.Hunk, index: Int) -> DiffSummary {
        var lines: [DiffHunk.Line] = []
        var added = 0
        var removed = 0
        for (position, line) in hunk.lines.enumerated() {
            let kind: DiffHunk.Kind
            switch line.kind {
            case .added: kind = .added; added += 1
            case .removed: kind = .removed; removed += 1
            case .context: kind = .context
            case .noNewline: continue
            }
            lines.append(.init(id: position, kind: kind, oldNumber: line.old, newNumber: line.new, text: line.text))
        }
        return DiffSummary(hunks: [DiffHunk(id: index, header: hunk.header, lines: lines)], added: added, removed: removed)
    }
}
