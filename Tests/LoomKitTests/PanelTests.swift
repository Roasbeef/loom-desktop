import Foundation
import XCTest
@testable import LoomKit

private func json(_ text: String) -> JSONValue {
    try! JSONValue.parse(Data(text.utf8))
}

final class PanelTests: XCTestCase {
    private let readyContext = """
    {"request_id":14,"status":"ready","strand":"main","as_of":99,"model":"fake/fake","context_window":200000,
     "used_tokens":82000,"basis":"reported_plus_estimate","compaction_used_tokens":80000,"checkpoint_at":183616,
     "reserve_tokens":16384,"items_total":3,"items_omitted":0,
     "categories":[{"name":"System prompt","tokens":4000},{"name":"Tools","tokens":23000},{"name":"Messages","tokens":50000}],
     "items":[{"category":"Tools","name":"bash","tokens":900},{"category":"Messages","name":"3. Assistant","tokens":500},
              {"category":"Messages","name":"5. Assistant","tokens":700}]}
    """

    func testContextBoardSplitsTheWindowAndWordsTheFigure() throws {
        guard case .ready(let board)? = ContextBoard.reading(json(readyContext)) else { return XCTFail("not ready") }
        XCTAssertEqual(board.footer, "ctx ~41%")
        XCTAssertEqual(board.untilCompaction, "103.6k tokens until the session compacts itself.")
        // The provider counted more than the three rows, and the rest is named as such.
        XCTAssertEqual(board.parts.first { $0.kind == .unattributed }?.tokens, 5000)
        XCTAssertEqual(board.messageKinds.first?.label, "Assistant")
        XCTAssertEqual(board.messageKinds.first?.count, 2)
    }

    func testAnInconsistentContextBoardIsAFailureNotAFigure() {
        let broken = readyContext.replacingOccurrences(of: "\"items_total\":3", with: "\"items_total\":9")
        guard case .failed? = ContextBoard.reading(json(broken)) else { return XCTFail("should fail") }
        XCTAssertEqual(ContextBoard.reading(json(#"{"request_id":3,"status":"pending"}"#)), .pending(requestID: 3))
    }

    func testUsageWordsNeverShowAnUnpricedCostAsZero() {
        let unavailable = json(#"{"version":1,"tokens":"unknown","billing":"api","cost":{"kind":"unavailable"}}"#)
        XCTAssertEqual(UsageWords.estimate(0, .init(unavailable)), "est —")
        let partial = json(#"{"version":1,"tokens":"partial","billing":"chatgpt-plan","cost":{"kind":"estimated","coverage":"partial","basis":"chatgpt-reference-rates"}}"#)
        XCTAssertEqual(UsageWords.estimate(1.0, .init(partial)), "API ref partial est $1.00")
        XCTAssertEqual(UsageWords.figure(0.456, .init(partial)), "API ref partial $0.46")
        let none = json(#"{"version":1,"tokens":"complete","billing":"no-provider","cost":{"kind":"no-expense"}}"#)
        XCTAssertEqual(UsageWords.estimate(0, .init(none)), "est $0.00")
        XCTAssertEqual(UsageWords.estimate(0, .init(nil)), "est —")
    }

    func testTodoBoardDecodesTotallyAndFindsTheActiveTask() {
        let board = TodoBoard(json("""
        {"phases":[{"name":"Build","tasks":[{"text":"Write","status":"done"},{"text":"Test","status":"active"},
        {"text":"Ship","status":"blocked","reason":"waiting on you"}]}]}
        """))
        XCTAssertEqual(board?.progress, "1/3 done")
        XCTAssertEqual(board?.active?.task.text, "Test")
        XCTAssertNil(TodoBoard(json(#"{"phases":[{"name":"x","tasks":[{"text":"a","status":"weird"}]}]}"#)))
        XCTAssertNil(TodoBoard(json(#"{"nothing":1}"#)))
    }

    func testOnlyASuccessfulTodoResultCarriesABoard() {
        let board = #"{"phases":[]}"#
        XCTAssertNotNil(TodoBoard.from(toolResult: json(#"{"role":"toolResult","toolName":"todo","isError":false,"details":{"todo":\#(board)}}"#)))
        XCTAssertNil(TodoBoard.from(toolResult: json(#"{"role":"toolResult","toolName":"todo","isError":true,"details":{"todo":\#(board)}}"#)))
        XCTAssertNil(TodoBoard.from(toolResult: json(#"{"role":"toolResult","toolName":"bash","isError":false,"details":{"todo":\#(board)}}"#)))
    }

    func testGoalBoardWordsAStoppedGoal() throws {
        let goal = try XCTUnwrap(GoalBoard(json("""
        {"status":"paused","reason":"operator","because":"you paused it","objective":"land the migration",
         "token_budget":400000,"tokens_used":51200,"cost_used":0.41,"continuations":3,"created_ms":0,"updated_ms":3600000,
         "observed_at_ms":7200000,"check":"make check","last_check":{"command":"make check","status":1,"output":"FAIL"}}
        """)))
        XCTAssertTrue(goal.canResume)
        XCTAssertFalse(goal.canPause)
        XCTAssertEqual(goal.causeWord, "you paused it")
        XCTAssertEqual(goal.lastCheck?.result, "failed (exit status 1)")
        XCTAssertTrue(goal.row.hasPrefix("goal paused (you paused it) · 51200/400000 tokens · 3 continuations"))
        XCTAssertFalse(try XCTUnwrap(GoalBoard(json(#"{"status":"none"}"#))).isPinned)
    }

    func testAnUnknownProposalKindIsOfferedNoDecision() throws {
        let board = try XCTUnwrap(ProposalBoard(json("""
        {"pending":2,"limit":64,"proposals":[
         {"id":"prop-1","kind":"rule","target":"loom-rules.md","old":"","new":"x","rationale":"r","state":"pending","source":{"session":"s"}},
         {"id":"prop-2","kind":"memory","target":"t","old":"","new":"y","rationale":"r","state":"pending","source":{"session":"s"}}]}
        """)))
        XCTAssertEqual(board.rows.map(\.canDecide), [true, false])
        XCTAssertEqual(board.rows[1].kindWords, "unknown change")
    }

    func testNotesExcerptsAreNeverParsedAsTheTodoBoard() throws {
        let complete = #"{\"phases\":[]}"#
        let board = try XCTUnwrap(NotesBoard(json(#"{"strand":"main","as_of":9,"total":2,"notes":[{"key":"todo","seq":1,"text":"\#(complete)","extent":"complete"}]}"#)))
        XCTAssertNotNil(board.todo)
        let excerpt = try XCTUnwrap(NotesBoard(json(#"{"strand":"main","as_of":9,"total":1,"notes":[{"key":"todo","seq":1,"text":"\#(complete)","extent":"excerpt"}]}"#)))
        XCTAssertNil(excerpt.todo)
        XCTAssertEqual(board.omitted, 1)
        XCTAssertEqual(board.matching("TODO").count, 1)
        XCTAssertEqual(board.matching("absent").count, 0)
    }

    func testForgetBodiesCarryTheSequenceTheListingHad() throws {
        let board = try XCTUnwrap(RememberedBoard(json("""
        {"seq":9,"grants":[{"grant":{"type":"readable_root","path":"/repo"},"provenance":{"by":{"name":"Alice"},"via":{"kind":"login","fingerprint":"9c1e0f2ab3d4e5f6"},"at_ms":1}}],
         "actions":[{"id":"ab12","seq":4,"tool":"bash","strand":"main","preview":"ls","provenance":null}]}
        """)))
        XCTAssertEqual(board.grants.first?.provenance?.words, "Alice · browser sign-in 9c1e0f2a")
        XCTAssertEqual(board.forgetBody(grant: board.grants[0])["expected_seq"]?.int, 9)
        XCTAssertEqual(board.forgetBody(action: board.actions[0])["expected_seq"]?.int, 4)
        XCTAssertEqual(board.forgetAllBody["target"]?["kind"]?.string, "all")
    }

    func testStrandLinesSayWhatEachStrandIsDoing() {
        let working = Strand(id: "main", model: "fake/fake", leaf: nil, currentOperation: "op", lastOutcome: nil)
        let rows = [TranscriptRow(id: "a", kind: .tool(name: "bash", arguments: ["command": "ls -la"], result: nil, isError: false), callID: "c1")]
        let line = StrandLine.make(strand: working, glance: nil, rows: rows, approvals: 0, hasHeldInput: false)
        XCTAssertEqual(line.status, .working)
        XCTAssertEqual(line.statusLine(elapsed: nil), "Working · bash")
        XCTAssertEqual(line.model, "fake")
        let waiting = StrandLine.make(strand: working, glance: nil, rows: [], approvals: 1, hasHeldInput: false)
        XCTAssertEqual(waiting.statusLine(elapsed: nil), "Needs approval")
        XCTAssertEqual(StrandLine(id: "sub:^main/build-1a2b", status: .idle, line: "", task: nil, model: nil,
                                  contextTokens: nil, running: [], recent: [], approvals: 0, ending: nil).name, "build")
    }

    func testTraceListsProgramsWithTheirStates() {
        let chain = [
            json(#"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"code_mode","arguments":{"program":"// count files\nreturn 1","within_ms":5000}}]}}"#),
            json(#"{"type":"message","message":{"role":"toolResult","toolName":"code_mode","toolCallId":"c1","isError":false,"content":[],"details":{"status":"completed","value":1,"calls":{"total":2,"failed":0,"items":[{"cap":"fs.list","status":"ok","duration_ms":4}]}}}}"#),
            json(#"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"code_mode","arguments":{"program":"x"}}]}}"#),
        ]
        let trace = TraceBoard.fold(chain: chain)
        XCTAssertEqual(trace.programs.map(\.state), [.completed, .running])
        XCTAssertEqual(trace.programs[0].label, "count files")
        XCTAssertEqual(trace.programs[0].budget, "5 s wall")
        XCTAssertEqual(trace.programs[0].calls.first?.capability, "fs.list")
    }

    func testConversationKeepsTheLastReadyContextAcrossARefresh() {
        var conversation = Conversation(sessionID: "s")
        func push(_ board: String) {
            conversation.apply(push: EventEnvelope(replyTo: nil, event: "snapshot", seq: nil,
                                                   body: json(#"{"mode":"context","board":\#(board)}"#)))
        }
        push(readyContext)
        XCTAssertEqual(conversation.context?.footer, "ctx ~41%")
        push(#"{"request_id":15,"status":"pending"}"#)
        XCTAssertEqual(conversation.context?.footer, "ctx ~41%")
        push(#"{"request_id":16,"status":"failed","message":"too slow"}"#)
        XCTAssertNil(conversation.context)
        XCTAssertEqual(conversation.contextNotice, "too slow")
    }
}
