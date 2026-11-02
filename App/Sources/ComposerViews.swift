import AppKit
import LoomKit
import SwiftUI
import UniformTypeIdentifiers

/// The editor and everything that belongs to it.
///
/// A busy strand takes two kinds of input. Return queues the text behind the
/// current turn, where the daemon holds it, and the steer chord (⌘↩) folds it into
/// the turn already running. An idle strand takes either as a new turn. While the
/// draft begins with a slash, a list of commands follows the cursor, and the
/// arrow keys, Tab, Return and Escape drive it instead of the editor.
struct Composer: View {
    let controller: SessionController
    @FocusState private var isFocused: Bool
    @State private var isChoosingFiles = false
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var composer = controller.composer
        let busy = controller.isBusy
        let rows = composer.suggestions(catalogue: controller.catalogue)
        let isEmpty = composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composer.images.isEmpty

        VStack(alignment: .leading, spacing: 8) {
            if !rows.isEmpty {
                CommandList(rows: rows, selection: composer.selection) { composer.accept($0) }
            }
            if !composer.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(composer.images) { image in
                            AttachmentChip(image: image) { composer.removeImage(image.id) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            TextField(placeholder(busy), text: $composer.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .lineLimit(1...12)
                .focused($isFocused)
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                    if let chosen = chosen(rows, composer.selection) {
                        composer.accept(chosen)
                        if !chosen.takesArgument { composer.submit(requested: .send, controller: controller) }
                        return .handled
                    }
                    composer.submit(requested: press.modifiers.contains(.command) ? .steer : .queue, controller: controller)
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    guard !rows.isEmpty else { return .ignored }
                    composer.move(by: press.key == .upArrow ? -1 : 1, count: rows.count)
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard let chosen = chosen(rows, composer.selection) else { return .ignored }
                    composer.accept(chosen)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if !rows.isEmpty {
                        composer.dismissList()
                        return .handled
                    }
                    if controller.isBusy {
                        controller.abort()
                        return .handled
                    }

                    // Away from the main strand, Escape returns to it.
                    if controller.focusedStrand != "main" {
                        controller.focusedStrand = "main"
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: composer.draft) {
                    if composer.draft.hasPrefix("/") { composer.loadCatalogue(controller) }
                }
                .accessibilityLabel("Message")

            HStack(spacing: 10) {
                Group {
                    if let model = controller.strand?.model {
                        Label(model, systemImage: "cpu")
                    }
                    if let tokens = controller.totalTokens, tokens > 0 {
                        Text("\(tokens.formatted(.number.notation(.compactName))) tokens")
                    }
                    if let cost = controller.totalCost, cost > 0 {
                        Text(cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                    }
                    ComposerFigures(controller: controller)
                    if controller.peers.count > 1 {
                        Label("\(controller.peers.count)", systemImage: "person.2")
                            .help(controller.peers.map { "\($0.name) (\($0.role))" }.joined(separator: ", "))
                    }
                }
                .font(Theme.meta)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    isChoosingFiles = true
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Attach images")
                .accessibilityLabel("Attach images")

                if busy, isEmpty {
                    Button {
                        controller.abort()
                    } label: {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Stop this run (⎋)")
                    .accessibilityLabel("Stop this run")
                } else if busy {
                    Button("Steer") {
                        composer.submit(requested: .steer, controller: controller)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Fold this into the run in progress (⌘↩)")
                    .accessibilityLabel("Steer this run")

                    Button {
                        composer.submit(requested: .queue, controller: controller)
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .help("Run this after the current turn (↩)")
                    .accessibilityLabel("Queue message")
                } else {
                    Button {
                        composer.submit(requested: .send, controller: controller)
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(isEmpty)
                    .help("Send (↩)")
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radiusFloating))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Theme.radiusFloating)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTarget) { providers in
            composer.ingest(providers)
            return true
        }
        .fileImporter(isPresented: $isChoosingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { composer.attach(data, name: url.lastPathComponent) }
            }
        }
        .onAppear {
            isFocused = true
            PasteBridge.install()
        }
        .onChange(of: isFocused, initial: true) {
            if isFocused { PasteBridge.target = composer }
        }
    }

    private func chosen(_ rows: [SlashCommand.Suggestion], _ selection: Int) -> SlashCommand.Suggestion? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    private func placeholder(_ busy: Bool) -> String {
        busy ? "Queue a message, or steer this run (⌘↩)…" : "Message \(StrandName.display(controller.focusedStrand))…"
    }
}

/// The command list that follows the draft. It is drawn flat inside the composer's
/// glass, with the highlighted row tinted, and a row can be clicked as well.
private struct CommandList: View {
    let rows: [SlashCommand.Suggestion]
    let selection: Int
    let choose: (SlashCommand.Suggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(rows.prefix(8).enumerated()), id: \.element.id) { index, row in
                Button {
                    choose(row)
                } label: {
                    HStack(spacing: 10) {
                        Text(row.command).font(Theme.code)
                        Text(row.summary).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(index == selection ? Theme.tintStrong : .clear, in: .rect(cornerRadius: Theme.radiusInner))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Command \(row.command)")
                .accessibilityValue(index == selection ? "Selected" : "")
            }
        }
        .padding(.bottom, 4)
    }
}

private struct AttachmentChip: View {
    let image: ImageAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail = NSImage(data: image.data) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(.rect(cornerRadius: 4))
            }
            Text(image.name).font(Theme.caption).lineLimit(1).truncationMode(.middle)
            Text(image.data.count.formatted(.byteCount(style: .file))).font(Theme.meta).foregroundStyle(.secondary)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(image.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.tint, in: .rect(cornerRadius: Theme.radiusInner))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attached \(image.name)")
    }
}

// MARK: Above the editor

/// Lines for what was sent and not yet taken, held inputs the daemon will run,
/// the notice after a command and the side-question panel.
struct ComposerStatus: View {
    let controller: SessionController

    var body: some View {
        let composer = controller.composer
        VStack(spacing: 6) {
            if let board = composer.btw {
                BtwPanel(board: board) { composer.closeBtw() }
            }
            ForEach(composer.ledger.lines) { line in
                PendingLine(line: line)
            }
            ForEach(controller.pendingInputs.filter { $0.strand == controller.focusedStrand }) { input in
                HeldInput(input: input, controller: controller)
            }
            if let notice = composer.notice {
                NoticeLine(notice: notice) { composer.dismissNotice() }
            }
        }
    }
}

private struct PendingLine: View {
    let line: PendingDraft

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini).frame(width: 14)
            Text(line.text).lineLimit(1)
            Spacer()
            Text(line.delivery == .steer ? "steering" : line.delivery == .queue ? "queuing" : "sending")
                .font(Theme.meta)
                .foregroundStyle(.secondary)
        }
        .font(Theme.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sending: \(line.text)")
    }
}

/// An input the daemon holds until its strand can take it. The person who
/// submitted it can open it to edit, or withdraw it, and the daemon refuses anyone
/// else, so the controls follow the `editable` flag it sent.
private struct HeldInput: View {
    let input: PendingInput
    let controller: SessionController
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        @Bindable var composer = controller.composer
        let isEditing = composer.editing?.id == input.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text(input.text).lineLimit(1)
                Spacer()
                Text(input.kind == "steer" ? "next step" : "queued")
                    .font(Theme.meta)
                    .foregroundStyle(.secondary)
                if input.editable, !isEditing {
                    Button {
                        composer.beginEdit(input, controller: controller)
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Edit this queued message")
                    .accessibilityLabel("Edit queued message")

                    Button {
                        composer.remove(input, controller: controller)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Take this out of the queue")
                    .accessibilityLabel("Remove queued message")
                }
            }
            if isEditing, let edit = composer.editing {
                TextField("Queued message", text: Binding(
                    get: { composer.editing?.text ?? edit.text },
                    set: { composer.editing?.text = $0 }
                ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(8)
                    .background(Theme.tint, in: .rect(cornerRadius: Theme.radiusInner))
                    .disabled(edit.isLoading)
                    .focused($isEditorFocused)
                    .onAppear { isEditorFocused = true }
                    .onChange(of: edit.isLoading) { isEditorFocused = true }
                    .accessibilityLabel("Edit queued message text")
                HStack {
                    Spacer()
                    Button("Cancel") { composer.editing = nil }
                        .buttonStyle(.bordered)
                    Button("Save") { composer.saveEdit(controller: controller) }
                        .buttonStyle(.borderedProminent)
                        .disabled(edit.isLoading)
                }
                .controlSize(.small)
            }
        }
        .font(Theme.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radius))
    }
}

private struct NoticeLine: View {
    let notice: ComposerModel.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(notice.text)
                .font(Theme.caption)
                .foregroundStyle(notice.tone == .warning ? Theme.failure : .secondary)
                .lineLimit(8)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.text)
    }
}

/// The attachment-private side question and its answers.
private struct BtwPanel: View {
    let board: JSONValue
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Side question").font(Theme.label)
                if let status = board["status"]?.string {
                    Text(status).font(Theme.meta).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close side question")
            }
            ForEach(Array((board["exchanges"]?.array ?? []).enumerated()), id: \.offset) { _, exchange in
                Text(exchange["question"]?.string ?? "").font(Theme.caption).foregroundStyle(.secondary)
                Text(exchange["answer"]?.string ?? "").font(Theme.body).textSelection(.enabled)
            }
            if let notice = board["notice"]?.string, !notice.isEmpty {
                Text(notice).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radius))
    }
}
