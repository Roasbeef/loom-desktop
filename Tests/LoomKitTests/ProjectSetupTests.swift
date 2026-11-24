import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// Setting a project up and giving it work: the decoders for `projects.settings`,
/// `projects.propose`, `projects.create` and `projects.post`, and the rule that turns
/// a settings form into the keys a Save sends (`MissionKit/ProjectSetup.swift`).
final class ProjectSetupTests: XCTestCase {
    private func settings(
        check: [String] = [], checkSource: String = "default", setup: [String] = [], workers: String = "4",
        publish: String = "off", paths: [String] = ["Makefile"], url: String? = "https://github.com/o/r", revision: Int = 3
    ) -> ProjectSettings {
        func row(_ key: String, _ value: [String], _ source: String) -> JSONValue {
            ["key": .string(key), "value": .array(value.map { .string($0) }), "source": .string(source), "changed_by": .null, "changed_ms": .null]
        }
        var fields: [String: JSONValue] = [
            "project": "p1", "revision": .int(Int64(revision)),
            "settings": [
                row("check", check, checkSource), row("setup", setup, "default"), row("publish", [publish], "default"),
                row("max_workers", [workers], "default"), row("protected_paths", paths, "default"),
            ],
        ]
        if let url { fields["publish_url"] = .string(url) }
        return ProjectSettings(.object(fields))!
    }

    private func plan(_ settings: ProjectSettings, _ edit: (inout SettingsDraft) -> Void) -> Result<SettingsPlan, SettingsRefusal> {
        var draft = ProjectSetup.draft(settings)
        edit(&draft)
        return ProjectSetup.plan(settings, draft: draft)
    }

    // MARK: Decoders

    func testTheSettingsCarryEachKeyItsSourceAndTheRevision() {
        let read = settings(check: ["make check"], checkSource: "project")
        XCTAssertEqual(read.revision, 3)
        XCTAssertEqual(read.publishURL, "https://github.com/o/r")
        XCTAssertEqual(read.setting("check")?.source, .project)
        XCTAssertEqual(read.setting("setup")?.source, .unset)
        XCTAssertEqual(ProjectSetup.sourceWords(.file), "from loom.toml")
        XCTAssertEqual(ProjectSettingSource(word: "wire"), .unknown("wire"), "a source this client does not know is kept as text")
        XCTAssertNil(ProjectSettings(["project": "p"]), "no revision, no settings")
        XCTAssertNil(settings(url: nil).publishURL)
    }

    func testAProposalSuggestsCommandsAndNamesTheMarkersItDidNotRead() {
        let proposal = ProjectProposal([
            "project": "p1", "check": ["command": "make unit", "because": "Makefile target unit"], "setup": .null,
            "notes": ["package.json: a symbolic link"],
        ])!
        XCTAssertEqual(proposal.check?.command, "make unit")
        XCTAssertNil(proposal.setup)
        XCTAssertEqual(ProjectSetup.proposalWords(proposal), [
            "Check: make unit (Makefile target unit)", "Present and not read: package.json: a symbolic link",
        ])
        XCTAssertEqual(
            ProjectSetup.proposalWords(ProjectProposal(["project": "p"])!), ["The repository suggests no check and no setup."]
        )
    }

    func testACreateAndAPostReplyDecode() {
        let made = ProjectCreated(["project": "p1", "workspace": "/src/loom", "router_session": "s-r"])!
        XCTAssertEqual(made.routerSession, "s-r")
        XCTAssertNil(ProjectCreated(["workspace": "/x"]))
        XCTAssertTrue(ProjectPostReceipt(["trigger": "tr-1", "repeated": .bool(true)])!.isRepeat)
        XCTAssertFalse(ProjectPostReceipt(["trigger": "tr-1"])!.isRepeat)
    }

    // MARK: The form

    func testASuggestionFillsOnlyACommandNothingSets() {
        let proposal = ProjectProposal(["project": "p1", "check": ["command": "make unit", "because": "t"], "setup": ["command": "make deps", "because": "t"]])!
        let empty = ProjectSetup.draft(settings(), proposal: proposal)
        XCTAssertEqual(empty.check, "make unit")
        XCTAssertEqual(empty.setup, "make deps")
        let set = ProjectSetup.draft(settings(check: ["make check"], checkSource: "project"), proposal: proposal)
        XCTAssertEqual(set.check, "make check", "a command already set is never overwritten by a suggestion")
        XCTAssertEqual(set.setup, "make deps")
    }

    func testASaveSendsOnlyTheKeysThatChanged() {
        let read = settings(check: ["make check"], checkSource: "project")
        XCTAssertEqual(try plan(read) { _ in }.get().changes, [])
        let changed = try? plan(read) { $0.check = "make unit"; $0.maxWorkers = "8"; $0.protectedPaths = "Makefile\n\n .github/** " }.get()
        XCTAssertEqual(changed?.changes.map(\.key), ["check", "max_workers", "protected_paths"])
        XCTAssertEqual(changed?.changes[0].value, ["make unit"])
        XCTAssertEqual(changed?.changes[2].value, ["Makefile", ".github/**"])
        XCTAssertNil(changed?.publishTo)
    }

    func testAnEmptyCommandGivesBackOnlyAKeyTheProjectHolds() {
        let held = settings(check: ["make check"], checkSource: "project")
        XCTAssertEqual(try plan(held) { $0.check = "  " }.get().changes, [SettingChange(key: "check", value: nil)])
        let fromFile = settings(check: ["make check"], checkSource: "file")
        XCTAssertEqual(try plan(fromFile) { $0.check = "" }.get().changes, [], "there is nothing to give back")
    }

    func testPublishingOnNeedsTheUrlTheReadShowedAndStandsAlone() {
        let read = settings()
        let on = try? plan(read) { $0.publish = .pullRequest }.get()
        XCTAssertEqual(on?.publishTo, "https://github.com/o/r")
        XCTAssertEqual(on?.changes, [SettingChange(key: "publish", value: ["pull_request"])])
        XCTAssertEqual(plan(read) { $0.publish = .pullRequest; $0.check = "make" }, .failure(.publishAlone))
        XCTAssertEqual(plan(settings(url: nil)) { $0.publish = .pullRequest }, .failure(.noRemote))
        let off = try? plan(settings(publish: "pull_request")) { $0.publish = .off }.get()
        XCTAssertNil(off?.publishTo, "turning it off needs no confirmation")
        XCTAssertEqual(off?.changes.map(\.key), ["publish"])
    }

    func testARefusalIsTheFilesSentenceForABadValue() {
        XCTAssertEqual(ProjectSetup.refusal(code: "bad_request", message: "check: a blank command is refused"), "check: a blank command is refused")
        XCTAssertTrue(ProjectSetup.refusal(code: "conflict", message: "").contains("read again"))
        XCTAssertEqual(ProjectSetup.refusal(code: "forbidden", message: ""), "Only the owner can change a project's settings.")
    }

    func testTheNameIsWhatWasTypedElseTheFoldersName() {
        XCTAssertEqual(ProjectSetup.projectName(typed: " ", folder: "/src/loom"), "loom")
        XCTAssertEqual(ProjectSetup.projectName(typed: "Loom", folder: "/src/loom"), "Loom")
    }

    // MARK: The composer

    func testARequestIsTrimmedBoundedAndNeverEmpty() {
        XCTAssertNil(ProjectPost.text(" \n "))
        XCTAssertEqual(ProjectPost.text("  fix it \n"), "fix it")
        XCTAssertEqual(ProjectPost.text(String(repeating: "x", count: 20_000))?.count, ProjectPost.limit)
    }

    func testARequestIdFitsTheDaemonsAlphabetAndBound() {
        let id = ProjectPost.requestID(UUID())
        XCTAssertLessThanOrEqual(id.count, 64)
        XCTAssertTrue(id.allSatisfy { $0.isLetter || $0.isNumber || "_-.".contains($0) })
        XCTAssertEqual(ProjectPost.requestID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), ProjectPost.requestID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))
    }

    func testTheReceiptSaysWhetherTheRequestWasAlreadyPosted() {
        XCTAssertEqual(ProjectPost.receiptWords(ProjectPostReceipt(["trigger": "t", "repeated": .bool(true)])!), "That request was already posted.")
        XCTAssertEqual(ProjectPost.receiptWords(ProjectPostReceipt(["trigger": "t"])!), "Posted. The router reads it next.")
    }

    // MARK: A result that outlives the row

    func testWhatAnActCameToNamesTheStageTheTicketMovedTo() {
        XCTAssertEqual(ProjectRule.done(.answer(seq: 1), stage: .working), "Answered \u{00B7} the ticket is now working")
        XCTAssertEqual(ProjectRule.done(.close, stage: .ended("closed")), "Closed \u{00B7} the ticket is now ended/closed")
        XCTAssertEqual(ProjectRule.done(.recheck, stage: .personCheck), "Check started \u{00B7} the ticket is now person/check")
        XCTAssertEqual(ProjectRule.done(.stop, stage: nil), "Stopped")
    }
}
