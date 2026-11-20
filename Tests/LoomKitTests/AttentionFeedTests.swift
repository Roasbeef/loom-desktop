import Foundation
import XCTest
@testable import LoomKit

/// The attention reads (loom protocol-change/120, 123, 125, 126 and the 050
/// addendum on times). Every decoder is total: an absent, null or mistyped field
/// reads as absent and never crashes. Each fixture names where its JSON came from.
final class AttentionFeedTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONValue.parse(Data(text.utf8))
    }

    // MARK: sessions.activity times

    /// Fixture: the activity row of loom docs/client-protocol.md section 3.21
    /// (line 1208), with the two members the 050 addendum on times adds (field
    /// table, lines 1225-1226).
    func testActivityReadsTheTwoTimes() throws {
        let row = try XCTUnwrap(SessionActivity(json("""
        {"session_id":"0198c0de-0000-7000-8000-000000000001","state":"working","strands":2,"working":1,"approvals":0,
         "last_outcome":"completed","last_message":"Merged the retry fix.","last_message_at":1763400000000,
         "turn_started_at":1763400600000,"model":"glm-5.2",
         "glances":[{"strand":"sub:main/audit-1a2b","title":"Audit","summary":"Reading manager.gleam"}]}
        """)))
        XCTAssertEqual(row.lastMessageAt, 1_763_400_000_000)
        XCTAssertEqual(row.turnStartedAt, 1_763_400_600_000)
        XCTAssertEqual(row.lastMessage, "Merged the retry fix.")
    }

    func testActivityTimesAreAbsentWhenNullMissingOrDamaged() throws {
        // An older daemon sends neither member.
        let older = try XCTUnwrap(SessionActivity(json(#"{"session_id":"a","state":"idle"}"#)))
        XCTAssertNil(older.lastMessageAt)
        XCTAssertNil(older.turnStartedAt)

        // A newer daemon sends null for both when there is nothing to date.
        let null = try XCTUnwrap(SessionActivity(json(#"{"session_id":"a","state":"idle","last_message_at":null,"turn_started_at":null}"#)))
        XCTAssertNil(null.lastMessageAt)
        XCTAssertNil(null.turnStartedAt)

        let damaged = try XCTUnwrap(SessionActivity(json(#"{"session_id":"a","state":"idle","last_message_at":"noon","turn_started_at":-5}"#)))
        XCTAssertNil(damaged.lastMessageAt)
        XCTAssertNil(damaged.turnStartedAt)
    }

    // MARK: sessions.attention

    /// Fixture: the reply example of loom docs/client-protocol.md section 3.34
    /// (line 2083). The doc's stuck item there is the old shape, with `failed_at`
    /// only, so it also pins that an older daemon's row decodes.
    func testTheDocumentedFeedReplyDecodes() throws {
        let body = try json("""
        {"attention":[{"session_id":"0198c0de-0000-7000-8000-000000000001","state":"ok","waiting_since":1763400000000,
        "asks":{"count":2,"items":[{"id":"ask-3f9c01a2b4","strand":"main","created_at":1763400000000,"head":"Which branch should the fix target?","questions":2}]},
        "finds":{"count":5,"items":[{"id":"find-77d0a1c9e2","strand":"sub:main/audit-1a2b","kind":"bug","created_at":1763401000000,"head":"The retry loop never backs off.","path":"src/retry.gleam","line":88}]},
        "stuck":{"count":1,"items":[{"strand":"sub:main/audit-1a2b","failed_at":1763402000000}]}}]}
        """)
        let row = try XCTUnwrap(body["attention"]?.array?.compactMap(AttentionRow.init).first)
        XCTAssertEqual(row.sessionID, "0198c0de-0000-7000-8000-000000000001")
        XCTAssertEqual(row.waitingSince, 1_763_400_000_000)

        // The count says what the session holds, and the items what the row kept.
        XCTAssertEqual(row.asks.count, 2)
        XCTAssertEqual(row.asks.items, [AttentionAsk(
            id: "ask-3f9c01a2b4", strand: "main", createdAt: 1_763_400_000_000,
            head: "Which branch should the fix target?", questions: 2
        )])
        XCTAssertEqual(row.finds.count, 5)
        XCTAssertEqual(row.finds.items.first?.kind, .bug)
        XCTAssertEqual(row.finds.items.first?.path, "src/retry.gleam")
        XCTAssertEqual(row.finds.items.first?.line, 88)
        XCTAssertEqual(row.stuck.items, [AttentionStuck(strand: "sub:main/audit-1a2b", failedAt: 1_763_402_000_000)])
    }

    /// Fixture: the stuck members of the addendum on stuck strands in loom
    /// protocol-change/120 (line 682), with the values of
    /// `web_view/test/attention_feed_stuck_test.gleam`, whose second item is the
    /// row of a daemon that predates the members.
    func testAStuckItemReadsItsReasonHintAndParent() throws {
        let row = try XCTUnwrap(AttentionRow(json("""
        {"session_id":"s","state":"ok","asks":{"count":0,"items":[]},"finds":{"count":0,"items":[]},
         "stuck":{"count":2,"items":[
           {"strand":"sub:main/a","failed_at":1763402000000,"reason":"rate_limited","retry_after_ms":30000,"parent":"main"},
           {"strand":"sub:main/b"}]}}
        """)))
        XCTAssertEqual(row.stuck.items, [
            AttentionStuck(strand: "sub:main/a", failedAt: 1_763_402_000_000, reason: "rate_limited", retryAfterMs: 30_000, parent: "main"),
            AttentionStuck(strand: "sub:main/b"),
        ])
    }

    /// Fixture: `a_damaged_added_field_is_absent_test` in the same Gleam file.
    func testADamagedStuckMemberIsAbsent() throws {
        let row = try XCTUnwrap(AttentionRow(json("""
        {"session_id":"s","state":"ok","asks":{"count":0,"items":[]},"finds":{"count":0,"items":[]},
         "stuck":{"count":1,"items":[{"strand":"sub:main/a","reason":3,"retry_after_ms":"soon","parent":null}]}}
        """)))
        XCTAssertEqual(row.stuck.items, [AttentionStuck(strand: "sub:main/a")])
    }

    /// Fixture: `a_row_that_is_not_ok_is_no_row_test` in
    /// `web_view/test/attention_feed_test.gleam`, and the `unknown` row of
    /// docs/client-protocol.md section 3.34 (a resident that did not answer in 2 s).
    func testARowThatWasNotReadIsNoRow() throws {
        XCTAssertNil(try AttentionRow(json(#"{"session_id":"s","state":"unknown"}"#)))
        XCTAssertNil(try AttentionRow(json(#"{"session_id":"s","state":"later","asks":{"count":0},"finds":{"count":0},"stuck":{"count":0}}"#)))
        XCTAssertNil(try AttentionRow(json("{}")))
        XCTAssertNil(try AttentionRow(json("null")))
    }

    /// Fixture: `a_damaged_section_makes_the_row_no_row_test`: a row whose counts
    /// are damaged cannot say how much it read, so it is no row.
    func testADamagedSectionMakesTheRowNoRow() throws {
        XCTAssertNil(try AttentionRow(json(#"{"session_id":"s","state":"ok","asks":"x","finds":{"count":0},"stuck":{"count":0}}"#)))
        XCTAssertNil(try AttentionRow(json(#"{"session_id":"s","state":"ok","asks":{"count":-1},"finds":{"count":0},"stuck":{"count":0}}"#)))
        XCTAssertNil(try AttentionRow(json(#"{"session_id":"s","state":"ok","asks":{"count":0},"finds":{"count":0}}"#)))
    }

    /// Fixture: `a_damaged_item_costs_only_itself_and_the_count_stays_honest_test`.
    func testADamagedItemCostsOnlyItselfAndTheCountStaysHonest() throws {
        let row = try XCTUnwrap(AttentionRow(json("""
        {"session_id":"s","state":"ok",
         "asks":{"count":1,"items":[{"id":"ask-3f9c01a2b4","strand":"main","created_at":10,"head":"Which branch?","questions":2},"junk"]},
         "finds":{"count":5,"items":[{"id":"find-0000000001","strand":"main","kind":"praise","created_at":1,"head":"x"}]},
         "stuck":{"count":0,"items":[]}}
        """)))
        XCTAssertEqual(row.asks.items.count, 1)

        // A find of a kind this client does not know is dropped, and its count stays.
        XCTAssertEqual(row.finds.items, [])
        XCTAssertEqual(row.finds.count, 5)

        // A count below the items it came with is raised to them.
        let low = try XCTUnwrap(AttentionRow(json("""
        {"session_id":"s","state":"ok",
         "asks":{"count":0,"items":[{"id":"ask-3f9c01a2b4","strand":"main","created_at":10,"head":"h","questions":1}]},
         "finds":{"count":0,"items":[]},"stuck":{"count":0,"items":[]}}
        """)))
        XCTAssertEqual(low.asks.count, 1)
    }

    func testALineWithoutItsPathIsDropped() throws {
        let row = try XCTUnwrap(AttentionRow(json("""
        {"session_id":"s","state":"ok","asks":{"count":0},"stuck":{"count":0},
         "finds":{"count":1,"items":[{"id":"find-0000000002","strand":"main","kind":"question","created_at":1,"head":"Why?","line":9}]}}
        """)))
        XCTAssertNil(row.finds.items.first?.line)
        XCTAssertEqual(row.finds.items.first?.kind, .question)
    }

    func testModelTextIsKeptAsTextAndNeverInterpreted() throws {
        let hostile = "<script>alert(1)</script> **bold** [x](https://evil.example)"
        let row = try XCTUnwrap(AttentionRow(JSONValue.object([
            "session_id": "s", "state": "ok",
            "asks": ["count": 1, "items": [["id": "ask-3f9c01a2b4", "strand": "main", "created_at": 1, "head": .string(hostile), "questions": 1]]],
            "finds": ["count": 0], "stuck": ["count": 0],
        ])))
        XCTAssertEqual(row.asks.items.first?.head, hostile)
    }

    // MARK: attention.read

    /// Fixture: the shape `client/attention_feed.gleam` `ask_record` (line 708)
    /// writes, with the field table of loom protocol-change/120 (line 236), for an
    /// open ask that the caller may answer.
    func testAnOpenAskReadsItsQuestions() throws {
        let record = try XCTUnwrap(AttentionRecord(json("""
        {"id":"ask-3f9c01a2b4","kind":"ask","revision":41,"status":"open","routing":"owner","strand":"main",
         "created_at":1763400000000,
         "anchor":{"operation":"op-1","step_id":"step-9","source_index":0},
         "why":"I cannot pick a target without you.",
         "questions":[
          {"key":"q1","prompt":"Which branch?","kind":"choice","options":[
            {"label":"main","note":null,"recommended":true},{"label":"release","note":"frozen","recommended":false}]},
          {"key":"q2","prompt":"How many?","kind":"multiple","min":1,"max":2,"options":[{"label":"a","note":null,"recommended":false}]},
          {"key":"q3","prompt":"Where?","kind":"fill","format":"path","options":[]},
          {"key":"q4","prompt":"Later kind","kind":"slider","options":[]}],
         "may_answer":true}
        """)))
        XCTAssertEqual(record.id, "ask-3f9c01a2b4")
        XCTAssertEqual(record.revision, 41)
        XCTAssertEqual(record.status, "open")
        XCTAssertEqual(record.anchor, AttentionAnchor(operation: "op-1", stepID: "step-9", sourceIndex: 0))
        guard case .ask(let ask) = record.detail else { return XCTFail("expected an ask") }
        XCTAssertEqual(ask.routing, "owner")
        XCTAssertEqual(ask.why, "I cannot pick a target without you.")
        XCTAssertTrue(ask.mayAnswer)
        XCTAssertNil(ask.answer)
        XCTAssertEqual(ask.questions.map(\.kind), [.choice, .multiple, .fill, .other("slider")])
        XCTAssertEqual(ask.questions[0].options.map(\.isRecommended), [true, false])
        XCTAssertEqual(ask.questions[0].options[1].note, "frozen")
        XCTAssertEqual(ask.questions[1].min, 1)
        XCTAssertEqual(ask.questions[1].max, 2)
        XCTAssertEqual(ask.questions[2].format, "path")
    }

    /// Fixture: the answer object of loom protocol-change/120 (line 363), with the
    /// `by` and `at` that `answer_of` adds.
    func testAnAnsweredAskCarriesItsAnswerAndIsNotAnswerable() throws {
        let record = try XCTUnwrap(AttentionRecord(json("""
        {"id":"ask-3f9c01a2b4","kind":"ask","revision":44,"status":"answered","routing":"owner","strand":"main","created_at":1,
         "questions":[],"answer":{"answers":{"q1":true,"q2":"Retry","q3":["a.gleam"],"q4":null},"other":{"q4":"Do it in a branch."},"by":"owner","at":1763400100000},
         "may_answer":false}
        """)))
        guard case .ask(let ask) = record.detail else { return XCTFail("expected an ask") }
        XCTAssertFalse(ask.mayAnswer)
        XCTAssertEqual(ask.answer?.by, "owner")
        XCTAssertEqual(ask.answer?.at, 1_763_400_100_000)
        XCTAssertEqual(ask.answer?.answers["q2"], "Retry")
        XCTAssertEqual(ask.answer?.other["q4"], "Do it in a branch.")
    }

    /// Fixture: `find_record` (client/attention_feed.gleam:726) for an open find and
    /// for one closed with the `closure` object of loom docs/client-protocol.md 3.34.
    func testAFindReadsItsTextPlaceAndClosure() throws {
        let open = try XCTUnwrap(AttentionRecord(json("""
        {"id":"find-77d0a1c9e2","kind":"find","revision":52,"status":"open","strand":"sub:main/audit-1a2b","created_at":1763401000000,
         "find_kind":"bug","text":"The retry loop never backs off.","path":"src/retry.gleam","line":88,"may_close":true}
        """)))
        guard case .find(let find) = open.detail else { return XCTFail("expected a find") }
        XCTAssertEqual(find.kind, .bug)
        XCTAssertEqual(find.text, "The retry loop never backs off.")
        XCTAssertEqual(find.line, 88)
        XCTAssertTrue(find.mayClose)
        XCTAssertNil(find.closure)

        let closed = try XCTUnwrap(AttentionRecord(json("""
        {"id":"find-77d0a1c9e2","kind":"find","revision":53,"status":"closed","strand":"main","created_at":1,
         "find_kind":"idea","text":"t","path":null,"line":null,"closure":{"outcome":"filed","at":1763401500000,"by":"owner"},"may_close":false}
        """)))
        guard case .find(let done) = closed.detail else { return XCTFail("expected a find") }
        XCTAssertEqual(done.closure, AttentionClosure(outcome: "filed", at: 1_763_401_500_000, by: "owner"))
        XCTAssertFalse(done.mayClose)
        XCTAssertNil(done.path)
    }

    func testARecordWithoutIdentityRevisionOrKnownKindIsNoRecord() throws {
        XCTAssertNil(try AttentionRecord(json(#"{"kind":"ask","revision":1}"#)))
        XCTAssertNil(try AttentionRecord(json(#"{"id":"ask-1","kind":"ask"}"#)))
        XCTAssertNil(try AttentionRecord(json(#"{"id":"x-1","revision":1,"kind":"note"}"#)))
        XCTAssertNil(try AttentionRecord(json("[]")))

        // A member this client does not use is ignored, and the permission words
        // default to the safe reading.
        let bare = try XCTUnwrap(AttentionRecord(json(#"{"id":"find-1","revision":1,"kind":"find","extra":{"x":1}}"#)))
        guard case .find(let find) = bare.detail else { return XCTFail("expected a find") }
        XCTAssertFalse(find.mayClose)
        XCTAssertNil(find.kind)
    }

    // MARK: approval.read

    /// Fixture: the member list of docs/client-protocol.md section 3.34 (line 2113),
    /// with the values of `web_view/test/approval_evidence_fields_test.gleam`.
    func testApprovalEvidenceReadsTheTimePolicyAndNetworkWords() throws {
        let evidence = try XCTUnwrap(ApprovalEvidence(json("""
        {"approvals":{"count":2,"items":[
          {"id":"esc-1","revision":4,"tool":"code_mode","preview":"{\\"cmd\\":\\"make\\"}","source":"policy","reason":"network is off",
           "wanted":[{"kind":"network","detail":"proxy"},{"kind":"writable_root"}],"asked":1,
           "raised_at":1763400000000,"network":"off","policy":{"sandbox":"workspace-write","network":"off"}},
          {"id":"esc-2","revision":9,"raised_at":1763399000000}]}}
        """)))
        XCTAssertEqual(evidence.count, 2)
        let first = evidence.items[0]
        XCTAssertEqual(first.tool, "code_mode")
        XCTAssertEqual(first.preview, #"{"cmd":"make"}"#)
        XCTAssertEqual(first.wanted, [ApprovalWanted(kind: "network", detail: "proxy"), ApprovalWanted(kind: "writable_root", detail: "")])
        XCTAssertEqual(first.raisedAt, 1_763_400_000_000)
        XCTAssertEqual(first.network, .off)
        XCTAssertEqual(first.policy, ApprovalPolicy(sandbox: "workspace-write", network: "off"))

        // The age is counted from the oldest raise time.
        XCTAssertEqual(evidence.oldestRaised, 1_763_399_000_000)
    }

    /// Fixture: `an_item_from_before_the_fields_has_none_of_them_test` and
    /// `a_damaged_added_field_is_absent_and_costs_nothing_test`.
    func testAnOldOrDamagedItemHasNoTimeNetworkOrPolicy() throws {
        let old = try XCTUnwrap(ApprovalEvidence(json(#"{"approvals":{"count":1,"items":[{"id":"esc-1","revision":4,"tool":"bash"}]}}"#)))
        XCTAssertNil(old.items[0].raisedAt)
        XCTAssertNil(old.items[0].network)
        XCTAssertNil(old.items[0].policy)
        XCTAssertNil(old.oldestRaised)

        let damaged = try XCTUnwrap(ApprovalEvidence(json("""
        {"approvals":{"count":1,"items":[{"id":"esc-1","revision":4,"tool":"code_mode","raised_at":"noon","network":"maybe","policy":{"sandbox":"x"}}]}}
        """)))
        XCTAssertNil(damaged.items[0].raisedAt)
        XCTAssertNil(damaged.items[0].network)
        XCTAssertNil(damaged.items[0].policy)
        XCTAssertEqual(damaged.items[0].tool, "code_mode")

        let negative = try XCTUnwrap(ApprovalEvidence(json(#"{"approvals":{"count":1,"items":[{"id":"e","revision":1,"raised_at":-5}]}}"#)))
        XCTAssertNil(negative.items[0].raisedAt)
    }

    /// Fixture: `a_damaged_record_costs_only_itself_test`,
    /// `a_count_below_the_items_is_read_as_the_larger_test` and
    /// `a_reply_that_is_not_one_is_no_evidence_test` in approval_evidence_test.gleam.
    func testEvidenceCountsStayHonestAndAForeignReplyIsNone() throws {
        let mixed = try XCTUnwrap(ApprovalEvidence(json(#"{"approvals":{"count":3,"items":[{"id":"e","revision":1},{"revision":2},"junk"]}}"#)))
        XCTAssertEqual(mixed.items.count, 1)
        XCTAssertEqual(mixed.count, 3)

        let low = try XCTUnwrap(ApprovalEvidence(json(#"{"approvals":{"count":0,"items":[{"id":"e","revision":1}]}}"#)))
        XCTAssertEqual(low.count, 1)

        XCTAssertNil(try ApprovalEvidence(json("null")))
        XCTAssertNil(try ApprovalEvidence(json(#"{"approvals":{"count":-1}}"#)))
        XCTAssertNil(try ApprovalEvidence(json(#"{"other":{}}"#)))
    }

    // MARK: session.brief

    /// Fixture: written from the member table of loom protocol-change/125 and the
    /// docs/client-protocol.md section 3.34 paragraph on `session.brief` (line 2138),
    /// not captured from a daemon.
    func testABriefReadsEverySection() throws {
        let brief = try XCTUnwrap(SessionBrief(json("""
        {"brief":{
         "assistant":{"text":"I ran the suite.","trust":"untrusted","at":1763400000000},
         "steps":[{"at":1763400001000,"tool":"bash","words":"Ran make check-core","trust":"untrusted","outcome":"succeeded"},
                  {"at":1763400002000,"tool":"edit","words":"Edit calc.py +3 \\u22121","trust":"untrusted","outcome":"running"}],
         "strands":[{"name":"main","state":"working","since":1763399000000},{"name":"sub:main/a","state":"stopped"}],
         "goal":{"objective":"Ship the fix","status":"active","tokens_used":1200,"token_budget":50000},
         "peers":[{"session":"s2","strand":"main","at":1763400003000,"text":"Heads up.","trust":"untrusted"}],
         "command":{"command":"make check-core","trust":"untrusted","exit":0,"at":1763400001000}}}
        """)))
        XCTAssertEqual(brief.assistant?.text.text, "I ran the suite.")
        XCTAssertEqual(brief.assistant?.at, 1_763_400_000_000)
        XCTAssertEqual(brief.steps.map(\.outcome), [.succeeded, .running])
        XCTAssertEqual(brief.steps[1].words.text, "Edit calc.py +3 \u{2212}1")
        XCTAssertEqual(brief.strands, [
            BriefStrand(name: "main", state: .working, since: 1_763_399_000_000),
            BriefStrand(name: "sub:main/a", state: .stopped, since: nil),
        ])
        XCTAssertEqual(brief.goal, BriefGoal(objective: "Ship the fix", status: "active", tokensUsed: 1200, tokenBudget: 50_000))
        XCTAssertEqual(brief.peers.first?.text.text, "Heads up.")
        XCTAssertEqual(brief.command?.exit, 0)
    }

    func testABriefKeepsWhatDecodesWhenASectionIsDamagedOrMissing() throws {
        let empty = try XCTUnwrap(SessionBrief(json(#"{"brief":{}}"#)))
        XCTAssertNil(empty.assistant)
        XCTAssertNil(empty.goal)
        XCTAssertNil(empty.command)
        XCTAssertEqual(empty.steps, [])

        let damaged = try XCTUnwrap(SessionBrief(json("""
        {"brief":{"assistant":"words","goal":{"objective":"x"},"command":{"command":"make","exit":"0","at":1},
         "steps":[{"at":1,"tool":"bash","words":"w","outcome":"exploded"},{"at":2,"tool":"bash","words":"ok","outcome":"failed"}],
         "strands":[{"name":"main","state":"asleep"}],"peers":"none"}}
        """)))
        XCTAssertNil(damaged.assistant)
        XCTAssertNil(damaged.goal)
        XCTAssertNil(damaged.command)
        XCTAssertEqual(damaged.steps.map(\.outcome), [.failed])
        XCTAssertEqual(damaged.strands, [])
        XCTAssertEqual(damaged.peers, [])

        XCTAssertNil(try SessionBrief(json(#"{"brief":3}"#)))
        XCTAssertNil(try SessionBrief(json("{}")))
    }

    func testBriefTextIsKeptVerbatimAsUntrustedText() throws {
        let hostile = "<b>x</b> `rm -rf /` # heading"
        let brief = try XCTUnwrap(SessionBrief(JSONValue.object([
            "brief": ["assistant": ["text": .string(hostile), "trust": "untrusted", "at": 1]],
        ])))
        XCTAssertEqual(brief.assistant?.text, UntrustedText(hostile))
    }

    // MARK: sessions.review

    /// Fixture: the reply example of loom docs/client-protocol.md section 3.35
    /// (line 2167), which is also the example of protocol-change/123 (line 95).
    func testTheDocumentedReviewDecodes() throws {
        let review = try XCTUnwrap(ReviewRead(json("""
        {"observed_at_ms":1763400000000,"repository":"head","stat":{"files":3,"added":41,"removed":9},"omitted":0,"extent":"whole",
         "files":[{"path":"src/retry.gleam","change":"modified","section":"source","content":"text","added":30,"removed":9,"hunks_omitted":0,"extent":"whole",
          "hunks":[{"header":"@@ -80,6 +80,9 @@ pub fn retry(","omitted":0,"shortened":0,"lines":[
           {"k":" ","o":80,"n":80,"t":"let wait = base"},{"k":"-","o":81,"t":"loop(base)"},{"k":"+","n":81,"t":"loop(base * 2)"}]}]}]}
        """)))
        XCTAssertEqual(review.repository, .head)
        XCTAssertEqual(review.stat, ReviewRead.Stat(files: 3, added: 41, removed: 9))
        XCTAssertEqual(review.extent, .whole)
        let file = try XCTUnwrap(review.files.first)
        XCTAssertEqual(file.path, "src/retry.gleam")
        XCTAssertEqual(file.section, .source)
        let lines = try XCTUnwrap(file.hunks.first?.lines)
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added])
        XCTAssertEqual(lines[1].old, 81)
        XCTAssertNil(lines[1].new)
        XCTAssertEqual(lines[2].new, 81)
        XCTAssertEqual(lines[2].text, "loop(base * 2)")
    }

    /// Fixture: `a_path_outside_the_workspace_is_left_out_and_counted_test` and
    /// `the_decoder_is_total_and_loses_one_file_at_a_time_test`.
    func testADamagedOrForeignFileIsLeftOutAndCounted() throws {
        func file(_ path: String, extra: String = "") -> String {
            #"{"path":"\#(path)","change":"added","section":"docs","content":"text","added":1,"removed":0,"hunks_omitted":0,"extent":"whole","hunks":[]\#(extra)}"#
        }
        let review = try XCTUnwrap(ReviewRead(json("""
        {"observed_at_ms":1,"repository":"unborn","stat":{"files":4,"added":1,"removed":0},"omitted":0,"extent":"whole",
         "files":[\(file("a.md")),\(file("/etc/passwd")),\(file("../up.md")),{"path":"broken"}]}
        """)))
        XCTAssertEqual(review.files.map(\.path), ["a.md"])

        // Each file left out is counted, and the review says that it was cut.
        XCTAssertEqual(review.omitted, 3)
        XCTAssertEqual(review.extent, .cut)
        XCTAssertEqual(review.repository, .unborn)
    }

    func testAReviewIsRefusedForAnUnknownRepositoryOrAMissingStat() throws {
        XCTAssertNil(try ReviewRead(json(#"{"observed_at_ms":1,"repository":"svn","stat":{"files":0,"added":0,"removed":0},"omitted":0,"extent":"whole","files":[]}"#)))
        XCTAssertNil(try ReviewRead(json(#"{"observed_at_ms":1,"repository":"head","omitted":0,"extent":"whole","files":[]}"#)))
        XCTAssertNil(try ReviewRead(json("[]")))
    }

    /// Fixture: `a_line_past_the_byte_bound_is_cut_and_counted_test` and
    /// `the_decoder_refuses_a_foreign_path_and_cuts_to_the_bounds_test`: the decoder
    /// holds the file, hunk, line and byte bounds on what it keeps.
    func testTheDecoderHoldsTheBounds() throws {
        let lines = (0..<95).map { #"{"k":"+","n":\#($0 + 1),"t":"l\#($0)"}"# }.joined(separator: ",")
        let long = String(repeating: "\u{00E9}", count: 300)
        let hunk = #"{"header":"@@ -1 +1 @@","omitted":0,"shortened":0,"lines":[\#(lines),{"k":" ","t":"\#(long)"}]}"#
        let hunks = Array(repeating: hunk, count: 14).joined(separator: ",")
        let file = #"{"path":"x.swift","change":"added","section":"source","content":"text","added":95,"removed":0,"hunks_omitted":0,"extent":"whole","hunks":[\#(hunks)]}"#
        let files = Array(repeating: file, count: 30).joined(separator: ",")
        let review = try XCTUnwrap(ReviewRead(json(#"{"observed_at_ms":1,"repository":"head","stat":{"files":30,"added":1,"removed":0},"omitted":0,"extent":"whole","files":[\#(files)]}"#)))
        XCTAssertEqual(review.files.count, ReviewRead.maxFiles)
        XCTAssertEqual(review.files[0].hunks.count, ReviewRead.maxHunks)
        XCTAssertEqual(review.files[0].hunks[0].lines.count, ReviewRead.maxHunkLines)

        // A cut falls between characters: 300 two-byte letters keep 200 whole ones.
        let cut = ReviewRead.prefix(long, bytes: ReviewRead.maxLineBytes)
        XCTAssertEqual(cut.utf8.count, 400)
        XCTAssertEqual(cut.count, 200)
        XCTAssertEqual(ReviewRead.prefix("\u{00E9}\u{00E9}", bytes: 3), "\u{00E9}")
    }
}
