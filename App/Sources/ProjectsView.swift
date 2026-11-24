import LoomKit
import MissionKit
import SwiftUI

// The Projects destination: each project with its tickets grouped by the daemon's
// stage words, and beside it the open ticket or the project's own page. A project's
// page shows its router, the messages the router declined to route, and the worker
// of each ticket, because project mode is one long-lived router per repository
// that decides what becomes work, and each ticket runs in a worker session of its
// own.
//
// The list holds one page of each board (the daemon's page zero, twenty tickets,
// needs-a-person first). A project with more says how many it left out.

struct ProjectsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let projects = model.projectStates
        Group {
            if projects.isEmpty {
                ContentUnavailableView(
                    "No projects", systemImage: "folder.badge.gearshape",
                    description: Text(model.daemons.contains { $0.projectsAnswered }
                        ? "This daemon holds no project yet."
                        : "No connected daemon has project mode on.")
                )
            } else {
                HSplitView {
                    List(selection: $model.projectSelection) {
                        ForEach(projects) { project in ProjectSection(project: project) }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
                    detail
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Projects")
        .navigationSubtitle(subtitle(projects))
        .accessibilityIdentifier("projects-view")
    }

    @ViewBuilder
    private var detail: some View {
        switch model.projectSelection {
        case .ticket(let project, let ticket)?: TicketPane(project: project, ticket: ticket).id("\(project)/\(ticket)")
        case .project(let id)?: ProjectPanel(project: id).id(id)
        case nil:
            ContentUnavailableView("Pick a ticket", systemImage: "ticket", description: Text("Choose a ticket, or a project's router, in the list."))
        }
    }

    private func subtitle(_ projects: [ProjectState]) -> String {
        let need = projects.reduce(0) { $0 + ProjectRule.needing($1.summary) }
        return need == 0 ? "" : "\(need) waiting"
    }
}

private struct ProjectSection: View {
    @Environment(AppModel.self) private var model
    let project: ProjectState

    var body: some View {
        Section {
            Label("Router and workers", systemImage: "point.3.connected.trianglepath.dotted")
                .tag(ProjectSelection.project(project.id))
            if let page = project.page {
                ForEach(ProjectRule.groups(page.tickets), id: \.stage.word) { group in
                    HStack(spacing: 6) {
                        Text(verbatim: group.stage.word).font(Theme.meta)
                        Text("\(group.tickets.count)").font(Theme.caption).foregroundStyle(.tertiary)
                        Text(verbatim: ProjectRule.gloss(group.stage)).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.top, 4)
                    ForEach(group.tickets) { ticket in
                        TicketRow(ticket: ticket).tag(ProjectSelection.ticket(project: project.id, ticket: ticket.id))
                    }
                }
                if page.total > page.tickets.count {
                    Text("\(page.total - page.tickets.count) more tickets are not shown.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                if page.unreadable > 0 {
                    Text("\(page.unreadable) tickets could not be read.").font(Theme.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("The board has not been read.").font(Theme.caption).foregroundStyle(.secondary)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: project.summary.name).font(.headline)
                Text(verbatim: ProjectRule.countWords(project.summary)).font(Theme.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("project/\(project.id)")
        }
    }
}

private struct TicketRow: View {
    let ticket: ProjectTicket

    var body: some View {
        HStack {
            Text(verbatim: ProjectRule.titleWords(ticket)).lineLimit(1)
            Spacer(minLength: 6)
            if let age = ProjectRule.age(ticket, now: Int(Date().timeIntervalSince1970 * 1000)) {
                Text(age.words).font(Theme.caption.monospacedDigit()).foregroundStyle(age.isOverdue ? Theme.attention : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ticket/\(ticket.id)")
    }
}

/// A project's page: the router, what it declined, and the workers.
struct ProjectPanel: View {
    @Environment(AppModel.self) private var model
    let project: String

    private var state: ProjectState? { model.projectStates.first { $0.id == project } }

    var body: some View {
        if let state {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: state.summary.name).font(.system(size: 20, weight: .semibold))
                        Text(verbatim: state.summary.workspace).font(Theme.meta).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(verbatim: ProjectRule.health(state.summary)).font(Theme.meta).foregroundStyle(.secondary)
                    }
                    router(state)
                    declined(state)
                    workers(state)
                }
                .padding(24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("This project is not listed", systemImage: "folder")
        }
    }

    // MARK: Router

    private func record(_ id: String?) -> SessionRecord? {
        id.flatMap { id in model.sessions.first { $0.id == id } }
    }

    private func router(_ state: ProjectState) -> some View {
        let session = record(state.summary.routerSession)
        return PaneSection("Router") {
            Text(verbatim: ProjectRule.routerWords(session?.state)).font(Theme.body)
            if let page = state.page, page.replies > 0 {
                Text("\(page.replies) replies queued").font(Theme.caption).foregroundStyle(.secondary)
            }
            if let session {
                Button("Open Router Session") { model.destination = .session(session.id) }.buttonStyle(.bordered)
            }
            // The daemon serves what the router could not decide, and no log of what
            // it did decide, so the page says only what it can read.
            Text("The daemon lists the messages the router declined three times. It does not serve a log of the rest of its decisions.")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private func declined(_ state: ProjectState) -> some View {
        PaneSection("Not routed") {
            let unrouted = state.page?.unrouted ?? []
            if unrouted.isEmpty {
                Text("The router has declined nothing.").font(Theme.caption).foregroundStyle(.secondary)
            }
            ForEach(unrouted) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Untrusted text from \(item.actor) via \(item.source)").font(Theme.caption).foregroundStyle(.secondary)
                    Text(verbatim: item.text).font(Theme.body).textSelection(.enabled)
                    Text(verbatim: "Reason: \(item.reason)").font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Workers

    private func workers(_ state: ProjectState) -> some View {
        PaneSection("Workers") {
            let tickets = (state.page?.tickets ?? []).filter { $0.session != nil }
            if tickets.isEmpty {
                Text("No ticket has a worker session.").font(Theme.caption).foregroundStyle(.secondary)
            }
            ForEach(tickets) { ticket in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: ProjectRule.titleWords(ticket)).lineLimit(1)
                        Text(verbatim: "\(ticket.stage.word) \u{00B7} session \(record(ticket.session)?.state.label.lowercased() ?? "not listed")")
                            .font(Theme.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Ticket") { model.projectSelection = .ticket(project: state.id, ticket: ticket.id) }.buttonStyle(.borderless)
                    if let session = ticket.session, record(session) != nil {
                        Button("Open Worker") { model.destination = .session(session) }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
