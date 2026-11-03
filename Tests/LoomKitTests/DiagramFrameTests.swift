import LoomKit
import XCTest

final class DiagramFrameTests: XCTestCase {
    func testTheRequestIsTheJSONTheFrameExpects() throws {
        let request = try XCTUnwrap(DiagramProtocol.request(source: "flowchart LR\n  A --> B", theme: "dark", revision: 3))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "flowchart LR\n  A --> B")
        XCTAssertEqual(object["theme"] as? String, "dark")
        XCTAssertEqual(object["revision"] as? Int, 3)
    }

    func testRepliesAreReadAndHeightsClamped() {
        XCTAssertEqual(DiagramProtocol.reply(#"{"kind":"ready"}"#), .ready)
        XCTAssertEqual(DiagramProtocol.reply(#"{"kind":"rendered","revision":2,"height":340}"#), .rendered(revision: 2, height: 340))
        XCTAssertEqual(DiagramProtocol.reply(#"{"kind":"rendered","revision":2,"height":40}"#), .rendered(revision: 2, height: 120))
        XCTAssertEqual(DiagramProtocol.reply(#"{"kind":"rendered","revision":2,"height":90000}"#), .rendered(revision: 2, height: 2000))
        XCTAssertEqual(DiagramProtocol.reply(#"{"kind":"failed","revision":1}"#), .failed(revision: 1, diagnostic: nil))
    }

    func testADiagnosticIsBoundedAndAnythingElseIgnored() {
        let long = String(repeating: "x", count: 5000)
        guard case .failed(_, let diagnostic)? = DiagramProtocol.reply(#"{"kind":"failed","revision":1,"diagnostic":"\#(long)"}"#) else {
            return XCTFail("a failure with a diagnostic is read")
        }
        XCTAssertEqual(diagnostic?.count, 2000)
        XCTAssertNil(DiagramProtocol.reply(#"{"kind":"svg","markup":"<svg/>"}"#))
        XCTAssertNil(DiagramProtocol.reply(#"{"kind":"rendered","height":10}"#))
        XCTAssertNil(DiagramProtocol.reply("not json"))
    }
}
