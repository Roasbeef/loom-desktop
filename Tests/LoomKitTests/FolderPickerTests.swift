import LoomKit
import XCTest

final class FolderPickerTests: XCTestCase {
    private let recent = ["/Users/o/code/loom", "/Users/o/work/loom-site", "/Users/o/code/weft", "/Users/o/notes"]

    func testNothingTypedShowsTheNewestRecentFoldersAndTheProjects() {
        let many = (1...12).map { "/Users/o/f\($0)" }
        let sections = FolderPicker.sections(
            query: "  ", recent: many, projects: [ProjectRef(id: "p1", workspace: "/Users/o/f3")], found: ["/Users/o/deep/x"]
        )
        XCTAssertEqual(sections.recent.map(\.path), Array(many.prefix(8)), "newest first, eight shown")
        XCTAssertEqual(sections.projects.map(\.path), ["/Users/o/f3"])
        XCTAssertTrue(sections.found.isEmpty, "the index is searched, not listed")
        XCTAssertTrue(sections.typed.isEmpty)
    }

    func testAFragmentMatchesAnywhereInThePathIgnoringCase() {
        let sections = FolderPicker.sections(query: "CODE", recent: recent, projects: [], found: [])
        XCTAssertEqual(sections.recent.map(\.path), ["/Users/o/code/loom", "/Users/o/code/weft"], "the parent path matches too")
    }

    func testANameMatchRanksAboveAParentOnlyMatchAndAPrefixAboveBoth() {
        let rows = ["/Users/o/loom/docs", "/Users/o/a-loom", "/Users/o/loomy"]
        let sections = FolderPicker.sections(query: "loom", recent: rows, projects: [], found: [])
        XCTAssertEqual(sections.recent.map(\.path), ["/Users/o/loomy", "/Users/o/a-loom", "/Users/o/loom/docs"])
    }

    func testSeveralWordsMustAllMatchInAnyOrder() {
        let sections = FolderPicker.sections(query: "loom code", recent: recent, projects: [], found: [])
        XCTAssertEqual(sections.recent.map(\.path), ["/Users/o/code/loom"])
    }

    func testFoundFoldersFollowRecentOnesAndNeverRepeatThem() {
        let found = ["/Users/o/code/loom", "/Users/o/old/loom-notes", "/Users/o/misc/other"]
        let sections = FolderPicker.sections(query: "loom", recent: recent, projects: [], found: found)
        XCTAssertEqual(sections.recent.map(\.path), ["/Users/o/code/loom", "/Users/o/work/loom-site"])
        XCTAssertEqual(sections.found.map(\.path), ["/Users/o/old/loom-notes"], "the recent folder is not listed twice")
    }

    func testAProjectsWorkspaceIsDrawnOnceUnderProjects() {
        let sections = FolderPicker.sections(
            query: "loom", recent: recent, projects: [ProjectRef(id: "p", workspace: "/Users/o/code/loom")], found: []
        )
        XCTAssertEqual(sections.projects.map(\.path), ["/Users/o/code/loom"])
        XCTAssertFalse(sections.recent.contains { $0.path == "/Users/o/code/loom" })
    }

    func testTypedTextIsOfferedAsAPathOrWhenNothingMatches() {
        XCTAssertEqual(FolderPicker.sections(query: "~/new/place", recent: recent, projects: [], found: []).typed.map(\.path), ["~/new/place"])
        XCTAssertEqual(FolderPicker.sections(query: "zzz", recent: recent, projects: [], found: []).typed.map(\.path), ["zzz"])
        XCTAssertTrue(FolderPicker.sections(query: "weft", recent: recent, projects: [], found: []).typed.isEmpty, "a plain word that matches is not also a path")
    }

    func testATypedPathLeadsSoReturnTakesIt() {
        let sections = FolderPicker.sections(query: "/Users/o/code", recent: recent, projects: [], found: ["/Users/o/code/x"])
        XCTAssertEqual(sections.all.first?.kind, .typed)
        XCTAssertEqual(sections.all.first?.path, "/Users/o/code")
    }

    func testThePickedRowIsTheFirstInDrawingOrder() {
        let sections = FolderPicker.sections(query: "loom", recent: recent, projects: [], found: ["/Users/o/old/loom-notes"])
        XCTAssertEqual(sections.all.first?.kind, .recent)
        XCTAssertEqual(sections.all.last?.kind, .found)
    }

    func testARowSplitsIntoNameAndParent() {
        let choice = PickerChoice(path: NSHomeDirectory() + "/code/loom", kind: .found)
        XCTAssertEqual(choice.name, "loom")
        XCTAssertEqual(choice.parent, "~/code")
    }

    func testAProjectRowNeedsBothFields() throws {
        let rows = try JSONDecoder().decode(JSONValue.self, from: Data(#"[{"id":"p","workspace":"/w"},{"id":"q"},{"workspace":"/x"}]"#.utf8))
        XCTAssertEqual((rows.array ?? []).compactMap(ProjectRef.init), [ProjectRef(id: "p", workspace: "/w")])
    }

    // MARK: The index

    private func tree(_ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("picker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // The scan reports real paths, and the temporary directory sits behind a link.
        let real = root.path.withCString { realpath($0, nil) }.map { String(cString: $0) } ?? root.path
        return URL(fileURLWithPath: real)
    }

    private func make(_ root: URL, _ paths: [String]) throws {
        for path in paths {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
    }

    func testTheIndexListsFoldersShallowestFirstAndSkipsWhatCreationRefuses() throws {
        let root = try tree { root in
            try make(root, ["code/loom", "code/weft", ".ssh/keys", "Library/Caches", "notes", "repo/.git", "repo/src/inner"])
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("code/link"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        }
        let names = FolderIndex.scan(roots: [root]).map { String($0.dropFirst(root.path.count + 1)) }
        XCTAssertEqual(names, ["code", "notes", "repo", "code/loom", "code/weft"])
    }

    func testTheIndexStopsAtTheDepthLimit() throws {
        let root = try tree { try make($0, ["a/b/c/d/e/f/g/h"]) }
        let depths = FolderIndex.scan(roots: [root]).map { $0.dropFirst(root.path.count + 1).split(separator: "/").count }
        XCTAssertEqual(depths.max(), FolderIndex.depthLimit)
    }

    func testTheIndexStopsAtItsDeadline() throws {
        let root = try tree { try make($0, ["a", "b", "c"]) }
        let late = Date().addingTimeInterval(60)
        var calls = 0

        // The first reading sets the deadline and the second is already past it.
        let found = FolderIndex.scan(roots: [root], now: { calls += 1; return calls > 1 ? late : Date() })
        XCTAssertTrue(found.isEmpty, "a walk past its deadline stops before reading another directory")
    }
}
