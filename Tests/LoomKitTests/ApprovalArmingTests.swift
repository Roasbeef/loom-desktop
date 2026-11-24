import XCTest
@testable import MissionKit

final class ApprovalArmingTests: XCTestCase {
    func testTheKeyIsStableWhileTheCardsAreUnchanged() {
        XCTAssertEqual(
            ApprovalArming.key(card: "a", shown: ["a", "b"]),
            ApprovalArming.key(card: "a", shown: ["a", "b"])
        )
    }

    func testACardLeavingRearmsTheCardsThatRemain() {
        let before = ApprovalArming.key(card: "b", shown: ["a", "b"])
        let after = ApprovalArming.key(card: "b", shown: ["b"])
        XCTAssertNotEqual(before, after, "b slid into a's place, so its buttons wait again")
    }

    func testACardJoiningRearmsTheCardsAlreadyShown() {
        XCTAssertNotEqual(
            ApprovalArming.key(card: "a", shown: ["a"]),
            ApprovalArming.key(card: "a", shown: ["a", "b"])
        )
    }

    func testTwoCardsNeverShareAKey() {
        XCTAssertNotEqual(ApprovalArming.key(card: "a", shown: ["a", "b"]), ApprovalArming.key(card: "b", shown: ["a", "b"]))
    }
}
