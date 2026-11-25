import AppKit
import LoomKit
import SwiftUI

extension AppModel {
    /// The folders below which the picker searches for any folder, not only
    /// recent ones: the home directory, as the daemon's own folder rules use.
    /// A debug build reads `LOOM_PICKER_ROOTS` (colon-separated) instead, so a
    /// scenario can search a scratch tree without writing into the home directory.
    var pickerRoots: [URL] {
        #if DEBUG
        if let roots = ProcessInfo.processInfo.environment["LOOM_PICKER_ROOTS"], !roots.isEmpty {
            return roots.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        #endif
        return [FileManager.default.homeDirectoryForCurrentUser]
    }
}

extension DaemonConnection {
    /// The projects this daemon runs, which the picker lists beside folders since
    /// a person thinks of "folder or project" as one choice. A daemon without
    /// project mode, or a failed read, has none to list.
    func pickerProjects() async -> [ProjectRef] {
        guard let control else { return [] }
        return (try? await control.listProjects()) ?? []
    }
}

/// The chip under the composer that names the folder a session will start in.
/// It shows the folder's short name and a chevron, and opens `FolderPickerPopover`.
/// Its accessibility value is the whole path, so a screen reader and a scenario
/// read the choice and not only its short name.
struct FolderChip: View {
    let workspace: String
    let placeholder: String
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(workspace.isEmpty ? placeholder : (workspace as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .font(Theme.label)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.tint, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("o")
        .help(workspace.isEmpty ? "Choose a folder (⌘O)" : "\(workspace) (⌘O)")
        .accessibilityLabel("Folder")
        .accessibilityValue(workspace)
    }
}

/// A folder chip with its popover and the folder walk behind it, which every form
/// that asks for a folder uses. The form says where its choices come from and
/// keeps the chosen folder in a binding; the chip owns whether the popover is
/// open and when the walk of the disk starts.
///
/// The walk starts when the popover first opens and not when the form does,
/// because reading Desktop, Documents and Downloads can raise a macOS privacy
/// prompt, and a person should meet that after asking to choose a folder. It is
/// bounded (`FolderIndex`), runs off the main actor, and a walk already done is
/// kept. `allowsNone` is false where a folder is required, so the list does not
/// offer "No folder".
struct FolderPickerChip: View {
    @Binding var folder: String
    let placeholder: String
    let recent: [String]
    let projects: [ProjectRef]
    let roots: [URL]
    var allowsNone = FolderPickerNone.allowed
    var canBrowseDisk = true
    var canForget = true
    var recentTitle = "Recent"
    var emptyNote = "No folders yet. Type a path."
    var forgotten: Set<String> = []
    var onForget: (String) -> Void = { _ in }
    @State private var isOpen = false
    @State private var found: [String] = []

    var body: some View {
        FolderChip(workspace: folder, placeholder: placeholder, isOpen: $isOpen)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                FolderPickerPopover(
                    source: FolderPickerSource(
                        recent: recent,
                        projects: projects,
                        found: canBrowseDisk ? found.filter { !forgotten.contains($0) } : [],
                        canOpenPanel: canBrowseDisk,
                        canForget: canForget,
                        recentTitle: recentTitle,
                        emptyNote: emptyNote,
                        currentIsChosen: !folder.isEmpty && allowsNone == .allowed,
                        current: folder,
                        onPick: { folder = $0 },
                        onForget: onForget,
                        onClear: { folder = "" }
                    ),
                    dismiss: { isOpen = false }
                )
            }
            .task(id: isOpen) {
                guard isOpen, found.isEmpty, canBrowseDisk else { return }
                let walked = await FolderIndex.scanOffMain(roots: roots)
                guard !Task.isCancelled else { return }
                found = walked
            }
    }
}

/// Whether a form may be left without a folder, which decides whether the
/// picker offers "No folder".
enum FolderPickerNone {
    case allowed
    case refused
}

/// What the picker draws: where the choices come from, and what a choice does.
struct FolderPickerSource {
    var recent: [String]
    var projects: [ProjectRef]
    var found: [String]

    /// Whether the folder can be browsed with the system panel and judged on this
    /// Mac. A remote daemon's folders and an executor's names cannot.
    var canOpenPanel: Bool

    /// Whether a recent row can be forgotten. Forgetting is this app's own list
    /// of local folders, so an executor's registered names cannot be.
    var canForget: Bool

    /// The heading of the first section: "Recent" for folders, and the registered
    /// workspaces' own name for an executor.
    var recentTitle: String

    /// What an empty list says with nothing typed.
    var emptyNote: String
    var currentIsChosen: Bool
    var current: String
    var onPick: (String) -> Void
    var onForget: (String) -> Void
    var onClear: () -> Void
}

/// The folder picker as a popover: a search field focused on open, "No folder",
/// recent folders and projects, folders found below the home directory, and
/// "Open folder…" for anything else.
///
/// Typing filters at once. The first row is selected, the arrow keys move the
/// selection and Return picks it, so the whole choice is open, a few letters,
/// Return. Escape closes the popover. Each row shows the short name with its
/// parent path dimmed beside it, so two folders of the same name differ. The row
/// of the current folder carries a checkmark.
///
/// Nothing here decides anything about the daemon: the choice becomes the
/// sheet's folder text, which the form judges while it is shown and the daemon
/// judges again when the session is created.
struct FolderPickerPopover: View {
    let source: FolderPickerSource
    let dismiss: () -> Void
    @State private var query = ""
    @State private var requested = 0
    @FocusState private var isSearchFocused: Bool

    private var sections: PickerSections {
        FolderPicker.sections(query: query, recent: source.recent, projects: source.projects, found: source.found)
    }

    /// The selected row, kept inside the list as the list changes under it.
    private func selection(in rows: [PickerChoice]) -> Int {
        min(max(requested, 0), max(rows.count - 1, 0))
    }

    var body: some View {
        let sections = sections
        let rows = sections.all
        let selection = selection(in: rows)
        VStack(spacing: 0) {
            TextField("Search folders…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .focused($isSearchFocused)
                .accessibilityLabel("Search folders")
                .onSubmit { pick(rows) }
                .onKeyPress(.downArrow) { move(1, in: rows); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: rows); return .handled }
                .onChange(of: query) { requested = 0 }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if source.currentIsChosen && query.isEmpty {
                            Button {
                                source.onClear()
                                dismiss()
                            } label: {
                                Label("No folder", systemImage: "nosign")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("No folder")
                        }
                        if sections.typedLeads { section("Use what you typed", sections.typed, rows: rows) }
                        section(source.recentTitle, sections.recent, rows: rows)
                        section("Projects", sections.projects, rows: rows)
                        section("Folders", sections.found, rows: rows)
                        if !sections.typedLeads { section("Use what you typed", sections.typed, rows: rows) }
                        if rows.isEmpty {
                            Text(query.isEmpty ? source.emptyNote : "Nothing matches.")
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                }
                .onChange(of: requested) {
                    if rows.indices.contains(selection) { proxy.scrollTo(rows[selection].id) }
                }
            }
            .frame(height: 300)

            if source.canOpenPanel {
                Divider()
                Button {
                    openPanel()
                } label: {
                    Label("Open folder…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open folder")
            }
        }
        .frame(width: 380)
        .onAppear {
            isSearchFocused = true

            // Return with nothing typed keeps the current folder.
            let rows = sections.all
            requested = rows.firstIndex { $0.path == source.current } ?? 0
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func section(_ title: String, _ choices: [PickerChoice], rows: [PickerChoice]) -> some View {
        if !choices.isEmpty {
            Section {
                ForEach(choices) { choice in
                    let index = rows.firstIndex(of: choice) ?? 0
                    FolderRow(
                        choice: choice,
                        isCurrent: choice.path == source.current,
                        isSelected: index == selection(in: rows),
                        canForget: choice.kind == .recent && source.canForget,
                        onPick: { choose(choice) },
                        onForget: { source.onForget(choice.path) }
                    )
                    .id(choice.id)
                }
            } header: {
                Text(title)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.bar)
            }
        }
    }

    // MARK: Actions

    private func move(_ step: Int, in rows: [PickerChoice]) {
        guard !rows.isEmpty else { return }
        requested = min(max(selection(in: rows) + step, 0), rows.count - 1)
    }

    private func pick(_ rows: [PickerChoice]) {
        guard !rows.isEmpty else { return }
        choose(rows[selection(in: rows)])
    }

    private func choose(_ choice: PickerChoice) {
        source.onPick(choice.path)
        dismiss()
    }

    private func openPanel() {
        dismiss()
        if let path = FolderChoice.choose() { source.onPick(path) }
    }
}

/// One row: the short name, the parent path dimmed beside it, a checkmark when it
/// is the current folder, and, for a recent folder, a way to forget it. The
/// forget control appears on the selected or hovered row, so rows stay quiet.
private struct FolderRow: View {
    let choice: PickerChoice
    let isCurrent: Bool
    let isSelected: Bool
    let canForget: Bool
    let onPick: () -> Void
    let onForget: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onPick) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                    Text(choice.name).lineLimit(1)
                    Text(choice.parent)
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                    if isCurrent { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use folder \(choice.path)")
            if canForget && (isHovered || isSelected) {
                Button(action: onForget) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Forget this folder")
                .accessibilityLabel("Forget folder \(choice.path)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isSelected ? Theme.tintStrong : Color.clear)
        .onHover { isHovered = $0 }
    }

    private var icon: String {
        switch choice.kind {
        case .project: return "square.stack.3d.up"
        case .typed: return "arrow.turn.down.right"
        case .recent, .found: return "folder"
        }
    }
}
