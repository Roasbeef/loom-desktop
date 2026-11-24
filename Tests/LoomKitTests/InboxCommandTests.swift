import Foundation
import XCTest
@testable import LoomKit
@testable import Markup
@testable import MissionKit

/// The inbox's commands (`MissionKit/InboxCommands.swift`): which actions each kind
/// of thread offers, that no context menu decides an approval, how next and previous
/// move through the list as drawn, and how a message that holds newlines is drawn on
/// one line and kept whole in a detail.
final class InboxCommandTests: XCTestCase {
    // MARK: Builders

    private func row(_ subject: InboxSubject, _ kind: InboxKind) -> InboxRow {
        InboxRow(subject: subject, kind: kind, group: InboxRule.group(of: kind), name: "work", head: "h", since: nil, now: 0)
    }

    private func context(
        _ kind: InboxKind, subject: InboxSubject = .session("s"), observer: Bool = false, stuckListed: Bool = false,
        approval: InboxApproval? = nil, own: Bool = false
    ) -> InboxCommandContext {
        InboxCommandContext(
            row: row(subject, kind), isObserver: observer, stuckListed: stuckListed, approval: approval,
            neighbors: InboxNeighbors(hasPrevious: true, hasNext: true), isInOwnWindow: own
        )
    }

    private let armed = InboxApproval(tool: "fs_write", canAllow: true, canRemember: true)

    private func states(_ context: InboxCommandContext) -> [InboxAction: InboxCommandState] {
        Dictionary(uniqueKeysWithValues: InboxAction.allCases.map { ($0, InboxCommands.state($0, in: context)) })
    }

    // MARK: The list

    func testTheContextMenuIsTheMenuWithoutNavigationOrDecisions() {
        XCTAssertEqual(InboxCommands.contextMenu, [.openSession, .openInWindow, .message])
        XCTAssertTrue(InboxCommands.menu.contains(.allow) && InboxCommands.menu.contains(.deny) && InboxCommands.menu.contains(.next))
        for action in InboxCommands.contextMenu { XCTAssertFalse(action.decides || action.navigates) }
    }

    func testNoContextMenuCarriesARetryOrACloseEvenForAStuckStrandOrAFind() {
        XCTAssertFalse(InboxCommands.contextMenu.contains(.retry) || InboxCommands.contextMenu.contains(.closeFind))
        let stuck = context(.stuck, subject: .stuck(session: "s", strand: "main"), stuckListed: true)
        XCTAssertEqual(InboxCommands.state(.retry, in: stuck), .enabled)
        XCTAssertFalse(InboxCommands.contextActions(for: stuck).contains(.retry))
        let found = context(.find(.bug), subject: .find(session: "s", id: "f"))
        XCTAssertEqual(InboxCommands.state(.closeFind, in: found), .enabled)
        XCTAssertFalse(InboxCommands.contextActions(for: found).contains(.closeFind))
    }

    func testARetryThatIsOutDisablesRetryUntilItIsDone() {
        let subject = InboxSubject.stuck(session: "s", strand: "main")
        var ctx = context(.stuck, subject: subject, stuckListed: true)
        XCTAssertEqual(InboxCommands.state(.retry, in: ctx), .enabled)
        ctx.isRetrying = true
        XCTAssertEqual(InboxCommands.state(.retry, in: ctx), .disabled)
    }

    func testNextReachesTheLastRowWhenTwoDaemonsListTheSameSession() {
        func thread(_ id: String) -> InboxThread {
            InboxThread(id: id, name: id, activity: SessionActivity(["session_id": .string(id), "state": "working"]))
        }
        let merged = [thread("a"), thread("b")] + [thread("b"), thread("c")]
        let threads = InboxRule.deduped(merged)
        XCTAssertEqual(threads.map(\.id), ["a", "b", "c"])
        let rows = InboxRule.selectable(InboxRule.sections(InboxRule.rows(
            threads: threads, feed: [:], raised: [:], reviewing: [], now: 0, clock: { "\($0)" }
        )))
        let drawn = rows.map { InboxSelection.thread($0.subject) }
        XCTAssertEqual(Set(drawn).count, drawn.count)
        var at = drawn.first
        for _ in 0..<drawn.count { at = InboxCommands.neighbor(of: at, in: drawn, step: .next) ?? at }
        XCTAssertEqual(at, drawn.last)
    }

    func testARowHeadSplitsOnCarriageReturnsAndLineSeparators() {
        for message in ["First\r\nsecond", "First\u{2028}second", "First\u{2029}second", "First\rsecond"] {
            let activity = SessionActivity(["session_id": "s", "state": "idle", "last_message": .string(message)])!
            XCTAssertEqual(InboxRule.threadHead(InboxThread(id: "s", name: "w", activity: activity)), "First", message.debugDescription)
        }
    }

    func testEveryActionIsInTheMenuOnce() {
        XCTAssertEqual(Set(InboxCommands.menu), Set(InboxAction.allCases))
        XCTAssertEqual(InboxCommands.menu.count, InboxAction.allCases.count)
    }

    func testNoContextMenuOffersADecisionEvenWithAnArmedCard() {
        let ctx = context(.approval, approval: armed)
        XCTAssertEqual(InboxCommands.state(.allow, in: ctx), .enabled)
        XCTAssertFalse(InboxCommands.contextActions(for: ctx).contains { $0.decides })
        XCTAssertEqual(InboxCommands.contextActions(for: ctx), [.openSession, .openInWindow, .message])
    }

    func testShortcutsAreDistinct() {
        let chords = InboxAction.allCases.compactMap(\.shortcut).map { "\($0.key)\($0.modifiers.map { "\($0)" }.sorted())" }
        XCTAssertEqual(Set(chords).count, chords.count)
        XCTAssertEqual(InboxAction.next.shortcut, InboxShortcut(key: "]"))
        XCTAssertEqual(InboxAction.previous.shortcut, InboxShortcut(key: "["))
    }

    // MARK: Which actions each thread offers

    func testAnApprovalThreadOffersTheSessionAndAMessageButNeitherRetryNorClose() {
        let found = states(context(.approval))
        XCTAssertEqual(found[.openSession], .enabled)
        XCTAssertEqual(found[.openInWindow], .enabled)
        XCTAssertEqual(found[.message], .enabled)
        XCTAssertEqual(found[.retry], .absent)
        XCTAssertEqual(found[.closeFind], .absent)
    }

    func testAStuckStrandOffersRetryOnlyWhileTheFeedStillListsIt() {
        let subject = InboxSubject.stuck(session: "s", strand: "main")
        XCTAssertEqual(InboxCommands.state(.retry, in: context(.stuck, subject: subject, stuckListed: true)), .enabled)
        XCTAssertEqual(InboxCommands.state(.retry, in: context(.stuck, subject: subject, stuckListed: false)), .disabled)
        XCTAssertEqual(InboxCommands.state(.retry, in: context(.stuck, subject: subject, observer: true, stuckListed: true)), .disabled)
        XCTAssertEqual(InboxCommands.state(.retry, in: context(.failed)), .absent)
    }

    func testAFindOffersCloseUnlessTheConnectionOnlyWatches() {
        let subject = InboxSubject.find(session: "s", id: "f")
        XCTAssertEqual(InboxCommands.state(.closeFind, in: context(.find(.bug), subject: subject)), .enabled)
        XCTAssertEqual(InboxCommands.state(.closeFind, in: context(.find(.bug), subject: subject, observer: true)), .disabled)
        XCTAssertEqual(InboxCommands.state(.closeFind, in: context(.ask)), .absent)
    }

    func testAnObserverCannotMessageAndAReviewMessagesThroughItsOutbox() {
        XCTAssertEqual(InboxCommands.state(.message, in: context(.waiting, observer: true)), .disabled)
        XCTAssertEqual(InboxCommands.state(.message, in: context(.review)), .disabled)
        XCTAssertEqual(InboxCommands.state(.message, in: context(.waiting)), .enabled)
        XCTAssertEqual(InboxCommands.state(.message, in: context(.working)), .enabled)
    }

    func testAThreadInItsOwnWindowCannotOpenAnother() {
        XCTAssertEqual(InboxCommands.state(.openInWindow, in: context(.ask, own: true)), .disabled)
        XCTAssertEqual(InboxCommands.state(.openSession, in: context(.ask, own: true)), .enabled)
    }

    func testNothingOpenDisablesTheThreadCommands() {
        let none = InboxCommandContext(row: nil)
        for action in [InboxAction.openSession, .openInWindow, .message, .next, .previous, .allow, .allowForSession, .deny] {
            XCTAssertEqual(InboxCommands.state(action, in: none), .disabled, "\(action)")
        }
        XCTAssertTrue(InboxCommands.contextActions(for: none).isEmpty)
    }

    // MARK: Allow and Deny follow the armed card

    func testDecisionsAreEnabledOnlyByAnArmedCard() {
        let without = context(.approval)
        for action in [InboxAction.allow, .allowForSession, .deny] {
            XCTAssertEqual(InboxCommands.state(action, in: without), .disabled, "\(action)")
        }
        let with = context(.approval, approval: armed)
        for action in [InboxAction.allow, .allowForSession, .deny] {
            XCTAssertEqual(InboxCommands.state(action, in: with), .enabled, "\(action)")
        }
    }

    func testRememberingNeedsTheOwnerAndNamesTheTool() {
        let observerCard = InboxApproval(tool: "fs_write", canAllow: true, canRemember: false)
        let ctx = context(.approval, approval: observerCard)
        XCTAssertEqual(InboxCommands.state(.allow, in: ctx), .enabled)
        XCTAssertEqual(InboxCommands.state(.allowForSession, in: ctx), .disabled)
        XCTAssertEqual(InboxAction.allow.title(tool: "fs_write"), "Allow fs_write")
        XCTAssertEqual(InboxAction.allowForSession.title(tool: "fs_write"), "Allow fs_write for This Session")
        XCTAssertEqual(InboxAction.deny.title(), "Deny Request")
        let denied = InboxApproval(tool: "x", canAllow: false, canRemember: false)
        XCTAssertEqual(InboxCommands.state(.allow, in: context(.approval, approval: denied)), .disabled)
        XCTAssertEqual(InboxCommands.state(.deny, in: context(.approval, approval: denied)), .enabled)
    }

    // MARK: Next and previous

    private let drawn: [InboxSelection] = [
        .thread(.session("a")), .thread(.ask(session: "b", id: "1")), .thread(.session("c")), .machine("m"),
    ]

    func testNextAndPreviousStepInDrawnOrder() {
        XCTAssertEqual(InboxCommands.neighbor(of: drawn[0], in: drawn, step: .next), drawn[1])
        XCTAssertEqual(InboxCommands.neighbor(of: drawn[2], in: drawn, step: .next), drawn[3])
        XCTAssertEqual(InboxCommands.neighbor(of: drawn[2], in: drawn, step: .previous), drawn[1])
    }

    func testNextAndPreviousStopAtTheEndsWithoutWrapping() {
        XCTAssertNil(InboxCommands.neighbor(of: drawn[0], in: drawn, step: .previous))
        XCTAssertNil(InboxCommands.neighbor(of: drawn[3], in: drawn, step: .next))
        XCTAssertEqual(InboxCommands.neighbors(of: drawn[0], in: drawn), InboxNeighbors(hasPrevious: false, hasNext: true))
        XCTAssertEqual(InboxCommands.neighbors(of: drawn[3], in: drawn), InboxNeighbors(hasPrevious: true, hasNext: false))
        XCTAssertEqual(InboxCommands.neighbors(of: drawn[1], in: drawn), InboxNeighbors(hasPrevious: true, hasNext: true))
    }

    func testASelectionTheListDoesNotDrawEntersAtTheEndItMovesToward() {
        let outside = InboxSelection.thread(.session("gone"))
        XCTAssertEqual(InboxCommands.neighbor(of: outside, in: drawn, step: .next), drawn.first)
        XCTAssertEqual(InboxCommands.neighbor(of: outside, in: drawn, step: .previous), drawn.last)
        XCTAssertEqual(InboxCommands.neighbor(of: nil, in: drawn, step: .next), drawn.first)
        XCTAssertNil(InboxCommands.neighbor(of: nil, in: [], step: .next))
        XCTAssertEqual(InboxCommands.neighbors(of: drawn[0], in: [drawn[0]]), .none)
    }

    // MARK: A subject can name a window

    func testASubjectSurvivesTheEncodingAWindowValueNeeds() throws {
        for subject in [InboxSubject.session("s"), .ask(session: "s", id: "a"), .stuck(session: "s", strand: "x"), .find(session: "s", id: "f")] {
            let data = try JSONEncoder().encode(subject)
            XCTAssertEqual(try JSONDecoder().decode(InboxSubject.self, from: data), subject)
        }
    }

    // MARK: Messages that hold newlines

    func testOneLineFoldsEveryKindOfLineBreakAndSpace() {
        XCTAssertEqual(InboxRule.oneLine("Done.\nSecond\r\nThird\u{2028}Fourth\t\tFifth"), "Done. Second Third Fourth Fifth")
        XCTAssertEqual(InboxRule.oneLine("\n\n  padded  \n"), "padded")
        XCTAssertEqual(InboxRule.oneLine(""), "")
    }

    func testAStripDigestOfAMultiLineMessageIsOneLineEvenWithCarriageReturns() {
        for message in ["Done.\nSecond line\n\nThird", "Done.\r\nSecond line\r\n\r\nThird"] {
            let line = InboxRule.oneLine(Markdown.plainPreview(message))
            XCTAssertEqual(line, "Done. Second line Third")
            XCTAssertFalse(line.contains { $0.isNewline })
        }
    }

    func testARowHeadIsTheFirstLineAndNeverBreaks() {
        let activity = SessionActivity([
            "session_id": "s", "state": "idle", "last_message": "\n\nFirst\u{2028}half\nsecond line",
        ])!
        let head = InboxRule.threadHead(InboxThread(id: "s", name: "work", activity: activity))
        XCTAssertEqual(head, "First")
    }

    func testTheFailedRunDetailKeepsTheMessagesLinesAndTheCardKeepsItRaw() {
        let message = "Build failed.\nLine two.\n\n- a\n- b"
        let record = SessionRecord([
            "session_id": "a", "workspace": "/src/loom", "name": "work", "created_at": 1,
            "status": ["state": "resident", "incarnation": "i"],
        ])!
        let row = SessionActivity(["session_id": "a", "state": "needs_you", "last_message": .string(message)])!
        let items = Mission.attention(sessions: [record], activity: ["a": row], escalations: [:])
        XCTAssertEqual(items.first?.detail, message)
        XCTAssertEqual(Mission.cards(sessions: [record], activity: ["a": row]).first?.digest, message)
    }
}
