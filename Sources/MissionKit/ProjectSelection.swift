import Foundation

/// What the Projects destination has open.
public enum ProjectSelection: Sendable, Equatable, Hashable {
    /// A project's own page: its router, the messages it declined and its workers.
    case project(String)
    /// One ticket of a project.
    case ticket(project: String, ticket: String)

    /// The project the selection is in.
    public var project: String {
        switch self {
        case .project(let id): return id
        case .ticket(let project, _): return project
        }
    }

    /// The selection once the projects have been read again: itself while the
    /// project, and the ticket on the project's page, still exist, and otherwise
    /// the project's page, or nothing when the project is gone. A project whose
    /// board did not read keeps its ticket selected, since no read says the
    /// ticket is gone.
    public static func settled(_ selection: ProjectSelection?, projects: [ProjectState]) -> ProjectSelection? {
        guard let selection else { return nil }
        guard let project = projects.first(where: { $0.id == selection.project }) else { return nil }
        guard case .ticket(_, let ticket) = selection, let page = project.page else { return selection }
        return page.tickets.contains { $0.id == ticket } || (page.leftOut ?? 1) > 0 ? selection : .project(project.id)
    }
}
