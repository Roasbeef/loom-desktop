import Foundation
import XCTest
@testable import LoomKit

final class JSONParserTests: XCTestCase {
    private func old(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testItReadsWhatTheDecoderRead() throws {
        let documents = [
            #"{"a":1,"b":-2,"c":3.5,"d":1e3,"e":-0.25E-2,"f":true,"g":false,"h":null}"#,
            #"[1,2,[3,[4,[]]],{},{"k":[]}]"#,
            #" { "x" : [ 1 , 2 ] , "y" : "z" } "#,
            #""plain""#,
            #"{"s":"line\nbreak\ttab \"quote\" back\\slash \/ \u00e9 \u4e2d"}"#,
            #"{"pair":"\ud83d\ude00 and \uD83D\uDE00"}"#,
            #"{"big":9223372036854775807,"over":9223372036854775808,"neg":-9223372036854775808}"#,
            #"{"unicode":"héllo 中文 😀","empty":""}"#,
            "0", "-0", "123", "true", "null",
        ]
        for text in documents {
            XCTAssertEqual(try JSONValue.parse(Data(text.utf8)), try old(text), text)
        }
    }

    func testAnIntegerThatFitsIsAnIntAndOtherNumbersAreDoubles() throws {
        XCTAssertEqual(try JSONValue.parse(Data("42".utf8)), .int(42))
        XCTAssertEqual(try JSONValue.parse(Data("-7".utf8)), .int(-7))
        XCTAssertEqual(try JSONValue.parse(Data("0.5".utf8)), .double(0.5))
        XCTAssertEqual(try JSONValue.parse(Data("1e2".utf8)), .int(100))
        XCTAssertEqual(try JSONValue.parse(Data("2.0".utf8)), .int(2))
        XCTAssertEqual(try JSONValue.parse(Data("9223372036854775808".utf8)), .double(9223372036854775808))
    }

    func testALoneSurrogateBecomesTheReplacementCharacter() throws {
        XCTAssertEqual(try JSONValue.parse(Data(#""a\ud83dz""#.utf8)), .string("a\u{FFFD}z"))
        XCTAssertEqual(try JSONValue.parse(Data(#""\ude00""#.utf8)), .string("\u{FFFD}"))
    }

    func testMalformedDocumentsAreRefused() {
        let bad = ["", "{", "[1,", "{\"a\"}", "{\"a\":}", "[1 2]", "tru", "nul", "\"open", "\"bad\\q\"",
                   "\"\\u12\"", "01x", "1.", "1e", "-", "{\"a\":1} extra", "[1,]", "{,}", "\"ctl\u{01}\""]
        for text in bad {
            XCTAssertThrowsError(try JSONValue.parse(Data(text.utf8)), text)
        }
    }

    func testNestingIsBounded() {
        let deep = String(repeating: "[", count: 2_000) + String(repeating: "]", count: 2_000)
        XCTAssertThrowsError(try JSONValue.parse(Data(deep.utf8)))
        let fine = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        XCTAssertNoThrow(try JSONValue.parse(Data(fine.utf8)))
    }

    func testItIsMuchFasterThanTheDecoderOnAMetadataDocument() throws {
        var cells: [String] = []
        for index in 0..<2_000 {
            cells.append(#"{"namespace":"strand.config","key":"sub:^main/w-\#(index)","seq":\#(index),"value":{"model":{"modelId":"fake"},"thinkingLevel":"high"}}"#)
        }
        let data = Data(("{\"cells\":[" + cells.joined(separator: ",") + "],\"peers\":[],\"usage\":null}").utf8)
        func time(_ body: () throws -> Void) rethrows -> Double {
            let start = ContinuousClock.now
            try body()
            let d = ContinuousClock.now - start
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        var fast: JSONValue?
        var slow: JSONValue?
        let direct = try time { fast = try JSONValue.parse(data) }
        let decoded = try time { slow = try JSONDecoder().decode(JSONValue.self, from: data) }
        XCTAssertEqual(fast, slow)
        print(String(format: "parse %.1f KB: direct=%.4fs decoder=%.4fs (%.0fx)", Double(data.count) / 1024, direct, decoded, decoded / max(direct, 1e-9)))
        XCTAssertLessThan(direct * 3, decoded)
    }
}
