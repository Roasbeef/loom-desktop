import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// Project mode: the decoders for `projects.list`, `projects.board` and
/// `projects.ticket` (`LoomKit/ProjectBoard.swift`), the rule behind the Projects
/// destination and a ticket's controls (`MissionKit/ProjectRule.swift`), and the
/// ticket rows the inbox draws (`InboxRule`), which mirror the web view's
/// `ticket_rule.gleam` and `project_board.gleam`.
final class ProjectRuleTests: XCTestCase {
    // MARK: Builders

    private func ticketJSON(
        _ id: String, stage: String, title: String? = "fix a", actions: [String] = [], session: String? = nil,
        question: JSONValue? = nil, check: JSONValue? = nil, opened: Int? = 1_000, review: String? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id), "project": "p1", "stage": .string(stage),
            "actions": .array(actions.map { .string($0) }),
        ]
        if let title { fields["title"] = .string(title) }
        if let session { fields["session"] = .string(session) }
        if let question { fields["question"] = question }
        if let check { fields["check"] = check }
        if let opened { fields["opened_ms"] = .int(Int64(opened)) }
        if let review { fields["review"] = .string(review) }
        return .object(fields)
    }

    private func ticket(_ id: String, _ stage: String, opened: Int? = 1_000, actions: [String] = []) -> ProjectTicket {
        ProjectTicket(ticketJSON(id, stage: stage, actions: actions, opened: opened))!
    }

    private func summary(counts: [String: Int] = [:], workspace: String = "/src/loom") -> ProjectSummary {
        ProjectSummary(.object([
            "id": "p1", "workspace": .string(workspace), "router_session": "s-router",
            "counts": .object(counts.mapValues { .int(Int64($0)) }),
        ]))!
    }

    private func state(_ tickets: [ProjectTicket], total: Int? = nil) -> ProjectState {
        let json: JSONValue = .object([
            "project": "p1", "revision": 4, "total": .int(Int64(total ?? tickets.count)),
            "tickets": .array(tickets.map { ticketAsJSON($0) }),
        ])
        return ProjectState(summary: summary(), page: ProjectPage(json))
    }

    private func ticketAsJSON(_ ticket: ProjectTicket) -> JSONValue {
        ticketJSON(
            ticket.id, stage: ticket.stage.word, title: ticket.title,
            actions: ticket.actions.map { action in
                switch action {
                case .answer: "answer"
                case .close: "close"
                case .retry: "retry"
                case .recheck: "recheck"
                case .publish: "publish"
                case .stop: "stop"
                case .unknown(let word): word
                }
            },
            session: ticket.session, question: ticket.question.map { ["seq": .int(Int64($0.seq)), "text": .string($0.text)] },
            opened: ticket.openedMs
        )
    }

    private func ref(_ ticket: ProjectTicket) -> ProjectTicketRef {
        ProjectTicketRef(project: "p1", projectName: "loom", ticket: ticket)
    }

    // MARK: Decoders

    func testAStageIsKeptInTheDaemonsSpellingAndAnUnknownOneAsText() {
        XCTAssertEqual(ProjectStage(word: "person/check").word, "person/check")
        XCTAssertEqual(ProjectStage(word: "ended/merged"), .ended("merged"))
        let unknown = ProjectStage(word: "person/triage")
        XCTAssertEqual(unknown, .unknown("person/triage"))
        XCTAssertTrue(unknown.needsPerson, "the person/ prefix is the protocol's own marker")
        XCTAssertFalse(ProjectStage(word: "working").needsPerson)
    }

    func testATicketWithNoUsableIdIsDroppedAndCounted() {
        let page = ProjectPage(.object([
            "project": "p1", "revision": 3, "total": 3,
            "tickets": [ticketJSON("t-a", stage: "working"), .object(["stage": "working"]), ticketJSON("", stage: "idle")],
        ]))!
        XCTAssertEqual(page.tickets.map(\.id), ["t-a"])
        XCTAssertEqual(page.unreadable, 2)
        XCTAssertEqual(page.total, 3)
    }

    func testAnAbsentFieldIsUnknownAndNeverZero() {
        let bare = ProjectTicket(ticketJSON("t", stage: "idle", title: nil, opened: nil))!
        XCTAssertNil(bare.openedMs)
        XCTAssertNil(bare.title)
        XCTAssertEqual(ProjectRule.titleWords(bare), "Untitled ticket")
        XCTAssertNil(ProjectRule.age(bare, now: 5_000_000), "an age is never made up")
        let blank = ProjectTicket(ticketJSON("t", stage: "idle", title: "   "))!
        XCTAssertNil(blank.title)
    }

    func testControlCharactersNeverReachADrawnString() {
        let hostile = ProjectTicket(ticketJSON("t", stage: "idle", title: "ok\u{1B}[31mred\u{07}"))!
        XCTAssertEqual(hostile.title, "ok[31mred")
        let check = ProjectCheck(["commit": "abc", "outcome": "failed", "output": "line\u{0}one\nline two"])!
        XCTAssertEqual(check.output, "lineone\nline two", "a newline survives and a NUL does not")
    }

    func testTheCheckCarriesItsCauseOutputAndOutcome() {
        let check = ProjectCheck([
            "commit": "abcdef0123456789", "outcome": "failed", "at_ms": 9, "command": "make check",
            "output": "exit 1\n2 tests failed", "cause": "test", "handling": "person", "note": "n",
        ])!
        XCTAssertEqual(check.outcome, .failed)
        XCTAssertEqual(check.cause, "test")
        XCTAssertEqual(check.handling, "person")
        XCTAssertEqual(check.atMs, 9)
        XCTAssertEqual(ProjectCheck(["outcome": "queued-up"])?.outcome, .unknown("queued-up"))
        XCTAssertNil(ProjectCheck(.null))
    }

    func testTheListCarriesCountsByStageInBoardOrder() {
        let listed = ProjectList.decode(.object(["projects": [
            ["id": "p1", "workspace": "/src/loom", "router_session": "s-r",
             "counts": ["working": 2, "person/check": 1, "person/answer": 3, "idle": 0]],
            .object(["workspace": "no id"]),
        ]]))
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].name, "loom")
        XCTAssertEqual(listed[0].stages.map(\.stage.word), ["person/answer", "person/check", "working"])
        XCTAssertEqual(ProjectRule.countWords(listed[0]), "3 person/answer \u{00B7} 1 person/check \u{00B7} 2 working")
        XCTAssertEqual(ProjectRule.needing(listed[0]), 4)
        XCTAssertEqual(ProjectRule.countWords(summary()), "No tickets")
    }

    func testTheDetailCarriesAssignmentsAndTheThread() {
        let detail = ProjectDetail(.object([
            "project": "p1", "revision": 14, "ticket": ticketJSON("t-a", stage: "person/answer"),
            "assignments": [["seq": 1, "session": "s_01", "status": "running"], .object(["status": "x"])],
            "inputs": [["trigger": "tr-1", "delivery": "delivered", "source": "composer", "actor": "owner", "text": "fix a"],
                       .object(["trigger": "tr-2", "delivery": "recorded"])],
        ]))!
        XCTAssertEqual(detail.assignments.count, 1)
        XCTAssertEqual(detail.inputs.map(\.trigger), ["tr-1", "tr-2"])
        XCTAssertNil(detail.inputs[1].text, "a message the ledger holds no text for has none")
    }

    func testTheBoardCountsRepliesAndKeepsWhatTheRouterDeclined() {
        let page = ProjectPage(.object([
            "project": "p1", "revision": 1, "total": 0, "tickets": [], "replies": [.object([:]), .object([:])],
            "unrouted": [["trigger": "tr-9", "source": "github", "actor": "x", "text": "hi", "reason": "no rule", "at_ms": 5]],
        ]))!
        XCTAssertEqual(page.replies, 2)
        XCTAssertEqual(page.unrouted.first?.reason, "no rule")
    }

    func testASessionRecordKnowsItsPartInAProject() {
        func record(_ standing: JSONValue?) -> SessionRecord {
            var fields: [String: JSONValue] = ["session_id": "s", "workspace": "/w", "name": "n", "created_at": 1,
                                               "status": ["state": "saved"]]
            if let standing { fields["standing"] = standing }
            return SessionRecord(.object(fields))!
        }
        XCTAssertNil(record(nil).standing)
        XCTAssertEqual(record(["kind": "router", "project": "p"]).standing, .router(project: "p"))
        XCTAssertEqual(record(["kind": "worker", "project": "p", "ticket": "t"]).standing, .worker(project: "p", ticket: "t"))
        XCTAssertNil(record(["kind": "worker", "project": "p"]).standing, "a worker with no ticket reads as no standing")
    }

    // MARK: Ordering and lanes

    func testNeedsAPersonComesFirstThenByUrgencyAndArrival() {
        let tickets = [
            ticket("w", "working"), ticket("r", "person/review"), ticket("a1", "person/answer"),
            ticket("c", "person/check"), ticket("a2", "person/answer"), ticket("e", "ended/closed"),
        ]
        XCTAssertEqual(ProjectRule.ordered(tickets).map(\.id), ["a1", "a2", "c", "r", "w", "e"])
        XCTAssertEqual(ProjectRule.groups(tickets).map(\.stage.word), ["person/answer", "person/check", "person/review", "working", "ended/closed"])
    }

    func testAReviewOrACheckIsReadAndEveryOtherWaitingStageIsAnswered() {
        XCTAssertEqual(ProjectRule.lane(of: ticket("t", "person/review")), .reviewing)
        XCTAssertEqual(ProjectRule.lane(of: ticket("t", "person/check")), .reviewing)
        for stage in ["person/answer", "person/delivery", "person/blocked", "person/failed", "person/triage"] {
            XCTAssertEqual(ProjectRule.lane(of: ticket("t", stage)), .answering, stage)
        }
    }

    func testWaitingTakesOnlyTheTicketsThatNeedAPersonFromBoardsThatRead() {
        let unread = ProjectState(summary: summary(), page: nil)
        let read = state([ticket("w", "working"), ticket("a", "person/answer"), ticket("c", "person/check")])
        XCTAssertEqual(ProjectRule.waiting([unread, read]).map(\.ticket.id), ["a", "c"])
        XCTAssertEqual(ProjectRule.waiting([unread]), [])
    }

    // MARK: Controls

    func testAControlExistsOnlyForAnActionTheDaemonListed() {
        let asked = ProjectTicket(ticketJSON(
            "t", stage: "person/answer", actions: ["answer", "close", "stop", "frobnicate"],
            question: ["seq": 9, "text": "which?"]
        ))!
        XCTAssertEqual(ProjectRule.controls(asked), [.answer(seq: 9), .close, .stop])
        XCTAssertEqual(ProjectRule.controls(ticket("t", "person/check")), [], "the stage decides nothing")
        let checked = ticket("t", "person/check", actions: ["stop", "publish", "close", "retry", "recheck"])
        XCTAssertEqual(ProjectRule.controls(checked), [.recheck, .retry, .close, .publish, .stop])
    }

    func testAnAnswerNeedsTheOpenQuestionItCarries() {
        let noQuestion = ProjectTicket(ticketJSON("t", stage: "person/answer", actions: ["answer"]))!
        XCTAssertEqual(ProjectRule.controls(noQuestion), [])
    }

    func testAPressIsHonouredOnlyForAControlDrawnNow() {
        let checked = ticket("t", "person/check", actions: ["recheck"])
        XCTAssertTrue(ProjectRule.allows(checked, .recheck))
        XCTAssertFalse(ProjectRule.allows(checked, .publish))
        XCTAssertFalse(ProjectRule.allows(checked, .answer(seq: 1)))
    }

    func testCloseStopAndPublishAskOnceAndTheRestAreSent() {
        XCTAssertEqual(
            [TicketControl.close, .stop, .publish, .retry, .recheck, .answer(seq: 1)].map(\.needsConfirmation),
            [true, true, true, false, false, false]
        )
        XCTAssertEqual(TicketControl.publish.act, .publish)
        XCTAssertEqual(TicketAct.publish.command, "projects.publish")
        XCTAssertNil(TicketControl.answer(seq: 1).act)
    }

    func testARefusalIsTheDaemonsSentenceForABadRequestAndOursForTheRest() {
        XCTAssertEqual(
            ProjectRule.refusal(code: "bad_request", message: "publishing is off for this project", control: .publish),
            "publishing is off for this project"
        )
        XCTAssertEqual(ProjectRule.refusal(code: "bad_request", message: "request refused", control: .close), "The daemon refused it.")
        XCTAssertEqual(
            ProjectRule.refusal(code: "conflict", message: "x", control: .answer(seq: 1)),
            "The question changed. Read it again before answering."
        )
        XCTAssertEqual(ProjectRule.refusal(code: "forbidden", message: "", control: .stop), "Only the owner can do that.")
    }

    // MARK: Words

    func testTheStageWordIsNeverReplacedByTheGloss() {
        let row = ref(ProjectTicket(ticketJSON("t", stage: "person/check", review: "no check is configured"))!)
        XCTAssertEqual(ProjectRule.head(row), "loom \u{00B7} person/check \u{00B7} no check is configured")
        XCTAssertTrue(ProjectRule.gloss(.personCheck).contains("check failed"))
    }

    func testTheHeadPrefersTheQuestionThenTheFailureThenTheCheck() {
        let asked = ProjectTicket(ticketJSON("t", stage: "person/answer", question: ["seq": 1, "text": "which?\nmore"]))!
        XCTAssertEqual(ProjectRule.head(ref(asked)), "loom \u{00B7} person/answer \u{00B7} which?")
        let failed = ProjectTicket(ticketJSON(
            "t", stage: "person/check", check: ["commit": "a", "outcome": "failed", "cause": "environment"]
        ))!
        XCTAssertEqual(ProjectRule.head(ref(failed)), "loom \u{00B7} person/check \u{00B7} Check failed (environment)")
    }

    func testTheMandateIsASentenceOrNothing() {
        XCTAssertNil(ProjectRule.mandateWords(nil))
        let mandate = ProjectMandate(["strength": "explicit", "via": "composer", "source": "composer", "actor": "owner"])
        XCTAssertEqual(ProjectRule.mandateWords(mandate), "Explicit: owner via composer asked for it")
    }

    func testTheRouterIsNeverReadAsHealthyWhenItIsNotListed() {
        XCTAssertEqual(ProjectRule.routerWords(nil), "Router session not listed")
        XCTAssertEqual(ProjectRule.routerWords(.saved), "Router saved")
        XCTAssertEqual(ProjectRule.routerWords(.resident(incarnation: "i")), "Router running")
    }

    // MARK: The inbox

    func testTicketsThatWaitAreRowsInTheGroupTheirLanePutsThemIn() {
        let tickets = [ticket("a", "person/answer", opened: 1_000), ticket("c", "person/check", opened: 2_000), ticket("w", "working")]
        let board = InboxRule.board(threads: [], feed: [:], tickets: tickets.map(ref), now: 61_000)
        XCTAssertEqual(board.sections.map(\.group), [.needsYou, .toReview])
        XCTAssertEqual(board.needsYou.map(\.id), ["ticket/p1/a"])
        XCTAssertEqual(board.sections[1].rows.map(\.id), ["ticket/p1/c"])
        XCTAssertEqual(board.needsYou[0].kind.chip, "Ticket")
        XCTAssertEqual(board.needsYou[0].age?.words, "1m")
        XCTAssertTrue(board.needsYou[0].isTicket)
    }

    func testOnlyAnAnsweringTicketIsCountedAsNeedingTheOwnerAndNoSessionIsNamed() {
        let tickets = [ref(ticket("a", "person/blocked")), ref(ticket("c", "person/check"))]
        let board = InboxRule.board(threads: [], feed: [:], tickets: tickets, now: 10_000)
        XCTAssertEqual(board.needing, 1, "a ticket to be read is counted by To review")
        XCTAssertEqual(board.needingSessions, [], "a ticket has no session to jump to")
        XCTAssertEqual(InboxRule.tally(threads: [], feed: [:], tickets: tickets).needing, 1)
    }

    func testATicketIsNoSessionAndOffersNoneToOpenOrWriteTo() {
        let row = InboxRule.ticketRows([ref(ticket("a", "person/answer"))], now: 10_000)[0]
        XCTAssertEqual(row.sessionID, "")
        let context = InboxCommandContext(row: row)
        XCTAssertEqual(InboxCommands.state(.openSession, in: context), .disabled)
        XCTAssertEqual(InboxCommands.state(.message, in: context), .disabled)
        XCTAssertEqual(InboxCommands.state(.retry, in: context), .absent)
    }

    func testATicketThatNeedsNobodyIsNoRow() {
        XCTAssertEqual(InboxRule.ticketRows([ref(ticket("w", "working")), ref(ticket("e", "ended/closed"))], now: 1), [])
    }

    func testTheSelectionKeepsATicketOpenWhileItIsListedAndSettlesWhenItIsNot() {
        let projects = [state([ticket("a", "person/answer")])]
        let open = ProjectSelection.ticket(project: "p1", ticket: "a")
        XCTAssertEqual(ProjectSelection.settled(open, projects: projects), open)
        XCTAssertEqual(ProjectSelection.settled(.ticket(project: "p1", ticket: "gone"), projects: projects), .project("p1"))
        XCTAssertNil(ProjectSelection.settled(open, projects: []))
        let unread = [ProjectState(summary: summary(), page: nil)]
        XCTAssertEqual(ProjectSelection.settled(open, projects: unread), open, "no read says the ticket is gone")
        let longer = [state([ticket("b", "working")], total: 30)]
        XCTAssertEqual(ProjectSelection.settled(open, projects: longer), open, "a ticket past the page may still exist")
    }
}
