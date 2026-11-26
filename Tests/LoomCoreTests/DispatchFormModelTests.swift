import XCTest
import LoomKit
@testable import LoomCore

/// The simulation of the new-session form: edits in any order, a submit, and a daemon that
/// loses the create reply, ignores the worktree or refuses.
///
/// The production `DispatchForm` runs. The world is a daemon that holds sessions by request
/// key and records a violation when a key arrives with parameters other than the ones it was
/// first used with: a retry that would recover the wrong session. Faults, one bit each: 0 the
/// create reply is lost after the daemon applied it, 1 the daemon ignores the worktree, 2 the
/// first prompt is not acknowledged, 3 the create is refused.
///
/// Rules: O4 one key names one set of create parameters. The key does not move when only the
/// prompt changes, and moves when any create parameter does. A submit that is not allowed, or
/// that follows another, or that follows a session made without its prompt, sends nothing. A
/// key is not reused after a worktree the daemon ignored.
struct DispatchFormModel: SimSpec {
    static let modes = 2
    static let maxSteps = 48

    enum Fault: Int {
        case replyLost = 0, worktreeIgnored, promptLost, refused
    }

    struct World {
        var form = DispatchForm(seed: "form")
        var sessions: [String: (id: String, parameters: [String])] = [:]
        var pending: DispatchForm.Request?
        var retired: Set<String> = []
        var faults: Sim.FaultMask
        var violations: [Sim.Violation] = []
        var created = 0
        var sentCount = 0
        var census: [String: Int] = [:]

        mutating func count(_ key: String) { census[key, default: 0] += 1 }
    }

    func makeWorld(mode: Int, faults: Sim.FaultMask, rng: inout SimRandom) -> World {
        World(form: DispatchForm(seed: "form", daemon: "local", disk: mode == 0 ? .thisMac : .elsewhere), faults: faults)
    }

    static let folders = ["", "/a", "/b", "/missing", "/file"]

    func step(_ world: inout World, kind: Int, arg: Int, rng: inout SimRandom) throws(Sim.Violation) {
        let mask = world.faults
        let faulty = { (fault: Fault) in mask.has(fault.rawValue) && arg % 2 == 0 }
        let keyBefore = world.form.requestKey
        var createParameterChanged = false
        switch kind {
        case 0:
            let path = Self.folders[arg % Self.folders.count]
            let judged: FolderCheck = path.isEmpty ? .empty : path == "/missing" ? .missing : path == "/file" ? .notAFolder : .ok(path)
            createParameterChanged = path != world.form.fields.workspace
            _ = world.form.apply(.edit(.workspace(path, folder: judged, worktreeProblem: path == "/b" ? "That folder is not a Git repository." : nil)))
        case 1:
            // With no name typed the prompt's first line is the session's name, a create parameter.
            let before = world.form.effectiveName
            _ = world.form.apply(.edit(.prompt(arg % 3 == 0 ? "" : "do it \(arg)")))
            createParameterChanged = world.form.effectiveName != before
        case 2:
            createParameterChanged = "n\(arg % 2)" != world.form.fields.name
            _ = world.form.apply(.edit(.name("n\(arg % 2)")))
        case 3:
            let value = arg % 2 == 0 ? "" : "m\(arg % 3)"
            createParameterChanged = value != world.form.fields.model
            _ = world.form.apply(.edit(.model(value)))
        case 4:
            createParameterChanged = (arg % 2 == 0) != world.form.fields.isShareable
            _ = world.form.apply(.edit(.shareable(arg % 2 == 0)))
        case 5:
            let choice: DispatchForm.Worktree = arg % 2 == 0 ? .ownTree : .folder
            createParameterChanged = choice != world.form.fields.worktree
            _ = world.form.apply(.edit(.worktree(choice)))
        case 6:
            let base = arg % 3 == 0 ? "-bad" : arg % 3 == 1 ? "" : "main"
            createParameterChanged = base != world.form.fields.worktreeBase
            _ = world.form.apply(.edit(.worktreeBase(base, problem: base == "-bad" ? "That base cannot start with a dash." : nil)))
        case 7:
            let placement: PlacementChoice = arg % 3 == 0 ? .local : arg % 3 == 1 ? .executor("box") : .pool("boxes")
            createParameterChanged = placement != world.form.fields.placement
            _ = world.form.apply(.edit(.placement(placement)))
        case 8:
            createParameterChanged = "d\(arg % 2)" != world.form.fields.daemon
            _ = world.form.apply(.edit(.daemon("d\(arg % 2)", disk: arg % 2 == 0 ? .thisMac : .elsewhere)))
        case 9, 10: try submit(&world)
        case 11: try finish(&world, honest: true, faulty: faulty)
        case 12: try finish(&world, honest: false, faulty: faulty)
        case 13:
            createParameterChanged = "c\(arg % 2)" != world.form.fields.configuration
            _ = world.form.apply(.edit(.configuration("c\(arg % 2)")))
        default: try submit(&world)
        }

        // The key moves with every create parameter and with nothing else.
        if kind != 9, kind != 10, kind != 11, kind != 12, kind != 14, kind != 15 {
            let moved = world.form.requestKey != keyBefore
            if createParameterChanged, !moved, kind != 8 || world.form.fields.daemon != "local" {
                throw Sim.Violation("O4", "a create parameter changed (edit \(kind)) and the key stayed \(keyBefore)")
            }
            if !createParameterChanged, moved { throw Sim.Violation("O4", "the key moved (edit \(kind)) though no create parameter changed") }
        }
        if let violation = world.violations.first { throw violation }
    }

    func finish(_ world: inout World, rng: inout SimRandom) throws(Sim.Violation) {
        if let violation = world.violations.first { throw violation }
    }

    func snapshot(_ world: World) -> String {
        "key=\(world.form.requestKey) sending=\(world.form.isSending) created=\(String(describing: world.form.createdID)) sessions=\(world.sessions.keys.sorted()) sent=\(world.sentCount) census=\(world.census.sorted { $0.key < $1.key })"
    }

    func tallies(_ world: World) -> [String: Int] { world.census }

    // MARK: Ops

    private func submit(_ world: inout World) throws(Sim.Violation) {
        let allowed = world.form.canDispatch
        let wasSending = world.form.isSending
        let hadCreated = world.form.createdID != nil
        let effects = world.form.apply(.submit)
        if !allowed {
            guard effects.isEmpty else { throw Sim.Violation("O4", "a submit that is not allowed sent a request") }
            return
        }
        guard !wasSending, !hadCreated else { throw Sim.Violation("O4", "a second request was sent while one was out or after a session was made") }
        for case .dispatch(let request) in effects {
            guard !world.retired.contains(request.requestKey) else { throw Sim.Violation("O4", "key \(request.requestKey) was reused after the daemon ignored its worktree") }
            world.pending = request
            world.sentCount += 1
            world.count("submit")
        }
    }

    private func finish(_ world: inout World, honest: Bool, faulty: (Fault) -> Bool) throws(Sim.Violation) {
        guard let request = world.pending else { return }
        world.pending = nil
        var result: DispatchForm.Result
        if !honest, faulty(.refused) {
            result = .failed(words: "no capacity")
            world.count("refused")
        } else {
            let session = createdSession(&world, request)
            if !honest, faulty(.replyLost) {
                result = .failed(words: "No reply came; the session may exist.")
                world.count("replyLost")
            } else if !honest, request.wantsWorktree, faulty(.worktreeIgnored) {
                world.sessions[request.requestKey] = nil
                world.retired.insert(request.requestKey)
                result = .worktreeIgnored(words: "The daemon did not use a worktree.")
                world.count("worktreeIgnored")
            } else if !honest, faulty(.promptLost) {
                result = .createdButUnsent(session: session, words: "The message may not have arrived.")
                world.count("promptLost")
            } else {
                result = .sent(session: session)
                world.count("sent")
            }
        }
        _ = world.form.apply(.finished(result))
    }

    /// The daemon's `sessions.create`: idempotent on the key, and it notes what the key was first used with.
    private func createdSession(_ world: inout World, _ request: DispatchForm.Request) -> String {
        if let known = world.sessions[request.requestKey] {
            if known.parameters != request.createParameters {
                world.violations.append(Sim.Violation("O4", "key \(request.requestKey) recovered a session made for \(known.parameters), not \(request.createParameters)"))
            }
            return known.id
        }
        world.created += 1
        let id = "n\(world.created)"
        world.sessions[request.requestKey] = (id, request.createParameters)
        return id
    }
}

final class DispatchFormModelTests: XCTestCase {
    func testTheSwarmKeepsEveryRuleOfTheForm() {
        for generator in [Sim.generator(default: 1), Sim.generator(default: 1) + 1] {
            if let failure = Sim.check(DispatchFormModel(), runs: Sim.runs(default: 3_000), generator: generator) {
                XCTFail("generator \(generator): \(failure)")
            }
        }
    }

    func testTheSwarmReachesEveryOutcome() {
        var seen: [String: Int] = [:]
        var rng = SimRandom(seed: 51)
        for _ in 0..<3_000 {
            let length = 3 + Int(rng.next() % UInt64(DispatchFormModel.maxSteps))
            let seed = Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if case .success(let outcome) = Sim.run(DispatchFormModel(), seed: seed) {
                for (key, value) in outcome.tallies { seen[key, default: 0] += value }
            }
        }
        for key in ["submit", "sent", "replyLost", "promptLost", "refused"] where (seen[key] ?? 0) == 0 {
            XCTFail("no run reached \(key); reached \(seen.sorted { $0.key < $1.key })")
        }
    }

    /// The corpus: seeds that once failed, kept so they keep passing. The first is the campaign
    /// failure on generator 100 (the prompt's first line names the session and did not move the key).
    func testTheRegressionSeedsPass() {
        for hex in ["61000041102e211bba2b", "93000080b1cf71dcba5c"] {
            guard let seed = Sim.Seed(hex: hex), case .success = Sim.run(DispatchFormModel(), seed: seed) else { return XCTFail("seed \(hex) fails") }
        }
    }

    func testTheCorpusIsDeterministicOnTwoRuns() {
        var rng = SimRandom(seed: 53)
        let seeds = (0..<300).map { _ -> Sim.Seed in
            let length = 3 + Int(rng.next() % UInt64(DispatchFormModel.maxSteps))
            return Sim.Seed(bytes: (0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        }
        XCTAssertEqual(Sim.corpus(DispatchFormModel(), seeds: seeds), [])
    }

    /// NS-23: the worktree toggle is off by default, local only, and judges the folder.
    func testTheWorktreeChoiceIsOffByDefaultJudgesTheFolderAndRefusesADashBase() {
        var form = DispatchForm(seed: "f")
        XCTAssertEqual(form.fields.worktree, .folder)
        XCTAssertFalse(form.worktreeJudgement.wanted)
        _ = form.apply(.edit(.workspace("/repo", folder: .ok("/repo"), worktreeProblem: "That folder is not a Git repository.")))
        _ = form.apply(.edit(.prompt("go")))
        XCTAssertTrue(form.canDispatch, "with the choice off the folder alone decides")
        _ = form.apply(.edit(.worktree(.ownTree)))
        XCTAssertFalse(form.canDispatch)
        XCTAssertEqual(form.hint, "That folder is not a Git repository.")
        _ = form.apply(.edit(.workspace("/repo2", folder: .ok("/repo2"), worktreeProblem: nil)))
        _ = form.apply(.edit(.worktreeBase("-x", problem: "That base cannot start with a dash.")))
        XCTAssertFalse(form.canDispatch)
        _ = form.apply(.edit(.worktreeBase("main", problem: nil)))
        XCTAssertTrue(form.canDispatch)
        XCTAssertTrue(form.worktreeJudgement.wanted)
    }

    func testAWorktreeTheDaemonIgnoredRetiresItsKeyAndAFailedFormKeepsIt() {
        var form = DispatchForm(seed: "f")
        _ = form.apply(.edit(.workspace("/a", folder: .ok("/a"), worktreeProblem: nil)))
        _ = form.apply(.edit(.prompt("go")))
        _ = form.apply(.edit(.worktree(.ownTree)))
        let key = form.requestKey
        XCTAssertEqual(form.apply(.submit).count, 1)
        XCTAssertTrue(form.apply(.submit).isEmpty, "a second press while one is out sends nothing")
        _ = form.apply(.finished(.failed(words: "No reply came.")))
        XCTAssertEqual(form.requestKey, key, "a failed attempt keeps the key so a retry recovers the session")
        XCTAssertEqual(form.apply(.submit).count, 1)
        _ = form.apply(.finished(.worktreeIgnored(words: "ignored")))
        XCTAssertNotEqual(form.requestKey, key, "the session was removed, so its key must not recover it")
        XCTAssertEqual(form.apply(.submit).count, 1)
        _ = form.apply(.finished(.createdButUnsent(session: "s1", words: "may not have arrived")))
        XCTAssertEqual(form.createdID, "s1")
        XCTAssertTrue(form.apply(.submit).isEmpty, "sending again would make a second session")
    }

    /// Found by a long campaign: with no name typed, editing the prompt changed the name the
    /// session was created with and not the key, so a retry recovered a session named for the old prompt.
    func testEditingThePromptMovesTheKeyWhenItNamesTheSession() {
        var form = DispatchForm(seed: "f")
        _ = form.apply(.edit(.prompt("first task")))
        let key = form.requestKey
        _ = form.apply(.edit(.prompt("second task")))
        XCTAssertNotEqual(form.requestKey, key, "the first line is the name, a create parameter")
        let named = form.requestKey
        _ = form.apply(.edit(.name("My session")))
        let afterName = form.requestKey
        XCTAssertNotEqual(afterName, named)
        _ = form.apply(.edit(.prompt("third task")))
        XCTAssertEqual(form.requestKey, afterName, "with a name typed the prompt is not a create parameter")
    }

    /// The disk can change under the same text, so a fresh judgement is taken even when the text did not move.
    func testAFreshJudgementOfTheSameFolderIsTaken() {
        var form = DispatchForm(seed: "f")
        _ = form.apply(.edit(.prompt("go")))
        _ = form.apply(.edit(.workspace("/new", folder: .missing, worktreeProblem: nil)))
        XCTAssertFalse(form.canDispatch)
        let key = form.requestKey
        _ = form.apply(.edit(.workspace("/new", folder: .ok("/new"), worktreeProblem: nil)))
        XCTAssertTrue(form.canDispatch, "the folder was made, and the same text now judges well")
        XCTAssertEqual(form.requestKey, key, "the text did not change, so the key did not")
    }

    func testARetryAfterANewFolderNeverCarriesTheOldKey() {
        var form = DispatchForm(seed: "f")
        _ = form.apply(.edit(.workspace("/a", folder: .ok("/a"), worktreeProblem: nil)))
        _ = form.apply(.edit(.name("Fix the build")))
        _ = form.apply(.edit(.prompt("go")))
        let first = form.requestKey
        _ = form.apply(.edit(.prompt("go, please")))
        XCTAssertEqual(form.requestKey, first, "with a name typed the prompt is not a create parameter")
        _ = form.apply(.edit(.workspace("/b", folder: .ok("/b"), worktreeProblem: nil)))
        XCTAssertNotEqual(form.requestKey, first, "the folder is, so a retry cannot recover the session made for /a")
    }
}
