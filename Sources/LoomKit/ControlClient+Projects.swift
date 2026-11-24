import Foundation

// The control commands behind project mode (loom docs/client-protocol.md section
// 3.32). They are the owner's alone and take no epoch. A daemon that started no
// project table answers every one `not_found`, and one that predates a command
// answers it as unknown, which `LoomError.isUnknownCommand` reports. The reads are
// `projects.list`, `projects.board` and `projects.ticket`; every other command
// changes a ticket and replies an echo, and a refusal carries the daemon's own
// sentence in its message.

extension ControlClient {
    /// The owner's projects with their counts by stage.
    public func projects() async throws -> [ProjectSummary] {
        ProjectList.decode(try await request("projects.list", body: [:]))
    }

    /// One page of a project's board, needs-a-person first. Page zero also carries
    /// the router's queued replies and the messages it declined to route.
    public func projectBoard(_ project: String, page: Int = 0) async throws -> ProjectPage {
        let body = try await request("projects.board", body: [
            "project": .string(project), "page": .int(Int64(page)),
        ])
        guard let page = ProjectPage(body) else {
            throw LoomError.protocolViolation("projects.board returned no board")
        }
        return page
    }

    /// One ticket with its assignments and the messages on its opening thread.
    public func projectTicket(_ project: String, ticket: String) async throws -> ProjectDetail {
        let body = try await request("projects.ticket", body: ["project": .string(project), "ticket": .string(ticket)])
        guard let detail = ProjectDetail(body) else {
            throw LoomError.protocolViolation("projects.ticket returned no ticket")
        }
        return detail
    }

    /// Answers the ticket's open question, echoing its `seq`. A question that has
    /// moved on is refused `conflict` and records nothing.
    public func answerTicket(_ project: String, ticket: String, seq: Int, text: String) async throws {
        _ = try await request("projects.answer", body: [
            "project": .string(project), "ticket": .string(ticket),
            "seq": .int(Int64(seq)), "text": .string(text),
        ])
    }

    /// One of the commands that names a ticket and replies an echo.
    public func actOnTicket(_ act: TicketAct, project: String, ticket: String) async throws {
        _ = try await request(act.command, body: ["project": .string(project), "ticket": .string(ticket)])
    }
}

/// An act on a ticket that needs only its address.
public enum TicketAct: String, Sendable, Equatable, CaseIterable {
    case close, retry, recheck, publish, stop

    /// The wire command.
    public var command: String { "projects.\(rawValue)" }
}
