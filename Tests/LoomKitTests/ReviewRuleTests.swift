import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// The review thread's layout rule (`MissionKit/ReviewRule.swift`), which mirrors the
/// web view's `review_pin_rule.gleam` and the wording of `view/review_thread.gleam`.
final class ReviewRuleTests: XCTestCase {
    private func line(_ kind: String, old: Int?, new: Int?, _ text: String = "x") -> JSONValue {
        var fields: [String: JSONValue] = ["k": .string(kind), "t": .string(text)]
        if let old { fields["o"] = .int(Int64(old)) }
        if let new { fields["n"] = .int(Int64(new)) }
        return .object(fields)
    }

    private func file(
        _ path: String, section: String = "source", content: String = "text", hunks: [[JSONValue]] = [],
        hunksOmitted: Int = 0, extent: String = "whole"
    ) -> JSONValue {
        .object([
            "path": .string(path), "change": "modified", "section": .string(section), "content": .string(content),
            "added": 2, "removed": 1, "hunks_omitted": .int(Int64(hunksOmitted)), "extent": .string(extent),
            "hunks": .array(hunks.map { lines in
                .object(["header": "@@ -1,3 +1,3 @@", "omitted": 0, "shortened": 0, "lines": .array(lines)])
            }),
        ])
    }

    private func review(
        _ files: [JSONValue], repository: String = "head", omitted: Int = 0, extent: String = "whole"
    ) -> ReviewRead {
        ReviewRead([
            "observed_at_ms": 1, "repository": .string(repository),
            "stat": ["files": .int(Int64(files.count)), "added": 41, "removed": 9],
            "omitted": .int(Int64(omitted)), "extent": .string(extent), "files": .array(files),
        ])!
    }

    private let hunk: [JSONValue] = [
        .object(["k": " ", "o": 10, "n": 10, "t": "keep"]),
        .object(["k": "-", "o": 11, "t": "old"]),
        .object(["k": "+", "n": 11, "t": "new"]),
        .object(["k": "\\", "t": "No newline"]),
    ]

    func testFilesReadSourceThenTestsThenDocsAndByPath() {
        let read = review([
            file("docs/b.md", section: "docs"), file("test/a_test.go", section: "tests"),
            file("src/z.go"), file("src/a.go"),
        ])
        XCTAssertEqual(ReviewRule.ordered(read.files).map(\.path), ["src/a.go", "src/z.go", "test/a_test.go", "docs/b.md"])
    }

    func testTheOrderLeavesTheDaemonsOrderAlone() {
        let read = review([file("src/a.go"), file("src/b.go"), file("test/a_test.go", section: "tests")])
        XCTAssertEqual(ReviewRule.ordered(read.files), read.files)
    }

    func testOnlyTheFirstFileOpensOnArrival() {
        XCTAssertTrue(ReviewRule.opensOnArrival(index: 0))
        XCTAssertFalse(ReviewRule.opensOnArrival(index: 1))
    }

    func testTheTitleCountsFilesAndAgreesInNumber() {
        let many = review([file("a"), file("b")]).stat
        XCTAssertEqual(ReviewRule.title(many), "Ready to review: +41 \u{2212}9 across 2 files")
        XCTAssertEqual(ReviewRule.title(review([file("a")]).stat), "Ready to review: +41 \u{2212}9 across 1 file")
    }

    func testEveryCutIsSaid() {
        XCTAssertEqual(ReviewRule.notices(review([file("a")])), [])
        let cut = review([file("a")], repository: "unborn", omitted: 3, extent: "cut")
        XCTAssertEqual(ReviewRule.notices(cut), [
            "The repository has no commit yet, so every file is new.", "3 files not shown",
            "Part of this diff was cut to fit, so its counts are lower bounds.",
        ])
        XCTAssertEqual(ReviewRule.notices(review([file("a")], omitted: 1)), ["1 file not shown"])
    }

    func testAFileWithNoTextSaysWhy() {
        let read = review([file("a", content: "binary"), file("b", content: "no_net_change"), file("c", content: "metadata_only"), file("d")])
        XCTAssertEqual(read.files.map(ReviewRule.contentNotice), [
            "Binary file: named, with no hunks.", "Touched, and its content is the same.",
            "Its mode or other metadata changed, with no text to show.", nil,
        ])
    }

    func testAFilesCutsAreSaid() {
        let read = review([file("a", hunksOmitted: 2, extent: "cut")])
        XCTAssertEqual(ReviewRule.cutNotices(read.files[0]), [
            "2 more hunks not shown", "This file's patch was cut, so its counts are lower bounds.",
        ])
        XCTAssertEqual(ReviewRule.counts(read.files[0]), "+2 \u{2212}1")
        XCTAssertEqual(ReviewRule.changeWords(read.files[0]), "modified")
    }

    // MARK: Placing finds

    func testAFindAtAShownLineIsAnchoredThere() {
        let read = review([file("src/a.go", hunks: [hunk])])
        let placed = ReviewRule.place(files: read.files, pins: [ReviewPin(id: "f1", path: "src/a.go", line: 11)])
        XCTAssertEqual(placed.files[0].anchored, [ReviewAnchor(hunk: 0, line: 2, find: "f1")])
        XCTAssertEqual(placed.files[0].at(hunk: 0, line: 2), ["f1"])
        XCTAssertEqual(placed.files[0].loose, [])
        XCTAssertEqual(placed.unplaced, [])
    }

    func testAContextLineCanBeNamedButARemovedLineCannot() {
        let read = review([file("src/a.go", hunks: [hunk])])
        let context = ReviewRule.place(files: read.files, pins: [ReviewPin(id: "c", path: "src/a.go", line: 10)])
        XCTAssertEqual(context.files[0].anchored.map(\.line), [0])

        // Old line 11 is the removed line, which has no number in the new file, and
        // new line 12 is in no hunk: both are loose at the top of the file.
        let loose = ReviewRule.place(files: read.files, pins: [
            ReviewPin(id: "r", path: "src/a.go", line: 12), ReviewPin(id: "n", path: "src/a.go", line: nil),
        ])
        XCTAssertEqual(loose.files[0].loose, ["r", "n"])
        XCTAssertEqual(loose.files[0].count, 2)
    }

    func testAFindThatNamesNoShownFileIsUnplacedAndNeverLost() {
        let read = review([file("src/a.go", hunks: [hunk])])
        let pins = [
            ReviewPin(id: "none", path: nil, line: nil), ReviewPin(id: "other", path: "src/other.go", line: 1),
            ReviewPin(id: "dot", path: "./src/a.go", line: 10), ReviewPin(id: "abs", path: "/src/a.go", line: 10),
        ]
        let placed = ReviewRule.place(files: read.files, pins: pins)
        XCTAssertEqual(placed.unplaced, ["none", "other", "abs"])
        XCTAssertEqual(placed.files[0].anchored.map(\.find), ["dot"], "a leading ./ is dropped and nothing else is")

        // Every find lands in exactly one place.
        let landed = placed.unplaced + placed.files.flatMap { $0.loose + $0.anchored.map(\.find) }
        XCTAssertEqual(landed.sorted(), pins.map(\.id).sorted())
    }

    func testAnchorsOrderByHunkLineThenFindWhateverTheInputOrder() {
        let read = review([file("a", hunks: [hunk, hunk])])
        let pins = [
            ReviewPin(id: "b", path: "a", line: 11), ReviewPin(id: "a", path: "a", line: 11),
            ReviewPin(id: "c", path: "a", line: 10),
        ]
        let forward = ReviewRule.place(files: read.files, pins: pins)
        let backward = ReviewRule.place(files: read.files, pins: pins.reversed())
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.files[0].anchored.map(\.find), ["c", "a", "b"])

        // The same line number in the second hunk is not reached while the first has it.
        XCTAssertTrue(forward.files[0].anchored.allSatisfy { $0.hunk == 0 })
    }

    func testAFindsMarkerIsABangForARiskAndAnIForAnyOther() {
        XCTAssertEqual(ReviewRule.marker(.risk), "!")
        XCTAssertEqual(ReviewRule.marker(.idea), "i")
        XCTAssertEqual(ReviewRule.marker(.bug), "i")
    }

    func testAHunkSaysWhatWasLeftOutOfIt() {
        let read = ReviewRead([
            "observed_at_ms": 1, "repository": "head", "stat": ["files": 1, "added": 1, "removed": 0], "omitted": 0,
            "extent": "whole", "files": [.object([
                "path": "a", "change": "added", "section": "source", "content": "text", "added": 1, "removed": 0,
                "hunks_omitted": 0, "extent": "whole",
                "hunks": [.object(["header": "@@", "omitted": 4, "shortened": 1, "lines": []])],
            ])],
        ])!
        XCTAssertEqual(ReviewRule.hunkNotices(read.files[0].hunks[0]), [
            "4 lines not shown", "1 line shortened to 400 bytes",
        ])
    }
}
