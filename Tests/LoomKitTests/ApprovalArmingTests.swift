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

    /// Evidence or peer sections loading above a card move it, so its key changes.
    func testTheKeyChangesWhenWhatSitsAboveTheCardChangesSize() {
        let bare = ApprovalArming.key(card: "a", shown: ["a"], above: [0, 0])
        XCTAssertNotEqual(bare, ApprovalArming.key(card: "a", shown: ["a"], above: [1, 0]))
        XCTAssertNotEqual(bare, ApprovalArming.key(card: "a", shown: ["a"], above: [0, 1]))
        XCTAssertEqual(bare, ApprovalArming.key(card: "a", shown: ["a"], above: [0, 0]))
    }
}
