import LoomKit
import SwiftUI

/// Every strand in the session, as one card each, and a page for the one chosen.
///
/// A card is a name, a state and one line saying what the strand is doing, so a
/// column of them reads at a glance. A strand that has finished is moved into a
/// closed group saying how each ended, so the live ones stay on top. Choosing a
/// card focuses that strand's transcript, and its page adds the task, model,
/// context size, the tools running now and the last few it ran.
struct StrandsPane: View {
    let controller: SessionController
    @State private var detail: String?
    @State private var showsSettled = false
    @State private var isForking = false

    private var lines: [StrandLine] { controller.strandLines }
    private var main: StrandLine? { lines.first { $0.id == "main" } }

    var body: some View {
        Group {
            if let detail, let line = lines.first(where: { $0.id == detail }) {
                StrandDetail(line: line, controller: controller) { self.detail = nil }
            } else {
                list
            }
        }
        // Escape leaves a strand's page for the list, as the breadcrumb does.
        .onExitCommand { detail = nil }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(lines.count) strand\(lines.count == 1 ? "" : "s")").font(.headline)
                Spacer()
                Button {
                    isForking = true
                } label: {
                    Label("Fork", systemImage: "arrow.triangle.branch")
                }
                .controlSize(.small)
                .help("Fork the focused strand at its current point")
                .accessibilityLabel("Fork Strand")
                .popover(isPresented: $isForking, arrowEdge: .bottom) {
                    ForkForm(controller: controller) { isForking = false }
                }
            }
            // The main strand is always listed, since it is the conversation. Any
            // other strand that has ended its run moves to a closed group, so the
            // live ones stay on top.
            ForEach(lines.filter { $0.id == "main" || !$0.status.isSettled }) { line in
                card(line)
            }
            let settled = lines.filter { $0.id != "main" && $0.status.isSettled }
            if !settled.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.15)) { showsSettled.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showsSettled ? 90 : 0))
                        Text("Settled (\(settled.count))").font(Theme.label)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .accessibilityLabel("Settled strands")
                .accessibilityValue(showsSettled ? "Expanded" : "Collapsed")
                if showsSettled {
                    ForEach(settled) { card($0) }
                }
            }
            if !controller.remoteChildren.isEmpty {
                Text("On other machines")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                ForEach(controller.remoteChildren) { child in
                    Button {
                        controller.peek(child: child)
                    } label: {
                        RemoteChildRow(child: child)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func card(_ line: StrandLine) -> some View {
        let isFocused = line.id == controller.focusedStrand
        return HStack(spacing: 4) {
            Button {
                controller.focusedStrand = line.id
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    StrandGlyph(status: line.status).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(line.name)
                                .font(.system(size: 13, weight: isFocused ? .semibold : .regular))
                            // The model is named only where it differs from the
                            // main strand's, since otherwise it is the same news
                            // on every card.
                            if let model = line.model, model != main?.model {
                                Text(model).font(Theme.meta).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if let tokens = line.contextTokens {
                                Text(PanelWords.count(tokens)).font(Theme.meta).foregroundStyle(.tertiary)
                            }
                        }
                        Text(line.statusLine(elapsed: nil))
                            .font(Theme.caption)
                            .foregroundStyle(line.status == .needsApproval ? Theme.attention : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(isFocused ? Theme.tintStrong : .clear, in: .rect(cornerRadius: Theme.radiusInner))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Strand \(line.name)")
            .accessibilityValue(line.statusLine(elapsed: nil))

            IconButton(symbol: "info.circle", label: "Details for \(line.name)") { detail = line.id }
                .foregroundStyle(.tertiary)
        }
    }
}

/// A strand's state as a shape, so it survives colour blindness: a diamond needs
/// a person, a filled dot is working, a check is finished, a cross is failed,
/// a square is halted and a ring is at rest.
struct StrandGlyph: View {
    let status: StrandLine.Status

    var body: some View {
        Group {
            switch status {
            case .needsApproval:
                Rectangle().fill(Theme.attention).frame(width: 6.5, height: 6.5).rotationEffect(.degrees(45))
            case .working:
                Circle().fill(Theme.working).frame(width: 7, height: 7)
            case .finished:
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.failure)
            case .halted:
                Rectangle().fill(Color.secondary).frame(width: 6, height: 6)
            case .idle:
                Circle().strokeBorder(Color.secondary, lineWidth: 1.2).frame(width: 7, height: 7)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

/// One strand's page: what it was asked, what it runs on, how large its context
/// is, what it is running now and what it ran last.
private struct StrandDetail: View {
    let line: StrandLine
    let controller: SessionController
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: back) {
                Label("All strands", systemImage: "chevron.left").font(Theme.label)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("All Strands")

            HStack(spacing: 8) {
                StrandGlyph(status: line.status)
                Text(line.name).font(.headline)
                Spacer()
                Button("Focus") { controller.focusedStrand = line.id }
                    .controlSize(.small)
                    .disabled(controller.focusedStrand == line.id)
            }
            Text(line.statusLine(elapsed: nil)).font(Theme.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                fact("Task", line.task ?? "Not recorded")
                fact("Model", line.model ?? "Not recorded")
                fact("Context", line.contextTokens.map { PanelWords.count($0) + " tokens" } ?? "Not reported yet")
                if line.approvals > 0 {
                    fact("Waiting on you", "\(line.approvals) approval\(line.approvals == 1 ? "" : "s")")
                }
            }

            if !line.running.isEmpty {
                PanelSection("Running now") {
                    ForEach(Array(line.running.enumerated()), id: \.offset) { _, name in
                        Text(name).font(Theme.code)
                    }
                }
            }
            PanelSection("Recent tools") {
                if line.recent.isEmpty {
                    Quiet("No tool has run on this strand yet.")
                }
                ForEach(line.recent) { call in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: call.isRunning ? "ellipsis" : call.isError ? "xmark" : "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(call.isError ? Theme.failure : Color.secondary)
                            .frame(width: 10)
                        Text(call.name).font(Theme.code)
                        Text(call.summary).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
            Text(value).font(Theme.body).textSelection(.enabled)
        }
    }
}

/// Forks the focused strand at its current point. The new strand starts from the
/// same history and goes its own way, which is how an agent tries a second
/// approach without losing the first.
private struct ForkForm: View {
    let controller: SessionController
    let done: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fork \(StrandName.display(controller.focusedStrand))").font(.headline)
            TextField("Name for the new strand", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Name for the new strand")
                .onSubmit(fork)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Fork", action: fork).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func fork() {
        var body: [String: JSONValue] = ["strand": .string(controller.focusedStrand), "scope": "branch"]
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { body["name"] = .string(trimmed) }
        controller.run("fork", body: .object(body))
        done()
    }
}
