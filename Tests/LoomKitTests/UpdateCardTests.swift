import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// The Updates cards and the board's order (`MissionKit/UpdateCard.swift`).
final class UpdateCardTests: XCTestCase {
    private let now = 10_000_000

    private func row(_ id: String, since: Int? = 9_880_000, kind: InboxKind = .working) -> InboxRow {
        InboxRow(
            subject: .session(id), kind: kind, group: InboxRule.group(of: kind), name: "Session \(id)",
            head: "said something", since: since, now: now
        )
    }

    private func activity(message: String? = "finished a step", glances: [JSONValue] = []) -> SessionActivity {
        var fields: [String: JSONValue] = ["session_id": "s", "state": "working", "glances": .array(glances)]
        if let message { fields["last_message"] = .string(message) }
        return SessionActivity(.object(fields))!
    }

    private func brief(steps: Int, command: JSONValue? = nil, strands: [JSONValue] = []) -> SessionBrief {
        var fields: [String: JSONValue] = [
            "assistant": ["text": "Reading the module now.", "at": 9_990_000],

            // The wire lists the newest step first, and step 0 here is the newest.
            "steps": .array((0..<steps).map { n in
                ["at": .int(Int64(9_900_000 - n)), "tool": "run", "words": .string("Ran step \(n)"), "outcome": n == 0 ? "running" : "succeeded"]
            }),
            "strands": .array(strands),
        ]
        if let command { fields["command"] = command }
        return SessionBrief(["brief": .object(fields)])!
    }

    func testTheCardNamesTheStateTheMessageAndTheRunningStep() {
        let digest = UpdateDigest(brief: brief(steps: 4))
        let card = UpdateCard.make(row: row("a"), activity: activity(), digest: digest, machine: nil, now: now)
        XCTAssertEqual(card.state, "working \u{00B7} 2 min into a turn")
        XCTAssertEqual(card.message, "Reading the module now.")
        XCTAssertEqual(card.step?.words.text, "Ran step 0")
        XCTAssertEqual(card.step?.outcome, .running)
        XCTAssertEqual(card.compact.map(\.words.text), ["Ran step 0", "Ran step 1", "Ran step 2"])
        XCTAssertNil(card.strandsLine)
        XCTAssertNil(card.failure)
        XCTAssertNil(card.machine)
    }

    func testTheDigestIsBoundedToFourStepsAndKeepsTheNewest() {
        let digest = UpdateDigest(brief: brief(steps: 40))
        XCTAssertEqual(digest.steps.count, 4)
        XCTAssertEqual(digest.steps.map(\.words.text), ["Ran step 0", "Ran step 1", "Ran step 2", "Ran step 3"])
    }

    func testWhenNothingRunsTheCurrentStepIsTheNewest() {
        let finished = SessionBrief(["brief": ["steps": [
            ["at": 200, "tool": "run", "words": "Ran newer", "outcome": "succeeded"],
            ["at": 100, "tool": "run", "words": "Ran older", "outcome": "failed"],
        ]]])!
        let card = UpdateCard.make(row: row("a"), activity: nil, digest: UpdateDigest(brief: finished), machine: nil, now: now)
        XCTAssertEqual(card.step?.words.text, "Ran newer")
    }

    func testWithoutADigestTheCardFallsBackToTheStreamedActivity() {
        let card = UpdateCard.make(row: row("a"), activity: activity(), digest: nil, machine: nil, now: now)
        XCTAssertEqual(card.message, "finished a step")
        XCTAssertNil(card.step)
        XCTAssertTrue(card.steps.isEmpty)
    }

    func testStrandsFailedCommandAndMachineFillTheOneLine() {
        let digest = UpdateDigest(brief: brief(
            steps: 1,
            command: ["command": "make check", "exit": 2, "at": 9_950_000],
            strands: [["name": "main", "state": "working"], ["name": "advisor", "state": "idle"]]
        ))
        let card = UpdateCard.make(row: row("a"), activity: activity(), digest: digest, machine: "laptop \u{2192} box", now: now)
        XCTAssertEqual(card.strandsLine, "2 strands \u{00B7} advisor idle")
        XCTAssertEqual(card.failure, "last command failed, exit 2")
        XCTAssertEqual(card.machine, "laptop \u{2192} box")
        XCTAssertEqual(card.strands.map(\.name), ["advisor"])
    }

    func testASucceededCommandIsNotAFailure() {
        let digest = UpdateDigest(brief: brief(steps: 1, command: ["command": "make", "exit": 0, "at": 9_950_000]))
        let card = UpdateCard.make(row: row("a"), activity: nil, digest: digest, machine: nil, now: now)
        XCTAssertNil(card.failure)
        XCTAssertEqual(card.commandExit, 0)
    }

    func testReadsAreCapped() {
        let rows = (0..<12).map { row("s\($0)") }
        let targets = UpdateWatch.targets(rows: rows)
        XCTAssertEqual(targets.count, UpdateWatch.readCap)
        XCTAssertEqual(targets.first, "s0")
        XCTAssertEqual(UpdateWatch.targets(rows: rows, excluding: "s0").first, "s1")
    }

    func testTheOldestReadGoesNextAndTheUnreadFirst() {
        XCTAssertEqual(UpdateWatch.next(targets: ["a", "b", "c"], readAt: ["a": 5, "b": 3, "c": 9]), "b")
        XCTAssertEqual(UpdateWatch.next(targets: ["a", "b", "c"], readAt: ["a": 5, "c": 9]), "b")
        XCTAssertEqual(UpdateWatch.next(targets: ["a", "b"], readAt: [:]), "a")
        XCTAssertNil(UpdateWatch.next(targets: [], readAt: [:]))
    }

    func testOnlyUpdatesAreRead() {
        let rows = [row("a"), row("b", kind: .waiting)]
        XCTAssertEqual(UpdateWatch.targets(rows: rows), ["a"])
    }

    func testTheBoardStartsByRecencyAndThenKeepsPlaces() {
        func card(_ id: String, _ at: Int) -> UpdateCard {
            UpdateCard.make(row: row(id, since: at), activity: nil, digest: nil, machine: nil, now: now)
        }
        let first = UpdateBoard.order(previous: [], cards: [card("a", 100), card("b", 300), card("c", 200)])
        XCTAssertEqual(first, ["session/b", "session/c", "session/a"])

        // A session that became the most recent does not move; a new one goes last; a gone one leaves.
        let next = UpdateBoard.order(previous: first, cards: [card("a", 900), card("b", 300), card("d", 50)])
        XCTAssertEqual(next, ["session/b", "session/a", "session/d"])
    }
}
