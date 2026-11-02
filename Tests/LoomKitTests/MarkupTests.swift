import XCTest
@testable import LoomKit
@testable import Markup

final class MarkdownTests: XCTestCase {
    func testParsesEveryBlockKind() {
        let source = """
        ## Title

        A paragraph
        on two lines.

        - one
          - nested
        - two

        1. first
        2. second

        > quoted

        | A | B |
        |---|---|
        | 1 | 2 |
        | 3 |

        ```swift
        let x = 1
        ```

        ---
        """
        let blocks = Markdown.parse(source)
        XCTAssertEqual(blocks.first, .heading(level: 2, text: "Title"))
        XCTAssertEqual(blocks[1], .paragraph("A paragraph\non two lines."))
        guard case .list(false, let items) = blocks[2] else { return XCTFail("expected a list") }
        XCTAssertEqual(items.map(\.depth), [0, 1, 0])
        guard case .list(true, let numbered) = blocks[3] else { return XCTFail("expected a numbered list") }
        XCTAssertEqual(numbered.first?.marker, "1.")
        XCTAssertEqual(blocks[4], .quote("quoted"))
        XCTAssertEqual(blocks[5], .table(header: ["A", "B"], rows: [["1", "2"], ["3", ""]]))
        XCTAssertEqual(blocks[6], .code(language: "swift", text: "let x = 1", isClosed: true))
        XCTAssertEqual(blocks[7], .rule)
    }

    func testAnUnterminatedFenceIsCodeThroughTheEnd() {
        XCTAssertEqual(
            Markdown.parse("text\n```go\nfunc main() {"),
            [.paragraph("text"), .code(language: "go", text: "func main() {", isClosed: false)]
        )
    }

    func testAHalfWrittenTableStaysText() {
        XCTAssertEqual(Markdown.parse("| A | B |"), [.paragraph("| A | B |")])
    }

    func testAHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(Markdown.parse("#notaheading"), [.paragraph("#notaheading")])
    }

    func testEveryPrefixOfAReplyParses() {
        let reply = "## H\n\n- a\n\n| x |\n|---|\n| y |\n\n```py\nprint('hi')\n```\n\n> q"
        for count in 0...reply.count {
            _ = Markdown.parse(String(reply.prefix(count)))
        }
    }

    func testPreviewDropsMarkers() {
        XCTAssertEqual(Markdown.plainPreview("## Retry\n\nA **bold** `code` move"), "Retry A bold code move")
    }
}

final class SyntaxTests: XCTestCase {
    /// The property that matters most: colouring never changes the text.
    func testTokensAlwaysJoinBackToTheInput() {
        let inputs = [
            "func a(b: Int) -> String { return \"x\\\"y\" } // done",
            "/* open", "\"unterminated", "don't panic", "", "\n\n", "0x1F 1_000 3.14 a1",
            "let é = 'ü' // ☃", "#!/bin/sh\necho $HOME # hi",
        ]
        for language in ["swift", "go", "python", "sh", "gleam", "rust", "nope", nil] as [String?] {
            for input in inputs {
                XCTAssertEqual(Syntax.highlight(input, language: language).map(\.text).joined(), input)
            }
        }
    }

    func testClassifiesTokens() {
        let tokens = Syntax.highlight("let x = \"s\" // c", language: "swift")
        XCTAssertEqual(tokens.first, .init(kind: .keyword, text: "let"))
        XCTAssertTrue(tokens.contains(.init(kind: .string, text: "\"s\"")))
        XCTAssertTrue(tokens.contains(.init(kind: .comment, text: "// c")))
    }

    func testAnApostropheInAWordIsNotAString() {
        XCTAssertFalse(Syntax.highlight("don't stop", language: "python").contains { $0.kind == .string })
    }

    func testLanguageFromPath() {
        XCTAssertEqual(Syntax.language(forPath: "a/b/main.gleam"), "gleam")
        XCTAssertNil(Syntax.language(forPath: "README"))
    }
}

final class DiffTests: XCTestCase {
    func testNumbersLinesAndCountsChanges() {
        let patch = """
        diff --git a/x b/x
        index 1..2 100644
        --- a/x
        +++ b/x
        @@ -10,3 +20,4 @@ func a
         same
        -old
        +new
        +more
         end
        """
        let summary = Diff.parse(patch)
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.removed, 1)
        let lines = summary.hunks[0].lines
        XCTAssertEqual(lines[0].oldNumber, 10)
        XCTAssertEqual(lines[0].newNumber, 20)
        XCTAssertEqual(lines[1].kind, .removed)
        XCTAssertEqual(lines[1].oldNumber, 11)
        XCTAssertEqual(lines[2].newNumber, 21)
        XCTAssertEqual(lines.last?.newNumber, 23)
    }

    func testAPatchWithNoHunksKeepsItsLines() {
        XCTAssertEqual(Diff.parse("+only").added, 1)
        XCTAssertEqual(Diff.parse("").hunks.count, 0)
    }

    func testBetweenKeepsCommonLinesAsContext() {
        let summary = Diff.between(old: "a\nb\nc", new: "a\nx\ny\nc")
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.removed, 1)
        XCTAssertEqual(summary.hunks[0].lines.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(summary.hunks[0].lines.last?.newNumber, 4)
    }

    func testANewFileIsAllAdditions() {
        let summary = Diff.between(old: "", new: "a\nb")
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.removed, 0)
    }
}

final class FuzzyTests: XCTestCase {
    func testRanksPrefixAndWordStartsAboveScattered() throws {
        let prefix = try XCTUnwrap(Fuzzy.score(query: "mis", candidate: "Mission Control"))
        let scattered = try XCTUnwrap(Fuzzy.score(query: "mis", candidate: "Make it so"))
        XCTAssertGreaterThan(prefix, scattered)
    }

    func testRequiresASubsequence() {
        XCTAssertNil(Fuzzy.score(query: "zzz", candidate: "Mission"))
        XCTAssertNil(Fuzzy.score(query: "nm", candidate: "man"))
        XCTAssertEqual(Fuzzy.score(query: "", candidate: "anything"), 0)
    }
}

final class TranscriptBlockTests: XCTestCase {
    private func tool(_ id: String, _ name: String, result: String? = "ok", failed: Bool = false) -> TranscriptRow {
        .init(id: id, kind: .tool(name: name, arguments: .null, result: result, isError: failed))
    }

    func testFoldsATurnsWorkAndKeepsTheAnswerOutside() {
        let user = TranscriptRow(id: "u", kind: .user(text: "go", author: nil), at: 1_000)
        var think = TranscriptRow(id: "th", kind: .thinking(text: "hm"), at: 2_000)
        think.tookMs = 1_000
        var run = tool("a", "bash")
        run.settledAt = 49_000
        let answer = TranscriptRow(id: "ans", kind: .assistant(text: "done"), at: 50_000)
        let blocks = TranscriptBlock.group([user, think, run, tool("b", "fs_read"), answer])
        XCTAssertEqual(blocks.map(\.id), ["u", "fold/th", "ans"])
        guard case .fold(let fold) = blocks[1] else { return XCTFail("expected a fold") }
        XCTAssertEqual(fold.steps, 2)
        XCTAssertEqual(fold.title, "Worked 48s · 2 steps")
        XCTAssertEqual(blocks.map(\.id).count, Set(blocks.map(\.id)).count)
    }

    func testNarrationBetweenStepsFoldsButTheLastProseStays() {
        let rows = [
            TranscriptRow(id: "u", kind: .user(text: "go", author: nil)),
            TranscriptRow(id: "n", kind: .assistant(text: "looking")),
            tool("a", "bash"),
            TranscriptRow(id: "ans", kind: .assistant(text: "done")),
        ]
        let blocks = TranscriptBlock.group(rows)
        guard case .fold(let fold) = blocks[1] else { return XCTFail("expected a fold") }
        XCTAssertEqual(fold.rows.map(\.id), ["n", "a"])
        XCTAssertEqual(blocks.last?.id, "ans")
    }

    func testATurnWithoutWorkIsNotFolded() {
        let rows = [
            TranscriptRow(id: "u", kind: .user(text: "hi", author: nil)),
            TranscriptRow(id: "ans", kind: .assistant(text: "hello")),
        ]
        XCTAssertEqual(TranscriptBlock.group(rows).count, 2)
    }

    func testARunningTurnStaysLive() {
        let rows = [TranscriptRow(id: "u", kind: .user(text: "go", author: nil)), tool("a", "bash")]
        guard case .fold(let fold) = TranscriptBlock.group(rows, running: true)[1] else { return XCTFail("expected a fold") }
        XCTAssertTrue(fold.isLive)
        XCTAssertTrue(fold.title.hasPrefix("Working"))
    }

    func testStepWordsCountLinesAndNameTheSubject() {
        let edit = StepWords.of(
            name: "fs_edit",
            arguments: ["path": "a.py", "old": "x\ny", "new": "x\nz\nw"],
            isRunning: false
        )
        XCTAssertEqual(edit.verb, "Edited")
        XCTAssertEqual(edit.subject, "a.py")
        XCTAssertEqual(edit.added, 2)
        XCTAssertEqual(edit.removed, 1)
        let write = StepWords.of(name: "fs_write", arguments: ["path": "b.py", "content": "1\n2\n3"], isRunning: true)
        XCTAssertEqual(write.verb, "Writing")
        XCTAssertEqual(write.added, 3)
        XCTAssertNil(write.removed)
    }

    func testAnchoredHunksCountTheLinesTheyReplaceAndAdd() {
        let hunks: JSONValue = [
            ["op": "replace", "from": ["line": 2, "anchor": "a"], "to": ["line": 4, "anchor": "b"], "lines": ["x", "y"]],
            ["op": "delete", "from": ["line": 9, "anchor": "c"], "to": ["line": 9, "anchor": "c"]],
            ["op": "insert_after", "at": ["line": 1, "anchor": "d"], "lines": ["z"]],
        ]
        let words = StepWords.of(name: "fs_edit", arguments: ["path": "f.py", "hunks": hunks], isRunning: false)
        XCTAssertEqual(words.added, 3)
        XCTAssertEqual(words.removed, 4)
        XCTAssertEqual(words.file, "f.py")
    }

    func testAFailedStepIsASentenceWithTheFirstLineOfItsResult() {
        let text = StepWords.failure(name: "bash", arguments: ["command": "make"], result: "make: *** boom\nmore")
        XCTAssertEqual(text, "Did not complete: ran make. make: *** boom")
    }

    func testDurationsReadAsAPersonWouldSayThem() {
        XCTAssertEqual(StepWords.duration(ms: 400), "under 1s")
        XCTAssertEqual(StepWords.duration(ms: 48_000), "48s")
        XCTAssertEqual(StepWords.duration(ms: 192_000), "3m 12s")
    }

    func testSummarizesInWordsAPersonWouldUse() {
        let rows = [tool("a", "bash"), tool("b", "bash"), tool("c", "fs_edit"), tool("d", "grep"), tool("e", "weird")]
        XCTAssertEqual(ToolSummary.describe(rows), "Ran 2 commands, edited 1 file, searched 1 time, used weird")
    }

    func testARunningGroupSpeaksInThePresent() {
        XCTAssertEqual(ToolSummary.describe([tool("a", "fs_write", result: nil)]), "Writing 1 file")
    }

    func testAFailedCallIsNotDescribedAsDone() {
        XCTAssertEqual(ToolSummary.describe([tool("a", "fs_write", failed: true)]), "1 call failed")
        XCTAssertEqual(ToolSummary.describe([tool("a", "bash"), tool("b", "fs_write", failed: true)]), "Ran 1 command, 1 call failed")
    }

    func testSummaryStatus() {
        XCTAssertEqual(ToolSummary.status([tool("a", "bash")]), .done)
        XCTAssertEqual(ToolSummary.status([tool("a", "bash", result: nil)]), .running)
        XCTAssertEqual(ToolSummary.status([tool("a", "bash", failed: true)]), .failed)
    }
}

/// The projection stays cheap on long sessions, because it runs on the main thread.
final class ProjectionPerformanceTests: XCTestCase {
    func testARepeatedIdenticalCutReportsNoChange() {
        var state = Conversation(sessionID: "s")
        let entry: JSONValue = ["id": "a", "parentId": .null, "seq": 1, "timestamp": 1, "type": "message", "message": ["role": "user", "content": [], "origin": .null]]
        let cells: JSONValue = ["cells": [
            ["namespace": "strand.config", "key": "main", "seq": 1, "value": ["model": ["modelId": "m"]]],
            ["namespace": "strand.leaf", "key": "main", "seq": 2, "value": "a"],
        ], "peers": [], "usage": .null]
        func cut(_ entries: [JSONValue]) -> Cut {
            Cut(window: "catch_up", nextSeq: 2, oldestSeq: 1, moreAfter: nil,
                identity: .init(sessionID: "s", epoch: "e", incarnation: "i", connectionID: "c", role: "owner"),
                metadata: cells, entries: entries)
        }
        XCTAssertTrue(state.apply(cut: cut([entry])))
        let revision = state.revision
        XCTAssertFalse(state.apply(cut: cut([])))
        XCTAssertEqual(state.revision, revision)
    }

    func testProjectingFiveThousandEntriesIsFast() {
        var state = Conversation(sessionID: "s")
        var entries: [JSONValue] = []
        var parent: JSONValue = .null
        for index in 0..<5000 {
            let id = "e\(index)"
            entries.append(["id": .string(id), "parentId": parent, "seq": .int(Int64(index)), "timestamp": 1, "type": "message", "message": [
                "role": "assistant", "content": [["type": "text", "text": .string("reply number \(index)")]],
            ]])
            parent = .string(id)
        }
        let metadata: JSONValue = ["cells": [
            ["namespace": "strand.config", "key": "main", "seq": 1, "value": ["model": ["modelId": "m"]]],
            ["namespace": "strand.leaf", "key": "main", "seq": 2, "value": parent],
        ], "peers": [], "usage": .null]
        state.apply(cut: Cut(window: "recent", nextSeq: 5001, oldestSeq: 0, moreAfter: nil,
            identity: .init(sessionID: "s", epoch: "e", incarnation: "i", connectionID: "c", role: "owner"),
            metadata: metadata, entries: entries))

        let start = ContinuousClock.now
        let rows = state.rows(strand: "main")
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(rows.count, 5000)
        print("PROJECTION_5000_MS \(elapsed)")
    }
}
