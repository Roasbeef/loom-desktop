import LoomKit
import Markup
import SwiftUI

/// The focused strand's notes: the durable, keyed text it keeps for itself.
///
/// A notes board is a bounded observation, so the pane says how many of the
/// notes it holds, marks an excerpt as one, and says that search covers only
/// what was read. A note that is structured data is shown readable by default,
/// with the raw text a click away.
struct NotesPane: View {
    let controller: SessionController
    @State private var query = ""
    @State private var open: String?
    @State private var showsRaw = false

    private var board: NotesBoard? {
        NotesBoard(controller.surfaces["notes"]?["board"]).flatMap { $0.strand == controller.focusedStrand ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let board, let key = open, let note = board.notes.first(where: { $0.key == key }) {
                detail(note)
            } else {
                list
            }
        }
        .task(id: controller.focusedStrand) { refresh() }
        // Escape leaves the page wherever the focus is. An exit command would reach
        // here only with the focus inside this pane, and it is usually in the composer.
        .background {
            if open != nil {
                Button("Back") { open = nil }.keyboardShortcut(.cancelAction).hidden()
            }
        }
    }

    private func refresh() {
        controller.read("notes", body: ["strand": .string(controller.focusedStrand)])
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes").font(.headline)
                Spacer()
                IconButton(symbol: "arrow.clockwise", label: "Refresh notes", action: refresh)
            }
            TextField("Search notes…", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search notes")
            if let board {
                Quiet("\(board.notes.count) of \(board.total) notes · snapshot at \(board.asOf)"
                      + (board.omitted > 0 ? " · \(board.omitted) omitted; search covers the notes held only." : ""))
                let rows = board.matching(query)
                if rows.isEmpty {
                    Quiet(board.notes.isEmpty ? "No notes in this snapshot." : "No matching notes.")
                }
                ForEach(rows) { note in
                    Button {
                        open = note.key
                        showsRaw = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(note.key).font(Theme.code)
                                if note.isExcerpt { Text("excerpt").font(Theme.caption).foregroundStyle(Theme.attention) }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Text(note.summary).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surface()
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Note \(note.key)")
                }
            } else if let error = controller.readFailures["notes"] {
                Quiet("Notes are unavailable: \(error)")
            } else {
                Quiet("Reading notes…")
            }
        }
    }

    private func detail(_ note: NotesBoard.Note) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open = nil } label: {
                Label("All notes", systemImage: "chevron.left").font(Theme.label)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("All Notes")
            HStack {
                Text(note.key).font(.system(size: 13, weight: .semibold).monospaced())
                Spacer()
                // Every note has a readable form now, since plain text is drawn as markdown.
                Picker("Representation", selection: $showsRaw) {
                    Text("Readable").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .accessibilityLabel("Note representation")
            }
            if note.isExcerpt {
                Quiet("Excerpt only. This bounded snapshot does not contain the rest of the note.")
            }
            if !showsRaw, let fields = note.fields {
                NoteFields(fields: fields)
            } else if !showsRaw, !note.isStructured {
                // A note of plain text is usually markdown the agent wrote.
                MarkdownView(source: note.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .surface()
            } else {
                ScrollView(.horizontal) {
                    Text(showsRaw ? note.text : note.readable)
                        .font(Theme.code)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .surface()
            }
            Quiet("Written at sequence \(note.seq).")
        }
    }
}

/// A note that is a JSON object, one labelled entry per key, so sentences wrap
/// in a narrow pane instead of running off its edge.
struct NoteFields: View {
    let fields: [NotesBoard.Note.Field]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 3) {
                    Text(field.key).font(Theme.meta).foregroundStyle(.secondary)
                    switch field.value {
                    case .text(let text):
                        MarkdownView(source: text)
                    case .items(let items):
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(.tertiary)
                                    Text(MarkdownView.inline(item))
                                }
                            }
                        }
                    case .structure(let json):
                        // Wrapped in place: a scroll view inside the inspector's own
                        // scroll view centred short values and hid the rest.
                        Text(json)
                            .font(Theme.code)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}
