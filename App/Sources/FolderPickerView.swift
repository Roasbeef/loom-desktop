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

/// What the picker draws: where the choices come from, and what a choice does.
struct FolderPickerSource {
    var recent: [String]
    var projects: [ProjectRef]
    var found: [String]

    /// Whether the folder can be browsed with the system panel and judged on this
    /// Mac. A remote daemon's folders and an executor's names cannot.
    var canOpenPanel: Bool
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
    @State private var selection = 0
    @FocusState private var isSearchFocused: Bool

    private var sections: PickerSections {
        FolderPicker.sections(query: query, recent: source.recent, projects: source.projects, found: source.found)
    }

    var body: some View {
        let sections = sections
        let rows = sections.all
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
                .onChange(of: query) { selection = 0 }

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
                        section("Recent", sections.recent, rows: rows)
                        section("Projects", sections.projects, rows: rows)
                        section("Folders", sections.found, rows: rows)
                        if !sections.typedLeads { section("Use what you typed", sections.typed, rows: rows) }
                        if rows.isEmpty {
                            Text("Nothing matches.")
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                }
                .onChange(of: selection) {
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
        .onAppear { isSearchFocused = true }
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
                        isSelected: index == selection,
                        canForget: choice.kind == .recent && source.canOpenPanel,
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
        selection = min(max(selection + step, 0), rows.count - 1)
    }

    private func pick(_ rows: [PickerChoice]) {
        guard rows.indices.contains(selection) else { return }
        choose(rows[selection])
    }

    private func choose(_ choice: PickerChoice) {
        source.onPick(choice.path)
        dismiss()
    }

    private func openPanel() {
        dismiss()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { source.onPick(url.path) }
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
