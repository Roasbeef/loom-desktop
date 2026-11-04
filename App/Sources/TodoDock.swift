import LoomKit
import SwiftUI

/// The strand's todo board, pinned above the composer.
///
/// The agent writes the board with its `todo` tool and follows it as it works,
/// so this is the quickest answer to what it is doing and how far along it is.
/// Closed, the dock is one line naming the active task and the progress. Open,
/// it lists every phase with each task's state. State is shown by shape as well
/// as tone: a ring is waiting, a filled dot is the active task, a check is
/// done, a dash is dropped, and a blocked task is amber because it waits on a
/// person.
///
/// It opens while the strand is running and closes to its one line when the run
/// ends, so an idle session does not give a sixth of its window to a finished
/// plan. A person's own open or close holds until the next run starts or ends.
struct TodoDock: View {
    let board: TodoBoard
    let isBusy: Bool
    @State private var isOpen: Bool

    init(board: TodoBoard, isBusy: Bool) {
        self.board = board
        self.isBusy = isBusy
        _isOpen = State(initialValue: isBusy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").foregroundStyle(.secondary)
                    Text(headline).font(Theme.label).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(board.progress).font(Theme.meta).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Todo board")
            .accessibilityValue("\(board.progress) · \(headline)")
            .onChange(of: isBusy) {
                withAnimation(.smooth(duration: 0.18)) { isOpen = isBusy }
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(board.phases) { phase in
                        PhaseView(phase: phase)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radius))
    }

    /// What the agent is on now, or how the board ended.
    private var headline: String {
        if let active = board.active { return active.task.text }
        let counts = board.tally
        return counts.closed == counts.total ? "All tasks closed" : "No task is active"
    }
}

private struct PhaseView: View {
    let phase: TodoBoard.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(phase.name).font(Theme.caption).foregroundStyle(.secondary)
                Text("\(phase.tally.closed)/\(phase.tally.total)").font(Theme.meta).foregroundStyle(.tertiary)
            }
            ForEach(phase.tasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    glyph(task.status)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.text)
                            .font(.system(size: 12, weight: task.status == .active ? .semibold : .regular))
                            .strikethrough(task.status == .dropped)
                            .foregroundStyle(task.status.isClosed ? .secondary : .primary)
                        if case .blocked(let reason?) = task.status {
                            Text(reason).font(Theme.caption).foregroundStyle(Theme.attention)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(task.text), \(task.status.word)")
            }
        }
    }

    @ViewBuilder
    private func glyph(_ status: TodoBoard.Status) -> some View {
        Group {
            switch status {
            case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .active: Image(systemName: "circle.fill").foregroundStyle(Theme.working)
            case .done: Image(systemName: "checkmark").foregroundStyle(.secondary)
            case .dropped: Image(systemName: "minus").foregroundStyle(.tertiary)
            case .blocked: Image(systemName: "diamond.fill").foregroundStyle(Theme.attention)
            }
        }
        .font(.system(size: 9))
        .frame(width: 12)
    }
}
