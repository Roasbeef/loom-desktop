import XCTest
import LoomKit
@testable import Loom

/// The app's host of one session lane. The simulation covers the core's decisions; these tests cover
/// what the host reports back to it, which the simulation cannot see.
@MainActor
final class SessionControllerTests: XCTestCase {
    private func controller() -> SessionController {
        let endpoint = DaemonEndpoint(host: "127.0.0.1", port: 1, token: String(repeating: "a", count: 64))
        return SessionController(sessionID: "s1", endpoint: endpoint)
    }

    /// Closing a lane for any reason must tell the daemon core it ended, or the core keeps a lane that is
    /// gone and never attaches another (the `older_turns_page_in` UI scenario found this after the old
    /// poll loop, which attached any lane that was not live, was replaced).
    func testDetachReportsTheLaneEndedExactlyOnce() {
        let lane = controller()
        var ended = 0
        lane.onEnded = { ended += 1 }
        lane.detach()
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(lane.isLive)
        lane.detach()
        XCTAssertEqual(ended, 1, "a second close reports nothing more")
    }
}
