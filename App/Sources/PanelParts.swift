import LoomKit
import SwiftUI

/// Small pieces the inspector panes and the dock share, so each pane is only
/// its own content.

/// A titled group in an inspector pane, with an optional control at its end.
struct PanelSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.headline)
                Spacer(minLength: 8)
                trailing
            }
            content
        }
    }
}

/// Quiet explanatory text, for what a panel does not know or has not read.
struct Quiet: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A borderless icon button with a name a screen reader can say.
struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Re-runs `body` with a debounce whenever `trigger` changes, so a burst of
/// changes (a run's tool calls landing one after another) causes one read.
extension View {
    func debouncedTask<T: Equatable & Sendable>(
        id trigger: T, after delay: Duration = .milliseconds(400), _ body: @escaping @MainActor () -> Void
    ) -> some View {
        task(id: trigger) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await body()
        }
    }
}
