import Foundation
import XCTest
@testable import LoomKit

final class AdministrationTests: XCTestCase {
    func testConfigurationChoicesReadProfileAndModelHeaders() {
        let text = """
        [models.fake]
        model_id = "fake"
        [models."other-model"]
        [profiles.review.roles]
        main = ["fake"]
        [profiles.review]
        [[schedule]]
        [profiles.quick.roles]
        """
        let choices = ConfigurationChoices.parse(text)
        XCTAssertEqual(choices.models, ["fake", "other-model"])
        XCTAssertEqual(choices.profiles, ["review", "quick"])
    }

    func testCreationOptionsSendOnlyWhatWasChosen() {
        var fields: [String: JSONValue] = [:]
        CreationOptions().add(to: &fields)
        XCTAssertTrue(fields.isEmpty)
        CreationOptions(profile: "review", model: "", isShareable: true).add(to: &fields)
        XCTAssertEqual(fields["profile"], "review")
        XCTAssertNil(fields["model"])
        XCTAssertEqual(fields["domain_scope"], "session_only")
    }

    func testFolderJudgementNamesTheProblem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)

        XCTAssertEqual(FolderCheck.judge("  "), .empty)
        XCTAssertEqual(FolderCheck.judge(directory.path), .ok(directory.path))
        XCTAssertEqual(FolderCheck.judge(directory.appendingPathComponent("absent").path), .missing)
        XCTAssertEqual(FolderCheck.judge(file.path), .notAFolder)
        XCTAssertNotNil(FolderCheck.missing.words)
    }

    func testAnInvitationNeverDescribesItsClaim() throws {
        let invitation = try XCTUnwrap(Invitation([
            "principal_id": "guest-1", "name": "Ada", "claim": "loomclaim_secret", "expires_in_ms": 3600000, "extra": "ignored",
        ]))
        XCTAssertFalse("\(invitation)".contains("loomclaim_secret"))
        XCTAssertFalse(String(reflecting: invitation).contains("loomclaim_secret"))
        XCTAssertEqual(invitation.command(address: "ws://h:1/v2/claim"), "loom claim --addr ws://h:1/v2/claim")
        XCTAssertNil(Invitation(["principal_id": "guest-1"]))
    }

    func testPrincipalsTolerateUnknownFieldsAndStates() throws {
        let owner = try XCTUnwrap(Principal([
            "principal_id": "owner", "name": "Me", "kind": "owner",
            "credential": ["state": "active", "fingerprint": "ab12"], "logins": 2, "future": .bool(true),
        ]))
        XCTAssertTrue(owner.isOwner)
        XCTAssertEqual(owner.credential.words, "Signed in (ab12)")
        let guest = try XCTUnwrap(Principal(["principal_id": "g", "credential": ["state": "something_new"]]))
        XCTAssertEqual(guest.credential.words, "No credential")
        XCTAssertEqual(guest.name, "g")
    }

    func testPeerLinksReadBothDirections() throws {
        let out = try XCTUnwrap(PeerLink(["session": "s2", "target_strand": "main", "wake": "may_wake", "metadata": ["name": "Other"]], direction: .outgoing))
        XCTAssertEqual(out.wakes, true)
        XCTAssertEqual(out.sessionName, "Other")
        let incoming = try XCTUnwrap(PeerLink(["source_session": "s3", "source_strand": "a"], direction: .incoming))
        XCTAssertNil(incoming.wakes)
        XCTAssertNil(PeerLink(["session": "s2"], direction: .outgoing))
    }

    func testMoveCandidatesGiveTheFirstReasonThatApplies() {
        let deployment = Deployment(["self": "a", "orchestrators": [
            ["name": "b", "node": "b@h", "state": "down"],
            ["name": "c", "node": "c@h", "state": "ok", "imports": "not_receiving"],
            ["name": "d", "node": "d@h", "state": "ok", "imports": "receiving", "serves": ["box"]],
            ["name": "e", "node": "e@h", "state": "ok", "imports": "receiving", "serves": ["other"]],
            ["name": "f", "node": "f@h", "state": "ok"],
        ]])
        let candidates = MoveCandidate.choose(from: deployment, executor: "box")
        XCTAssertEqual(candidates.map { $0.name }, ["b", "c", "d", "e", "f"])
        XCTAssertEqual(candidates.map { $0.isEligible }, [false, false, true, false, false])
        XCTAssertEqual(candidates[0].refusal, "is not reachable")
        XCTAssertEqual(candidates[3].refusal, "does not serve this session's executor")
    }

    func testAnExecutorNodeReadsItsWorkspacesAndUncleanScopes() throws {
        let deployment = Deployment(["nodes": [[
            "node": "exec@h", "name": "box", "roles": ["executor"],
            "executor": ["workspaces": ["proj"], "unclean": [["session": "s1", "state": "closing"]], "contradiction": .null],
        ]]])
        let node = try XCTUnwrap(deployment.nodes.first)
        XCTAssertEqual(node.workspaces, ["proj"])
        XCTAssertEqual(node.unclean.map { $0.sessionID }, ["s1"])
        XCTAssertNil(node.contradiction)
    }

    func testRefusalCodesHaveWordsAndUnknownOnesKeepTheDaemonsMessage() {
        XCTAssertEqual(LoomError.server(code: "busy", message: "x", details: nil).errorDescription, Refusal.words(code: "busy"))
        XCTAssertEqual(LoomError.server(code: "zzz", message: "m", details: nil).errorDescription, "zzz: m")
    }

    func testOperatorCommandsQuoteAndRefuseNames() {
        XCTAssertEqual(OperatorCommands.renew("box"), "loom distribution renew box")
        XCTAssertEqual(OperatorCommands.revoke("it's"), "loom distribution revoke 'it'\\''s' --reason 'REASON'")
        XCTAssertNil(OperatorCommands.renew("-rf"))
        XCTAssertNil(OperatorCommands.renew(""))
        XCTAssertEqual(OperatorCommands.release(session: "01a1-b"), "loomd executor release 01a1-b")
        XCTAssertEqual(
            OperatorCommands.enroll("box", node: "loom@box", role: "executor", links: "hub"),
            "loom distribution enroll box --node loom@box --role executor --links hub"
        )
    }
}

final class ClaimTests: XCTestCase {
    func testTheDigestIsSHA256InLowercaseHexadecimal() {
        XCTAssertEqual(Claim.digest(of: "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testACredentialIs64HexadecimalCharactersAndDiffers() {
        let first = Claim.newCredential()
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(first, Claim.newCredential())
    }

    func testOnlyAWellFormedClaimTokenIsOne() {
        XCTAssertTrue(Claim.isClaimToken("loomclaim_" + String(repeating: "a", count: 64)))
        XCTAssertFalse(Claim.isClaimToken(String(repeating: "a", count: 64)))
        XCTAssertFalse(Claim.isClaimToken("loomclaim_abc"))
    }

    func testTheClaimRouteDropsAPastedPathAndRefusesCleartextAway() throws {
        XCTAssertEqual(try Claim.claimURL(address: "ws://127.0.0.1:7441/v2/claim").absoluteString, "ws://127.0.0.1:7441/v2/claim")
        XCTAssertEqual(try Claim.claimURL(address: "wss://box.example.ts.net/v2/control").absoluteString, "wss://box.example.ts.net/v2/claim")
        XCTAssertThrowsError(try Claim.claimURL(address: "ws://box.example.com:7441"))
    }
}

final class LaunchWordsTests: XCTestCase {
    func testTheLineNamesTheAddressAndTheSession() {
        XCTAssertEqual(
            LaunchWords.line(address: "ws://10.0.0.4:7000", session: "0198c1aa"),
            "loom --addr ws://10.0.0.4:7000 --session 0198c1aa --token-file <owner token file on that host>"
        )
    }

    func testAMissingAddressIsAPlaceholder() {
        XCTAssertTrue(LaunchWords.line(address: nil, session: "s").hasPrefix("loom --addr <its control address> --session s"))
    }
}

final class RefusalWordsTests: XCTestCase {
    func testEveryCreationRefusalHasPlainWords() {
        for code in ["invalid_workspace", "invalid_configuration", "invalid_name", "unknown_profile", "unknown_model",
                     "executor_unknown", "pool_unknown", "not_initialized", "forbidden", "unavailable"] {
            XCTAssertNotNil(Refusal.words(code: code), code)
        }
        XCTAssertNil(Refusal.words(code: "something_new"))
        XCTAssertEqual(Refusal.words(code: "conflict", message: "there is nothing to compact"), "Nothing to compact yet.")
    }
}

final class UnopenedWordsTests: XCTestCase {
    func testTheDaemonsReasonLosesItsProtocolCodes() {
        let words = Refusal.unopened(reason: "start_failed: executor_unavailable: no workspace named `x`")
        XCTAssertTrue(words.hasSuffix("The daemon said: no workspace named `x`"))
        XCTAssertFalse(words.contains("start_failed"))
    }
}
