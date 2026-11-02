import LoomKit
import MissionKit
import SubstrateKit
import SwiftUI

/// The fleet at a glance: who is waiting, who is working, and how full the
/// daemon is. Colour and motion appear only where an agent is doing something.
struct MissionControlView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = Filter.active

    enum Filter: String, CaseIterable, Identifiable {
        case active = "Active"
        case all = "All"
        var id: Self { self }
    }

    private var visible: [AgentCard] {
        switch filter {
        case .active: return model.cards.filter { $0.liveness != .off }
        case .all: return model.cards
        }
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SummaryStrip()

                let waiting = model.attention
                if !waiting.isEmpty {
                    NeedsYouStrip(items: Array(waiting.prefix(4)), total: waiting.count)
                }

                if visible.isEmpty {
                    ContentUnavailableView {
                        Label("No agents are running", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Dispatch an agent, or switch to All to see saved sessions.")
                    } actions: {
                        Button("Dispatch Agent…") { model.isDispatching = true }
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(visible) { card in
                            AgentCardView(card: card)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Mission Control")
        .toolbar {
            ToolbarItem {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}

/// Counts across the fleet, in one line.
private struct SummaryStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cards = model.cards
        HStack(spacing: 22) {
            stat("Needs you", cards.filter { $0.liveness == .needsYou }.count, .needsYou)
            stat("Working", cards.filter { $0.liveness == .working }.count, .working)
            stat("Idle", cards.filter { $0.liveness == .idle }.count, .idle)
            stat("Saved", cards.filter { $0.liveness == .off }.count, .off)
            Spacer()
            if let status = model.status {
                HStack(spacing: 8) {
                    CapacityMeter(used: status.resident, capacity: status.capacity)
                    Text("\(status.resident) of \(status.capacity) slots")
                        .font(Theme.meta)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stat(_ label: String, _ count: Int, _ liveness: AgentCard.Liveness) -> some View {
        HStack(spacing: 6) {
            StatusDot(liveness: liveness)
            Text("\(count)").font(.system(.title3, design: .rounded).weight(.medium).monospacedDigit())
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct NeedsYouStrip: View {
    @Environment(AppModel.self) private var model
    let items: [AttentionItem]
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Button {
                    model.destination = .inbox
                } label: {
                    HStack(spacing: 10) {
                        Text(item.kind.title)
                            .font(Theme.meta)
                            .foregroundStyle(Theme.attention)
                            .frame(width: 112, alignment: .leading)
                        Text(item.agent).fontWeight(.medium).lineLimit(1)
                        Text(item.title).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if item.id != items.last?.id { Divider() }
            }
            if total > items.count {
                Divider()
                Button("\(total - items.count) more in the inbox") { model.destination = .inbox }
                    .buttonStyle(.link)
                    .padding(9)
            }
        }
        .surface(fill: Theme.attention.opacity(0.06))
    }
}

/// One agent's dossier. A Loom session and a Substrate agent share this card,
/// because a person dispatching work should not need to care which runs it.
private struct AgentCardView: View {
    @Environment(AppModel.self) private var model
    let card: AgentCard
    @State private var steer = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(card.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HeartbeatTrace(liveness: card.liveness)
                Spacer(minLength: 0)
                if card.waitingCount > 0 {
                    Text("\(card.waitingCount)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(Theme.attention)
                }
            }

            HStack(spacing: 6) {
                Text(cardContext)
            }
            .font(Theme.meta)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if !card.digest.isEmpty {
                // The digest is one flattened line, so fences and emphasis are noise.
                Text(card.digest.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""))
                    .font(.callout)
                    .lineLimit(3)
            }

            if !card.lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(card.lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(line.label).font(Theme.meta).foregroundStyle(.secondary).lineLimit(1)
                            Text(line.text).font(.caption).lineLimit(1)
                        }
                    }
                }
            }

            if card.liveness != .off {
                TextField("Steer \(card.name)…", text: $steer)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .surface(fill: Color(nsColor: .textBackgroundColor), radius: 6)
                    .onSubmit(send)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.failure)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
        .onTapGesture {
            if case .loom(let id) = card.origin {
                model.destination = .session(id)
            }
        }
    }

    private var cardContext: String {
        var parts = [card.context]
        if let model = card.model { parts.append(model) }
        if case .substrate = card.origin { parts.append("substrate") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func send() {
        let text = steer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        steer = ""
        error = nil
        switch card.origin {
        case .loom(let id):
            Task {
                guard let controller = model.attach(id) else { return }
                await controller.waitUntilAdopted()
                controller.send(text: text)
            }
        case .substrate:
            Task {
                do {
                    try await model.steerSubstrateAgent(named: card.name, body: text)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

/// One place to answer everything. Threads group by what they need, and nothing
/// reaches an agent until the person answers.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AttentionItem.ID?

    var body: some View {
        let items = model.attention
        HSplitView {
            List(selection: $selection) {
                ForEach(AttentionItem.Kind.allCases, id: \.self) { kind in
                    let group = items.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Section(kind.title) {
                            ForEach(group) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).lineLimit(2)
                                    Text(item.agent).font(Theme.meta).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.vertical, 2)
                                .tag(item.id)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)

            Group {
                if let item = items.first(where: { $0.id == selection }) ?? items.first {
                    AttentionDetail(item: item).id(item.id)
                } else {
                    ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Inbox")
    }
}

private struct AttentionDetail: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem
    @State private var reply = ""
    @State private var error: String?
    @State private var isSent = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.kind.title).font(Theme.meta).foregroundStyle(Theme.attention)
                    Text(item.title).font(.title3.weight(.medium)).textSelection(.enabled)
                    Text(item.agent).font(Theme.meta).foregroundStyle(.secondary)
                }
                actions
                if let error {
                    Text(error).font(.callout).foregroundStyle(Theme.failure)
                }
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.source {
        case .loom(let sessionID, let escalation):
            if let escalation, let controller = model.attached[sessionID] {
                ApprovalCard(record: escalation, controller: controller)
            } else if !item.detail.isEmpty {
                MarkdownText(source: item.detail)
            }
            Button("Open session") { model.destination = .session(sessionID) }
                .buttonStyle(.link)

        case .substrate(_, let threadID, let planReviewID):
            if !item.detail.isEmpty {
                MarkdownText(source: item.detail)
            }
            if isSent {
                Label("Sent", systemImage: "checkmark").foregroundStyle(.secondary)
            } else {
                TextEditor(text: $reply)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 90)
                    .surface()
                if let planReviewID {
                    HStack {
                        Spacer()
                        Button("Reject") { decide(planReviewID, .rejected) }
                        Button("Request changes") { decide(planReviewID, .changesRequested) }
                        Button("Approve") { decide(planReviewID, .approved) }
                            .buttonStyle(.borderedProminent)
                    }
                } else if let threadID {
                    HStack {
                        Spacer()
                        Button("Send") {
                            run { try await model.reply(threadID: threadID, body: reply) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(reply.isEmpty)
                    }
                }
            }
        }
    }

    private func decide(_ id: String, _ decision: PlanDecision) {
        run { try await model.decide(planReviewID: id, decision: decision, comment: reply) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        Task {
            do {
                try await action()
                isSent = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
