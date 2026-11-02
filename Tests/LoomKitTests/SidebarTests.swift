import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

final class SidebarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func record(
        _ id: String, workspace: String = "/src/loom", created: Double = 1, state: JSONValue = ["state": "saved"],
        extra: [String: JSONValue] = [:]
    ) -> SessionRecord {
        var fields: [String: JSONValue] = [
            "session_id": .string(id), "workspace": .string(workspace), "name": "work", "created_at": .double(created * 1000),
            "status": state,
        ]
        fields.merge(extra) { _, new in new }
        return SessionRecord(.object(fields))!
    }

    private func activity(_ id: String, _ state: String) -> SessionActivity {
        SessionActivity(["session_id": .string(id), "state": .string(state)])!
    }

    private let resident: JSONValue = ["state": "resident", "incarnation": "i"]

    func testStandingSaysWhatTheAgentIsDoing() {
        let a = record("a", state: resident)
        XCTAssertEqual(SidebarRows.standing(of: a, activity: activity("a", "working")), "working")
        XCTAssertEqual(SidebarRows.standing(of: a, activity: activity("a", "needs_you")), "needs you")
        XCTAssertEqual(SidebarRows.standing(of: a, activity: activity("a", "idle")), "idle")
        XCTAssertEqual(SidebarRows.standing(of: a, activity: nil), "running")
    }

    func testStandingSaysWhereAQuietSessionStands() {
        XCTAssertEqual(SidebarRows.standing(of: record("a"), activity: nil), "saved")
        XCTAssertEqual(SidebarRows.standing(of: record("a", state: ["state": "recovery_blocked"]), activity: nil), "needs attention")
        let failed = record("a", state: ["state": "reserved", "failure": ["reason": "no space"]])
        XCTAssertEqual(SidebarRows.standing(of: failed, activity: nil), "failed to start: no space")
        let moving = record("a", state: resident, extra: ["moving": ["to": "east"]])
        XCTAssertEqual(SidebarRows.standing(of: moving, activity: activity("a", "idle")), "moving to east")
    }

    func testOnlyALinkedWorktreeHasAWorktreeName() {
        let pointer = "gitdir: /src/loom/.git/worktrees/feature"
        XCTAssertEqual(SidebarRows.worktree(workspace: "/src/loom/.claude/worktrees/feature", gitPointer: pointer), "feature")
        XCTAssertNil(SidebarRows.worktree(workspace: "/src/loom", gitPointer: nil))
        XCTAssertNil(SidebarRows.worktree(workspace: "/src/loom", gitPointer: "gitdir: /elsewhere/.git/modules/x"))
    }

    func testAgeIsInWords() {
        let base = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(SidebarRows.ago(base, now: base.addingTimeInterval(30)), "just now")
        XCTAssertEqual(SidebarRows.ago(base, now: base.addingTimeInterval(60)), "1 minute ago")
        XCTAssertEqual(SidebarRows.ago(base, now: base.addingTimeInterval(7200)), "2 hours ago")
        XCTAssertEqual(SidebarRows.ago(base, now: base.addingTimeInterval(86400 * 3)), "3 days ago")
    }

    func testSubtitleIsKeptOnlyWhenItAddsToTheTitle() {
        let withSubtitle = record("a", extra: ["subtitle": "Fix the parser", "name": "loom"])
        XCTAssertEqual(SidebarRows.row(withSubtitle, activity: nil, machine: "m", now: now).subtitle, nil)
        let named = record("b", extra: ["subtitle": "Fix the parser", "name": "parser work"])
        XCTAssertEqual(SidebarRows.row(named, activity: nil, machine: "m", now: now).subtitle, "Fix the parser")
    }

    func testRowsAreNewestFirstAndProjectsAreSorted() {
        let records = [
            record("old", workspace: "/a/zed", created: 10, state: resident),
            record("new", workspace: "/a/zed", created: 20, state: resident),
            record("other", workspace: "/a/api", created: 5, state: resident),
        ]
        let sections = SidebarRows.sections(records, activity: [:], grouping: .project, machine: { _ in "m" })
        XCTAssertEqual(sections.map(\.title), ["api", "zed"])
        XCTAssertEqual(sections[1].rows.map(\.id), ["new", "old"])
        XCTAssertEqual(sections[1].count, 2)
    }

    func testAMachineFilterKeepsOnlyThatMachinesRows() {
        let records = [record("a", state: resident), record("b", state: resident)]
        let machine: (SessionRecord) -> String = { $0.id == "a" ? "orch" : "box" }
        let sections = SidebarRows.sections(records, activity: [:], grouping: .machine, machine: machine, machineFilter: "box")
        XCTAssertEqual(sections.map(\.title), ["box"])
        XCTAssertEqual(sections.flatMap(\.rows).map(\.id), ["b"])
    }

    func testSavedRowsAreApartFromRunningOnes() {
        let records = [record("a", state: resident), record("b")]
        XCTAssertEqual(SidebarRows.saved(records, activity: [:], machine: { _ in "m" }).map(\.id), ["b"])
        let sections = SidebarRows.sections(records, activity: [:], grouping: .status, machine: { _ in "m" })
        XCTAssertEqual(sections.flatMap(\.rows).map(\.id), ["a"])
    }
}
