import Foundation
import XCTest
@testable import LoomKit

/// How the projection's cost grows with the number of strands.
///
/// A session can hold thousands of strands, each a short chain of entries. Every
/// metadata change and every revision rebuilds some view of all of them, so a
/// pass that is quadratic in strands, or that walks every chain again for a strand
/// nothing happened to, is what a large session feels as lag and heat. These tests
/// build one and time the passes a host runs on each change.
final class ScaleTests: XCTestCase {
    private static let session = "01a19a3a-0000-7000-8000-000000000002"

    /// A session of `count` strands, each with a chain of `depth` entries ending in
    /// a finished tool call, plus a `main` strand.
    private static func conversation(strands count: Int, depth: Int = 6) -> Conversation {
        var cells: [JSONValue] = []
        var entries: [JSONValue] = []
        for index in 0..<count {
            let id = index == 0 ? "main" : "sub:^main/worker-\(index)"
            var parent: String?
            var leaf = ""
            for step in 0..<depth {
                leaf = "\(index)-\(step)"
                let body: JSONValue = step % 2 == 0
                    ? ["role": "assistant", "content": [["type": "toolCall", "toolCall": ["id": .string("c\(leaf)"), "name": "bash", "arguments": ["command": .string("ls \(step)")]]]]]
                    : ["role": "toolResult", "toolCallId": .string("c\(leaf.dropLast())\(step - 1)"), "toolName": "bash",
                       "content": [["type": "text", "text": "ok"]], "isError": .bool(false)]
                entries.append(["id": .string(leaf), "parentId": parent.map { .string($0) } ?? .null,
                                "seq": 1, "timestamp": 1, "type": "message", "message": body])
                parent = leaf
            }
            cells.append(["namespace": "strand.config", "key": .string(id), "seq": 1, "value": ["model": ["modelId": "fake"]]])
            cells.append(["namespace": "strand.leaf", "key": .string(id), "seq": 2, "value": .string(leaf)])
            cells.append(["namespace": "strand.state", "key": .string(id), "seq": 3, "value": ["currentOperationId": .null]])
            cells.append(["namespace": "strand.last_result", "key": .string(id), "seq": 4, "value": ["outcome": "completed"]])
        }
        var state = Conversation(sessionID: session)
        state.apply(cut: Cut(
            window: "catch_up", nextSeq: 99, oldestSeq: 1, moreAfter: nil,
            identity: .init(sessionID: session, epoch: "e", incarnation: "i", connectionID: "c", role: "owner"),
            metadata: ["cells": .array(cells), "peers": [], "usage": .null], entries: entries
        ))
        return state
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    func testBuildingAndSummarisingStrandsStaysLinear() {
        var report = ""
        for count in [1_000, 10_000, 100_000] {
            var built: Conversation?
            let build = seconds { built = Self.conversation(strands: count) }
            let state = try! XCTUnwrap(built)
            XCTAssertEqual(state.strands.count, count)
            var lines: [StrandLine] = []
            let cold = seconds { lines = state.strandLines() }
            let warm = seconds { _ = state.strandLines() }
            XCTAssertEqual(lines.count, count)
            // A pass that grew with the square of the strands would take minutes here.
            XCTAssertLessThan(build, 0.00006 * Double(count) + 2, "building \(count) strands")
            XCTAssertLessThan(warm, 0.0000030 * Double(count) + 0.05, "a repeat summary of \(count) strands")
            report += String(format: "strands=%5d build=%.3fs lines cold=%.3fs warm=%.3fs\n", count, build, cold, warm)
        }
        print(report)
    }

    func testTheTraceIsFoldedOncePerChain() {
        let state = Self.conversation(strands: 50, depth: 40)
        let first = state.traceBoard(strand: "main")
        let again = seconds { XCTAssertEqual(state.traceBoard(strand: "main"), first) }
        XCTAssertLessThan(again, 0.01)
        // Another strand has its own chain and its own board.
        _ = state.traceBoard(strand: "sub:^main/worker-3")
        XCTAssertEqual(state.traceBoard(strand: "main"), first)
    }
}
