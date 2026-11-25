import Foundation
import MissionKit
import XCTest
@testable import LoomKit

/// The per-session worktree choice of loom's protocol-change/133: what is sent,
/// what a reply must carry for the choice to count as honoured, and the words
/// for each way it can fail.
final class SessionWorktreeTests: XCTestCase {
    /// Answers `sessions.create` with a fixed body and keeps the request, so a
    /// test reads what the client put on the wire.
    private final class Create: ControlTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [Int] = []
        private var sent: [String] = []
        let reply: String

        init(reply: String) { self.reply = reply }

        var requests: [JSONValue] { lock.withLock { sent.compactMap { try? JSONValue.parse(Data($0.utf8)) } } }

        func send(_ text: String) async throws {
            let id = (try JSONValue.parse(Data(text.utf8)))["id"]?.int ?? -1
            lock.withLock {
                ids.append(id)
                sent.append(text)
            }
        }

        func receive() async throws -> String {
            while lock.withLock({ ids.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
            let id = lock.withLock { ids.removeFirst() }
            return #"{"v":2,"reply_to":\#(id),"event":"sessions.create","body":\#(reply)}"#
        }

        func close() {}
    }

    private let plain = #"{"session_id":"s1","workspace":"/src/proj","name":"n","created_at":1,"status":{"state":"saved"}}"#
    private let withTree = #"{"session_id":"s1","workspace":"/src/proj","name":"n","created_at":1,"status":{"state":"saved"},"worktree":{"base":"origin/main","branch":"loom/s1"}}"#

    private func create(_ reply: String, options: CreationOptions) async throws -> (SessionRecord, [JSONValue]) {
        let transport = Create(reply: reply)
        let client = ControlClient(transport: transport)
        let record = try await client.createSession(requestKey: "k", workspace: "/src/proj", name: "n", configuration: "", options: options)
        return (record, transport.requests)
    }

    func testARecordDecodesItsWorktreeAndOmitsItWhenThereIsNone() throws {
        let with = try SessionRecord(JSONValue.parse(Data(withTree.utf8)))
        XCTAssertEqual(with?.worktree, SessionWorktree(base: "origin/main", branch: "loom/s1"))
        XCTAssertEqual(with?.workspace, "/src/proj", "the workspace stays the folder")
        XCTAssertNil(try SessionRecord(JSONValue.parse(Data(plain.utf8)))?.worktree)
    }

    func testAMemberWithNoBranchIsNoWorktree() {
        XCTAssertNil(SessionWorktree(["base": "HEAD"]))
        XCTAssertNil(SessionWorktree(["base": "HEAD", "branch": ""]))
        XCTAssertNil(SessionWorktree(nil))
        XCTAssertEqual(SessionWorktree(["branch": "loom/x"])?.base, "HEAD")
    }

    func testTheRequestIsSentOnlyWhenChosenAndTheBaseOnlyWhenTyped() {
        var fields: [String: JSONValue] = [:]
        CreationOptions().add(to: &fields)
        XCTAssertNil(fields["worktree"])

        CreationOptions(worktree: WorktreeRequest()).add(to: &fields)
        XCTAssertEqual(fields["worktree"], .object([:]))

        CreationOptions(worktree: WorktreeRequest(base: "   ")).add(to: &fields)
        XCTAssertEqual(fields["worktree"], .object([:]), "spaces alone ask for the default")

        CreationOptions(worktree: WorktreeRequest(base: " origin/main ")).add(to: &fields)
        XCTAssertEqual(fields["worktree"], ["base": "origin/main"])
    }

    func testACreationWithAWorktreeIsConfirmedByTheReply() async throws {
        let (record, requests) = try await create(withTree, options: CreationOptions(worktree: WorktreeRequest(base: "origin/main")))
        XCTAssertEqual(record.worktree?.branch, "loom/s1")
        XCTAssertEqual(requests.first?["body"]?["worktree"], ["base": "origin/main"])
    }

    func testADaemonThatIgnoresTheKeyIsReportedWithTheSessionItMade() async throws {
        do {
            _ = try await create(plain, options: CreationOptions(worktree: WorktreeRequest()))
            XCTFail("a reply with no worktree must not count as honoured")
        } catch let error as WorktreeNotHonoured {
            XCTAssertEqual(error.sessionID, "s1")
            XCTAssertEqual(error.localizedDescription, WorktreeWords.daemonTooOld)
        }
    }

    func testACreationWithoutAWorktreeNeedsNoMember() async throws {
        let (record, requests) = try await create(plain, options: CreationOptions())
        XCTAssertNil(record.worktree)
        XCTAssertNil(requests.first?["body"]?["worktree"])
    }

    func testTheBaseRuleIsTheDaemons() {
        XCTAssertNil(WorktreeWords.problem(withBase: ""))
        XCTAssertNil(WorktreeWords.problem(withBase: "  "))
        XCTAssertNil(WorktreeWords.problem(withBase: "origin/main"))
        XCTAssertNil(WorktreeWords.problem(withBase: "v1.2.3~2"))
        XCTAssertNotNil(WorktreeWords.problem(withBase: "-D"))
        XCTAssertNotNil(WorktreeWords.problem(withBase: "two words"))
        XCTAssertNotNil(WorktreeWords.problem(withBase: "tab\there"))
        XCTAssertNotNil(WorktreeWords.problem(withBase: String(repeating: "a", count: 256)))
        XCTAssertNil(WorktreeWords.problem(withBase: String(repeating: "a", count: 255)))
    }

    func testOnlyTheTopOfAPrimaryCheckoutCanHoldAWorktree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let top = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: top.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let sub = top.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        // A linked worktree keeps a `.git` file, which the daemon refuses.
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data("gitdir: /x/.git/worktrees/linked\n".utf8).write(to: linked.appendingPathComponent(".git"))

        XCTAssertNil(WorktreeWords.judge(folder: top.path))
        XCTAssertEqual(WorktreeWords.judge(folder: sub.path), WorktreeWords.notARepository)
        XCTAssertEqual(WorktreeWords.judge(folder: linked.path), WorktreeWords.notARepository)
        XCTAssertEqual(WorktreeWords.judge(folder: root.path), WorktreeWords.notARepository)
    }

    func testTheRefusalIsWordedAndTheCodeIsNotShown() {
        let error = LoomError.server(code: "not_a_repository", message: "x", details: nil)
        XCTAssertEqual(error.errorDescription, WorktreeWords.notARepository)
        XCTAssertFalse(WorktreeWords.notARepository.contains("not_a_repository"))
    }

    func testTheHeaderAndTheRowNameTheBranch() throws {
        let with = try XCTUnwrap(SessionRecord(JSONValue.parse(Data(withTree.utf8))))
        let without = try XCTUnwrap(SessionRecord(JSONValue.parse(Data(plain.utf8))))
        XCTAssertEqual(with.placeLine(liveBranch: nil), "proj · worktree loom/s1")
        XCTAssertEqual(with.placeLine(liveBranch: "other"), "proj · worktree loom/s1", "the daemon's branch wins over an observation")
        XCTAssertEqual(without.placeLine(liveBranch: "main"), "proj · main")
        XCTAssertEqual(without.placeLine(liveBranch: nil), "proj")

        let row = SidebarRows.row(with, activity: nil, machine: "m")
        XCTAssertEqual(row.ownBranch, "loom/s1")
        XCTAssertEqual(row.ownWorktreeHelp, "Works in its own worktree on branch loom/s1, started from origin/main")
        XCTAssertNil(SidebarRows.row(without, activity: nil, machine: "m").ownBranch)
    }
}
