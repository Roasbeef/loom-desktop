import XCTest
@testable import LoomKit

final class SlashCommandTests: XCTestCase {
    func testOrdinaryTextIsAPrompt() {
        XCTAssertEqual(SlashCommand.parse("  hello there "), .prompt("hello there"))
        XCTAssertEqual(SlashCommand.parse("   "), .empty)
    }

    func testCommandsTakeTheirArgumentWithInternalSpacing() {
        XCTAssertEqual(SlashCommand.parse("/model  glm 5"), .model("glm 5"))
        XCTAssertEqual(SlashCommand.parse("/model"), .models)
        XCTAssertEqual(SlashCommand.parse("/effort high"), .effort("high"))
        XCTAssertEqual(SlashCommand.parse("/queue run the tests"), .queue("run the tests"))
        XCTAssertEqual(SlashCommand.parse("/fork alt"), .fork("alt"))
        XCTAssertEqual(SlashCommand.parse("/compact"), .compact)
    }

    func testAMissingArgumentAndAnUnknownCommandAreWorded() {
        XCTAssertEqual(SlashCommand.parse("/effort"), .invalid("/effort needs an argument."))
        XCTAssertEqual(SlashCommand.parse("/frobnicate x"), .invalid("Unknown command /frobnicate."))
    }

    func testProfileDefaultIsNil() {
        XCTAssertEqual(SlashCommand.parse("/profile"), .profileShow)
        XCTAssertEqual(SlashCommand.parse("/profile default"), .profileSelect(nil))
        XCTAssertEqual(SlashCommand.parse("/profile blue"), .profileSelect("blue"))
    }

    func testGoalSubcommandsAreSubcommandsOnlyAsTheWholeArgument() {
        XCTAssertEqual(SlashCommand.parse("/goal"), .goalStatus)
        XCTAssertEqual(SlashCommand.parse("/goal clear"), .goalClear)
        XCTAssertEqual(SlashCommand.parse("/goal pause"), .goalPause)
        XCTAssertEqual(SlashCommand.parse("/goal resume"), .goalResume)
        XCTAssertEqual(
            SlashCommand.parse("/goal clear the failing test"),
            .goalSet(objective: "clear the failing test", budget: SlashCommand.defaultGoalBudget)
        )
        XCTAssertEqual(SlashCommand.parse("/goal check make check"), .goalCheck("make check"))
        XCTAssertEqual(SlashCommand.parse("/goal check"), .goalCheck(nil))
    }

    func testGoalBudgetIsReadOnlyFromTheFlag() {
        XCTAssertEqual(
            SlashCommand.parse("/goal --budget 50_000 fix issue 468"),
            .goalSet(objective: "fix issue 468", budget: 50_000)
        )
        XCTAssertEqual(SlashCommand.parse("/goal --budget=9 ship"), .goalSet(objective: "ship", budget: 9))
        XCTAssertEqual(SlashCommand.parse("/goal --budget abc go"), .invalid("abc is not a positive token count."))
        XCTAssertEqual(SlashCommand.parse("/goal --budget 0 go"), .invalid("0 is not a positive token count."))
        XCTAssertEqual(
            SlashCommand.parse("/goal " + String(repeating: "x", count: 4001)),
            .invalid("The objective is 4001 characters, and the limit is 4000.")
        )
    }

    func testBtwActions() {
        XCTAssertEqual(SlashCommand.parse("/btw"), .btw(.read))
        XCTAssertEqual(SlashCommand.parse("/btw refresh"), .btw(.refresh))
        XCTAssertEqual(SlashCommand.parse("/btw close"), .btwClose)
        XCTAssertEqual(SlashCommand.parse("/btw why is it slow"), .btw(.ask("why is it slow")))
    }

    func testUnscheduleTakesAnOptionalTarget() {
        XCTAssertEqual(SlashCommand.parse("/unschedule beat"), .unschedule(name: "beat", target: nil))
        XCTAssertEqual(SlashCommand.parse("/unschedule beat sub:x"), .unschedule(name: "beat", target: "sub:x"))
    }

    func testTheListFiltersByPrefixAndOpensArgumentRowsPastASpace() {
        XCTAssertTrue(SlashCommand.suggestions(for: "hello").isEmpty)
        XCTAssertEqual(SlashCommand.suggestions(for: "/go").map(\.command), ["/goal"])
        XCTAssertEqual(SlashCommand.suggestions(for: "/eff").first?.insertion, "/effort ")
        XCTAssertEqual(SlashCommand.suggestions(for: "/compact").first?.insertion, "/compact")
        XCTAssertEqual(SlashCommand.suggestions(for: "/effort h").map(\.command), ["/effort high"])
        XCTAssertEqual(SlashCommand.suggestions(for: "/effort ").count, 7)
        XCTAssertEqual(SlashCommand.suggestions(for: "/goal pa").map(\.command), ["/goal pause"])
        XCTAssertTrue(SlashCommand.suggestions(for: "/queue so").isEmpty)
    }

    func testModelAndProfileRowsComeFromTheCatalogue() {
        let catalogue = SlashCommand.Catalogue(models: ["glm", "kimi"], profiles: ["blue"])
        XCTAssertEqual(SlashCommand.suggestions(for: "/model k", catalogue: catalogue).map(\.command), ["/model kimi"])
        XCTAssertEqual(
            SlashCommand.suggestions(for: "/profile ", catalogue: catalogue).map(\.command),
            ["/profile default", "/profile blue"]
        )
    }

    func testSelectionWrapsAtEitherEdge() {
        XCTAssertEqual(SlashCommand.move(0, by: -1, count: 3), 2)
        XCTAssertEqual(SlashCommand.move(2, by: 1, count: 3), 0)
        XCTAssertEqual(SlashCommand.move(0, by: 1, count: 0), 0)
    }
}

final class DraftTests: XCTestCase {
    func testARefusalReturnsTheTextAndATakenDraftGoes() {
        var ledger = DraftLedger()
        let first = ledger.sent("one", delivery: .queue)!
        let second = ledger.sent("two", delivery: .send)!
        XCTAssertEqual(ledger.lines.count, 2)
        XCTAssertEqual(ledger.refused(first), "one")
        ledger.taken(second)
        XCTAssertTrue(ledger.lines.isEmpty)
        XCTAssertNil(ledger.refused(first))
    }

    func testAnEmptyDraftShowsNoLine() {
        var ledger = DraftLedger()
        XCTAssertNil(ledger.sent("  \n", delivery: .send))
        XCTAssertTrue(ledger.lines.isEmpty)
    }

    func testRestoringKeepsWhatWasTypedSince() {
        XCTAssertEqual(DraftLedger.restoring("sent", into: ""), "sent")
        XCTAssertEqual(DraftLedger.restoring("sent", into: "newer"), "sent\n\nnewer")
    }

    func testImagesAreIdentifiedByTheirBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])
        XCTAssertEqual(ImageAttachment.mimeType(of: png), "image/png")
        XCTAssertNil(ImageAttachment.mimeType(of: Data("<svg".utf8)))
        guard case .failure(let refusal) = ImageAttachment.vet(Data("<svg".utf8), name: "a.svg", already: 0) else {
            return XCTFail("an svg must be refused")
        }
        XCTAssertTrue(refusal.message.contains("a.svg"))
        guard case .failure = ImageAttachment.vet(png, name: "p.png", already: ImageAttachment.countLimit) else {
            return XCTFail("the ninth image must be refused")
        }
    }

    func testPromptContentKeepsTextThenImagesInOrder() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let image = try ImageAttachment.vet(png, name: "p.png", already: 0).get()
        let body = PromptContent.body(strand: "main", text: "look", images: [image])
        let blocks = body["content"]?.array ?? []
        XCTAssertEqual(blocks.map { $0["type"]?.string }, ["text", "image"])
        XCTAssertEqual(blocks[1]["mimeType"]?.string, "image/png")
    }
}

final class ProgramCardTests: XCTestCase {
    private let details: JSONValue = [
        "status": "completed",
        "calls": [
            "started_unix_ms": 0, "elapsed_ms": 100, "total": 3, "failed": 1, "cancelled": 0, "unsettled": 0,
            "items": [
                ["cap": "fs.read", "args": "a", "status": "ok", "start_ms": 0, "duration_ms": 10],
                ["cap": "fs.read", "args": "b", "status": "ok", "start_ms": 10, "duration_ms": 10],
                ["cap": "net.fetch", "args": "u", "status": "failed", "start_ms": 50, "duration_ms": 50],
            ],
        ],
    ]

    func testACompletedProgramIsOneSentenceAndATimeAxis() {
        let card = ProgramCard.read(arguments: ["program": "a\nb\n"], result: "ok", isError: false, details: details)
        XCTAssertEqual(card.state, .completed)
        XCTAssertEqual(card.outcome, "Read 2 files, made 1 request")
        XCTAssertEqual(card.countWords, "3 calls · 1 failed")
        XCTAssertEqual(card.lines, 2)
        XCTAssertEqual(card.calls.map(\.count), [2, 1])
        XCTAssertEqual(card.calls[1].offset, 50)
        XCTAssertEqual(card.calls[1].width, 50)
    }

    func testARunningProgramHoldsOnlyItsSource() {
        let card = ProgramCard.read(arguments: ["program": "x"], result: nil, isError: false, details: nil)
        XCTAssertEqual(card.state, .running)
        XCTAssertTrue(card.calls.isEmpty)
    }

    func testACompilerRefusalSaysNothingRan() {
        let card = ProgramCard.read(
            arguments: ["program": "x"], result: "boom", isError: true,
            details: ["status": "compile_failed", "detail": "line 1: bad"]
        )
        XCTAssertEqual(card.state, .compileFailed)
        XCTAssertEqual(card.failure, "line 1: bad")
    }
}
