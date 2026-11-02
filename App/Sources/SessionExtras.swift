import LoomKit
import SwiftUI

/// The Session tab's operating sections: the goal, background jobs, schedules,
/// remembered permissions, proposals and memory.
///
/// Each section reads its own surface when the tab opens, and none draws a
/// guess. A board that has not been read says "not read yet", a jobs board says
/// it is as of its last refresh because the daemon observed it then, and a
/// surface the daemon refuses to this client says why it is empty.
struct SessionExtras: View {
    let controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GoalSection(board: GoalBoard(controller.surfaces["goal"]?["board"]), controller: controller)
            JobsSection(controller: controller)
            SchedulesSection(controller: controller)
            RememberedSection(controller: controller)
            ProposalsSection(board: ProposalBoard(controller.surfaces["proposals"]?["board"]), controller: controller)
            MemorySection(controller: controller)
        }
        .task { controller.read("goal_get") }
    }
}

// MARK: Live jobs

/// Background shell jobs the focused strand started. They outlive the call that
/// began them, so this is where a person sees that something is still running.
private struct JobsSection: View {
    let controller: SessionController

    private var board: JobsBoard? {
        JobsBoard(controller.surfaces["live_jobs"]?["board"]).flatMap { $0.strand == controller.focusedStrand ? $0 : nil }
    }

    var body: some View {
        PanelSection("Live jobs", trailing: {
            IconButton(symbol: "arrow.clockwise", label: "Refresh live jobs") { refresh() }
        }) {
            if let board {
                Quiet("\(board.total) job\(board.total == 1 ? "" : "s") · at last refresh")
                ForEach(board.jobs) { job in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PanelWords.clip(PanelWords.oneLine(job.command), 90)).font(Theme.code).lineLimit(2)
                        Text("\(job.state) · started by \(job.startedBy) · age \(PanelWords.age(milliseconds: job.ageMs)) · \(board.deadline(job))")
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if board.omitted > 0 { Quiet("\(board.omitted) more are not listed.") }
            } else if let error = controller.readFailures["live_jobs"] {
                Quiet("Jobs are not available here: \(error)")
            } else {
                Quiet("not read yet")
            }
        }
        // The board is an observation, so it is read again every few seconds
        // while this tab is open and not at all otherwise.
        .task(id: controller.focusedStrand) {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refresh() {
        controller.read("live_jobs", body: ["strand": .string(controller.focusedStrand)])
    }
}

// MARK: Schedules

/// Timers that fire text into a strand. A schedule an operator wrote in the
/// configuration file is listed but cannot be retired here.
private struct SchedulesSection: View {
    let controller: SessionController
    @State private var retiring: ScheduleRow?

    private var rows: [ScheduleRow]? { ScheduleRow.list(controller.surfaces["schedules"]) }

    var body: some View {
        PanelSection("Schedules", trailing: {
            IconButton(symbol: "arrow.clockwise", label: "Refresh schedules") { controller.read("schedules") }
        }) {
            if let rows {
                if rows.isEmpty { Quiet("Nothing is scheduled.") }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(PanelWords.oneLine(row.name)).font(Theme.label)
                            Text("→ \(StrandName.display(row.target))").font(Theme.meta).foregroundStyle(.secondary)
                            Spacer(minLength: 6)
                            if row.isOperator {
                                Text("configuration").font(Theme.caption).foregroundStyle(.tertiary)
                            } else {
                                Button("Retire") { retiring = row }
                                    .controlSize(.small)
                                    .accessibilityLabel("Retire schedule \(row.name)")
                            }
                        }
                        Text("\(PanelWords.oneLine(row.when)) · fired \(row.fired)" + (row.wake ? " · may wake" : " · steers only"))
                            .font(Theme.caption).foregroundStyle(.secondary)
                        Text(PanelWords.clip(PanelWords.oneLine(row.body), 120))
                            .font(Theme.caption).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    .accessibilityElement(children: .contain)
                }
            } else if let error = controller.readFailures["schedules"] {
                Quiet("Schedules are not available here: \(error)")
            } else {
                Quiet("not read yet")
            }
        }
        .task { controller.read("schedules") }
        .confirmationDialog(
            "Retire \(retiring?.name ?? "this schedule")?",
            isPresented: Binding(get: { retiring != nil }, set: { if !$0 { retiring = nil } })
        ) {
            Button("Retire Schedule", role: .destructive) {
                if let row = retiring {
                    controller.run("schedule_cancel", body: ["target": .string(row.target), "name": .string(row.name)])
                }
                retiring = nil
            }
        } message: {
            Text("It stops firing. A schedule a strand made can be made again.")
        }
    }
}

// MARK: Remembered permissions

/// What "Allow for This Session" left behind, with who approved each. Forgetting
/// one makes the agent ask again, and does not reach a call already running.
private struct RememberedSection: View {
    let controller: SessionController
    @State private var asking: Question?

    private struct Question: Identifiable {
        let id = UUID()
        let noun: String
        let body: JSONValue
    }

    private var board: RememberedBoard? { RememberedBoard(controller.surfaces["permissions"]?["board"]) }

    var body: some View {
        PanelSection("Remembered permissions", trailing: {
            IconButton(symbol: "arrow.clockwise", label: "Refresh permissions") { controller.read("permissions") }
        }) {
            if let board {
                if board.isEmpty {
                    Quiet("Nothing is remembered for this session.")
                } else {
                    Quiet("Allowed for the rest of this session. Forget one and the agent has to ask again.")
                }
                ForEach(board.grants) { grant in
                    entry(grant.words, provenance: grant.provenance, noun: "this permission",
                          body: board.forgetBody(grant: grant))
                }
                ForEach(board.actions) { action in
                    entry(action.tool.map { "\($0): \(PanelWords.clip(PanelWords.oneLine(action.preview ?? ""), 60))" } ?? "One exact action",
                          provenance: action.provenance, noun: "this consent", body: board.forgetBody(action: action))
                }
                if board.count > 1 {
                    Button("Forget All") {
                        asking = Question(noun: "all \(board.count) permissions", body: board.forgetAllBody)
                    }
                    .controlSize(.small)
                }
            } else if let error = controller.readFailures["permissions"] {
                Quiet("Only the daemon's owner can read these: \(error)")
            } else {
                Quiet("not read yet")
            }
        }
        .task { controller.read("permissions") }
        .confirmationDialog(
            "Forget \(asking?.noun ?? "this")?",
            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
        ) {
            Button("Forget", role: .destructive) {
                if let question = asking { controller.run("permission_forget", body: question.body) }
                asking = nil
            }
        } message: {
            Text("The agent will have to ask again.")
        }
    }

    private func entry(_ words: String, provenance: RememberedBoard.Provenance?, noun: String, body: JSONValue) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(words).font(Theme.code).textSelection(.enabled)
                Text(provenance?.words ?? "Approved before approvals were attributed")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Forget") { asking = Question(noun: noun, body: body) }
                .controlSize(.small)
                .accessibilityLabel("Forget \(words)")
        }
    }
}

// MARK: Memory

/// What the daemon remembers for the workspace, and what each run receives of
/// it. Reading it is the owner's alone, because the rows are model-written text
/// and the rules are standing instructions.
private struct MemorySection: View {
    let controller: SessionController

    private var board: MemoryBoard? { MemoryBoard(controller.surfaces["memory"]?["board"]) }

    var body: some View {
        PanelSection("Memory", trailing: {
            IconButton(symbol: "arrow.clockwise", label: "Refresh memory") { controller.read("memory_get") }
        }) {
            if let board {
                Quiet("Each run is given the notes index when injection is on. Injection is \(board.inject).")
                ForEach(board.receives) { file in
                    HStack {
                        Text(file.file).font(Theme.meta)
                        Spacer()
                        Text("\(file.state) · \(PanelWords.count(file.bytes)) bytes").font(Theme.caption).foregroundStyle(.secondary)
                    }
                }
                if board.notesAvailable {
                    Text("Notes (\(board.notesTotal))").font(Theme.label)
                    ForEach(board.notes) { note in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(note.kind) · \(PanelWords.oneLine(note.title))").font(Theme.caption)
                            if !note.description.isEmpty {
                                Text(PanelWords.oneLine(note.description)).font(Theme.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Quiet("The notes could not be read.")
                }
                if board.rulesAvailable {
                    Text("Rules (\(board.rulesTotal))").font(Theme.label)
                    ForEach(board.rules) { rule in
                        Text("\(rule.approved) · \(PanelWords.oneLine(rule.line))").font(Theme.caption)
                    }
                } else {
                    Quiet("The rules could not be read.")
                }
                if let pending = board.pendingProposals, pending > 0 {
                    Quiet("\(pending) proposed rule\(pending == 1 ? "" : "s") wait for a decision.")
                }
            } else if let error = controller.readFailures["memory_get"] {
                Quiet("Only the daemon's owner can read this: \(error)")
            } else {
                Quiet("not read yet")
            }
        }
        .task { controller.read("memory_get") }
    }
}
