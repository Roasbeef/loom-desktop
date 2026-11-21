import Foundation
import XCTest
@testable import LoomKit
@testable import MissionKit

/// The attention inbox's rule (`MissionKit/InboxRule.swift`), which mirrors the web
/// view's `inbox_rule.gleam`, `attention_rule.gleam` and `thread_words.gleam`. The
/// named cases below are the Gleam suite's cases (`inbox_rule_test.gleam`,
/// `attention_rule_test.gleam`, `thread_words_test.gleam`, `inbox_folders_test.gleam`),
/// each saying which it ports. The property tests use a fixed seed, as the Gleam ones
/// do with qcheck, so a failure repeats.
final class InboxRuleTests: XCTestCase {
    private let seed: UInt64 = 20_261_118

    // MARK: Builders

    private func activity(
        _ state: String, approvals: Int = 0, message: String? = nil, at: Int? = nil, turn: Int? = nil,
        glances: [(String, String)] = []
    ) -> SessionActivity {
        var fields: [String: JSONValue] = ["session_id": "x", "state": .string(state), "approvals": .int(Int64(approvals))]
        if let message { fields["last_message"] = .string(message) }
        if let at { fields["last_message_at"] = .int(Int64(at)) }
        if let turn { fields["turn_started_at"] = .int(Int64(turn)) }
        fields["glances"] = .array(glances.map { ["strand": "s", "title": .string($0.0), "summary": .string($0.1)] })
        return SessionActivity(.object(fields))!
    }

    private func thread(_ id: String, _ name: String, _ activity: SessionActivity?) -> InboxThread {
        InboxThread(id: id, name: name, activity: activity)
    }

    private func ask(_ id: String, _ at: Int) -> AttentionAsk {
        AttentionAsk(id: id, strand: "main", createdAt: at, head: "Which?", questions: 1)
    }

    private func find(_ id: String, _ at: Int, kind: FindKind = .bug) -> AttentionFind {
        AttentionFind(id: id, strand: "main", kind: kind, createdAt: at, head: "Noticed", path: nil, line: nil)
    }

    private func feed(
        _ session: String, asks: [AttentionAsk] = [], finds: [AttentionFind] = [], stuck: [AttentionStuck] = []
    ) -> AttentionRow {
        AttentionRow(
            sessionID: session,
            asks: .init(count: asks.count, items: asks), finds: .init(count: finds.count, items: finds),
            stuck: .init(count: stuck.count, items: stuck)
        )
    }

    private func sections(
        _ threads: [InboxThread], feed rows: [AttentionRow] = [], raised: [String: Int] = [:],
        reviewing: Set<String> = [], now: Int = 10_000_000
    ) -> [InboxSection] {
        InboxRule.sections(InboxRule.rows(
            threads: threads, feed: Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionID, $0) }),
            raised: raised, reviewing: reviewing, now: now, clock: { "t\($0)" }
        ))
    }

    private func ids(_ section: InboxSection?) -> [String] {
        section?.rows.map(\.sessionID) ?? []
    }

    // MARK: Kinds and groups

    /// Ports `every_activity_and_message_has_one_group_test`: every activity with
    /// every sort of message (none, only whitespace, words) lands in one group. The
    /// daemon's `needs_you` splits into an approval and a failed run by the count.
    func testEveryActivityAndMessageHasOneGroup() {
        let messages: [String?] = [nil, "   \n", "Done."]
        var found: [String] = []
        for (label, state, approvals) in [("approval", "needs_you", 1), ("failed", "needs_you", 0), ("working", "working", 0), ("idle", "idle", 0)] {
            for message in messages {
                let kind = InboxRule.kind(of: thread("a", "n", activity(state, approvals: approvals, message: message)))!
                found.append("\(label)/\(message.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "blank" : "words" } ?? "none") -> \(InboxRule.group(of: kind).title)")
            }
        }
        XCTAssertEqual(found, [
            "approval/none -> Needs you", "approval/blank -> Needs you", "approval/words -> Needs you",
            "failed/none -> Needs you", "failed/blank -> Needs you", "failed/words -> Needs you",
            "working/none -> Updates", "working/blank -> Updates", "working/words -> Updates",
            "idle/none -> Folded", "idle/blank -> Folded", "idle/words -> Waiting",
        ])
    }

    /// Ports `the_kinds_have_their_words_test`, with the chips the feed's kinds add.
    func testTheKindsHaveTheirWords() {
        XCTAssertEqual(
            [InboxKind.approval, .failed, .waiting, .working, .quiet, .review, .ask, .stuck, .find(.bug), .find(.question)].map(\.chip),
            ["Approval", "Failed", "Waiting", "Update", "Quiet", "Review", "Ask", "Stuck", "Bug", "Question"]
        )
    }

    func testASessionTheDaemonDidNotReportHasNoThread() {
        XCTAssertNil(InboxRule.kind(of: thread("a", "n", nil)))
        XCTAssertNil(InboxRule.kind(of: thread("a", "n", activity("unknown"))))
        XCTAssertEqual(sections([thread("a", "n", nil)]), [])
    }

    func testTheGroupsAreListedInTheDesignsOrderWithItsWords() {
        XCTAssertEqual(InboxGroup.allCases.map(\.title), ["Needs you", "To review", "Waiting", "Finds", "Updates", "Folded"])
        XCTAssertEqual(InboxGroup.updates.gloss, "working, nothing asked; message them here")
        XCTAssertEqual(InboxGroup.needsYou.gloss, "agents stopped for you")
        XCTAssertEqual(InboxGroup.toReview.gloss, InboxGroup.waiting.gloss)
    }

    /// Ports `only_an_idle_session_with_changes_moves_to_review_test`: a finished
    /// session named in `reviewing` moves from Waiting to To review, and nothing but
    /// an idle session with a message ever moves.
    func testOnlyAnIdleSessionWithAMessageMovesToReview() {
        let threads = [
            thread("a", "idle", activity("idle", message: "Done.")),
            thread("b", "other", activity("idle", message: "Done.")),
            thread("c", "busy", activity("working", message: "Doing.")),
            thread("d", "silent", activity("idle")),
        ]
        let moved = sections(threads, reviewing: ["a", "c", "d", "z"])
        XCTAssertEqual(moved.map(\.group), [.toReview, .waiting, .updates, .quiet])
        XCTAssertEqual(moved.map { ids($0) }, [["a"], ["b"], ["c"], ["d"]])
        XCTAssertEqual(sections(threads, reviewing: []).map(\.group), [.waiting, .updates, .quiet])
    }

    // MARK: Heads

    /// Ports `the_head_falls_back_in_order_test`: the first line with words, else the
    /// newest glance, else (here, as `thread_head`) the session's name.
    func testTheHeadFallsBackInOrder() {
        let glances = [("", "newest"), ("", "older")]
        XCTAssertEqual(InboxRule.threadHead(thread("a", "n", activity("idle", message: "\n  First line  \nSecond"))), "First line")
        XCTAssertEqual(InboxRule.threadHead(thread("a", "n", activity("working", glances: glances))), "newest")
        XCTAssertEqual(InboxRule.threadHead(thread("a", "n", activity("working", message: " \n ", glances: glances))), "newest")
        XCTAssertEqual(InboxRule.threadHead(thread("a", "build", activity("working"))), "build")
        XCTAssertEqual(InboxRule.threadHead(thread("a", "build", activity("idle", glances: [("t", "  ")]))), "build")
    }

    /// Ports `a_thread_with_nothing_said_is_headed_by_its_name_test`.
    func testAThreadWithNothingSaidIsHeadedByItsName() {
        let working = activity("working")
        XCTAssertEqual(InboxRule.threadHead(thread("abcdef0123", "build", working)), "build")
        XCTAssertEqual(InboxRule.threadHead(thread("abcdef0123", " ", working)), "Session abcdef01")
        XCTAssertEqual(InboxRule.threadHead(thread("abcdef0123", "build", activity("idle", message: "Done."))), "Done.")
    }

    /// Ports `a_long_head_is_cut_inside_the_cap_test` and
    /// `the_cut_never_splits_a_grapheme_test`.
    func testALongHeadIsCutInsideTheCapAndNeverSplitsACharacter() {
        let exact = String(repeating: "a", count: 120)
        XCTAssertEqual(InboxRule.cut(exact), exact)
        let cut = InboxRule.cut(exact + "b")
        XCTAssertEqual(cut.count, 120)
        XCTAssertTrue(cut.hasSuffix("\u{2026}"))

        // A family emoji is one character of seven scalars, and a letter with a
        // combining accent is one of two. Neither is split at the cut.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let text = String(repeating: "a", count: 118) + family + "tail"
        XCTAssertEqual(InboxRule.cut(text), String(repeating: "a", count: 118) + family.prefix(1) + "\u{2026}")
        XCTAssertEqual(InboxRule.cut(text).count, 120)
        let accented = String(repeating: "a", count: 118) + "e\u{0301}" + "xx"
        XCTAssertEqual(InboxRule.cut(accented), String(repeating: "a", count: 118) + "e\u{0301}" + "\u{2026}")
    }

    /// Ports `no_head_is_longer_than_the_cap_test`, over 200 generated strings that
    /// mix ASCII, accents, emoji joiners, newlines and blanks.
    func testNoHeadIsLongerThanTheCap() {
        var generator = SeededGenerator(seed: seed)
        let pieces = ["a", "b", " ", "\n", "e\u{0301}", "\u{1F468}\u{200D}\u{1F469}", "\u{00E9}", "\u{4E2D}", "x"]
        for _ in 0..<200 {
            let length = Int.random(in: 0..<400, using: &generator)
            let message = (0..<length).map { _ in pieces.randomElement(using: &generator)! }.joined()
            let head = InboxRule.threadHead(thread("abcdef012345", "name", activity("idle", message: message)))
            XCTAssertLessThanOrEqual(head.count, InboxRule.headCharacters, "message: \(message.debugDescription)")
        }
    }

    func testANameIsTrimmedAndAnEmptyOneIsTheIdentity() {
        XCTAssertEqual(InboxRule.shownName(thread("abcdef012345", "  web ui ", nil)), "web ui")
        XCTAssertEqual(InboxRule.shownName(thread("abcdef012345", "", nil)), "Session abcdef01")
    }

    // MARK: Ordering

    /// Ports `threads_are_grouped_in_order_and_sorted_by_name_test`: same-named threads
    /// fall back to the identity, and capitals sort first.
    func testThreadsAreGroupedInOrderAndSortedByName() {
        let found = sections([
            thread("1", "zeta", activity("working")),
            thread("2", "beta", activity("idle", message: "Hi")),
            thread("3", "alpha", activity("needs_you", approvals: 1)),
            thread("4", "Alpha", activity("needs_you")),
            thread("5", "quiet one", activity("idle")),
            thread("6", "alpha", activity("needs_you", approvals: 1)),
        ])
        XCTAssertEqual(found.map(\.group), [.needsYou, .waiting, .updates, .quiet])
        XCTAssertEqual(found.map { ids($0) }, [["4", "3", "6"], ["2"], ["1"], ["5"]])
    }

    /// The web orders session threads by the raw name, so a name with a leading space
    /// or no name at all is listed where the web lists it, not where its shown name
    /// would put it.
    func testThreadsAreOrderedByTheRawNameAsTheWebOrdersThem() {
        let found = sections([
            thread("1", "b", activity("working")),
            thread("2", " c", activity("working")),
            thread("3", "", activity("working")),
            thread("4", "a", activity("working")),
        ])
        XCTAssertEqual(found.map { ids($0) }, [["3", "2", "4", "1"]])
    }

    func testARefusedApprovalReadKeepsTheAgeOfASessionStillWaiting() {
        let kept = InboxRule.raisedTimes(previous: ["a": 5, "b": 7, "gone": 9], read: ["b": 8], approving: ["a", "b"])
        XCTAssertEqual(kept, ["a": 5, "b": 8], "a read time replaces the old one, and a session with no approval keeps none")
        XCTAssertEqual(InboxRule.raisedTimes(previous: ["a": 5], read: [:], approving: []), [:])
    }

    /// Ports `an_empty_group_is_not_listed_test`.
    func testAnEmptyGroupIsNotListed() {
        XCTAssertEqual(sections([]), [])
        XCTAssertEqual(sections([thread("1", "a", activity("working"))]).map(\.group), [.updates])
    }

    /// Ports `needs_you_ranks_the_longest_wait_first_and_unknown_last_test`: the
    /// stuck strand with a time is oldest, then the ask at 100, then the two at 200
    /// by session, and the one with no time last. Finds are not in this group.
    func testNeedsYouRanksTheLongestWaitFirstAndUnknownLast() {
        let found = sections(
            [thread("a", "A", nil), thread("b", "B", nil), thread("c", "C", nil)],
            feed: [
                feed("b", asks: [ask("ask-b", 200)], stuck: [AttentionStuck(strand: "sub:b")]),
                feed("a", asks: [ask("ask-a", 200)], stuck: [AttentionStuck(strand: "sub:a", failedAt: 50)]),
                feed("c", asks: [ask("ask-c", 100)], finds: [find("find-c", 1)]),
            ]
        )
        XCTAssertEqual(found.map(\.group), [.needsYou, .finds])
        XCTAssertEqual(found[0].rows.map(\.id), [
            "stuck/a/sub:a", "ask/c/ask-c", "ask/a/ask-a", "ask/b/ask-b", "stuck/b/sub:b",
        ])
        XCTAssertEqual(found[1].rows.map(\.id), ["find/c/find-c"])
    }

    /// The feed's items come before the sessions' own threads in "Needs you", which
    /// are then by name, as the web draws the feed's rows as the group's first rows.
    func testFeedItemsPrecedeSessionThreadsInNeedsYou() {
        let found = sections(
            [thread("p", "pending", activity("needs_you", approvals: 1)), thread("q", "asking", activity("working"))],
            feed: [feed("q", asks: [ask("ask-q", 5)])]
        )
        XCTAssertEqual(found[0].rows.map(\.id), ["ask/q/ask-q", "session/p"])
    }

    func testFindsAreOrderedByHowLongTheyHaveBeenOpen() {
        let found = sections([thread("a", "A", nil), thread("b", "B", nil)], feed: [
            feed("a", finds: [find("find-2", 30)]), feed("b", finds: [find("find-1", 10), find("find-3", 20)]),
        ])
        XCTAssertEqual(found[0].rows.map(\.id), ["find/b/find-1", "find/b/find-3", "find/a/find-2"])
    }

    /// Property: the list is a function of what it is given and not of the order it
    /// was given in, so two reads of the same data draw the same list.
    func testTheListDoesNotDependOnTheOrderOfItsInputs() {
        var generator = SeededGenerator(seed: seed)
        let states: [(String, Int)] = [("needs_you", 1), ("needs_you", 0), ("working", 0), ("idle", 0)]
        for _ in 0..<100 {
            let count = Int.random(in: 0..<9, using: &generator)
            var threads: [InboxThread] = []
            var rows: [AttentionRow] = []
            for index in 0..<count {
                let (state, approvals) = states.randomElement(using: &generator)!
                let message = [nil, "Said it.", "  "].randomElement(using: &generator)!
                // Names collide on purpose, so the tie-break is exercised.
                threads.append(thread("s\(index)", ["a", "b", "A"].randomElement(using: &generator)!, activity(state, approvals: approvals, message: message)))
                if Bool.random(using: &generator) {
                    rows.append(feed(
                        "s\(index)",
                        asks: (0..<Int.random(in: 0..<3, using: &generator)).map { ask("ask-\(index)\($0)", Int.random(in: 0..<4, using: &generator)) },
                        finds: (0..<Int.random(in: 0..<3, using: &generator)).map { find("find-\(index)\($0)", Int.random(in: 0..<4, using: &generator)) },
                        stuck: Bool.random(using: &generator) ? [AttentionStuck(strand: "sub:\(index)", failedAt: Bool.random(using: &generator) ? 3 : nil)] : []
                    ))
                }
            }
            let reviewing = Set(threads.filter { _ in Bool.random(using: &generator) }.map(\.id))
            let straight = sections(threads, feed: rows, reviewing: reviewing)
            let shuffled = sections(threads.shuffled(using: &generator), feed: rows.shuffled(using: &generator), reviewing: reviewing)
            XCTAssertEqual(straight, shuffled)

            // Every row is in exactly one section, and a folder's count is the number of
            // rows its band draws.
            let all = InboxRule.rows(threads: threads, feed: Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionID, $0) }), reviewing: reviewing, now: 10_000_000)
            XCTAssertEqual(straight.reduce(0) { $0 + $1.count }, all.count)
            for entry in InboxRule.folderEntries(straight) {
                guard let count = entry.count else { continue }
                XCTAssertEqual(count, InboxRule.visible(straight, in: entry.folder).first?.count)
            }
        }
    }

    // MARK: Ages

    /// Ports `a_wait_is_worded_as_the_row_says_it_test` and
    /// `a_wait_of_an_hour_is_marked_and_a_shorter_one_is_not_test`.
    func testAWaitIsWordedAsTheRowSaysIt() {
        XCTAssertEqual(InboxRule.shortAge(30_000), "now")
        XCTAssertEqual(InboxRule.shortAge(2_400_000), "40m")
        XCTAssertEqual(InboxRule.shortAge(4_920_000), "1h 22m")
        XCTAssertEqual(InboxRule.shortAge(10_800_000), "3h 00m")
        XCTAssertEqual(InboxRule.shortAge(3 * 86_400_000), "3d")

        XCTAssertEqual(InboxRule.age(since: 0, now: 3_600_000)?.isOverdue, true)
        XCTAssertEqual(InboxRule.age(since: 0, now: 3_599_999)?.isOverdue, false)
        XCTAssertNil(InboxRule.age(since: nil, now: 5))
    }

    /// A wait from the future, as a clock that stepped back gives, is "now".
    func testAWaitFromTheFutureIsNow() {
        XCTAssertEqual(InboxRule.age(since: 500, now: 0)?.words, "now")
    }

    /// Ports `dated_threads` in `home.gleam`: an approval is aged from its raise
    /// time, a finished session from its last message, a working one from the turn's
    /// start, and a session whose data holds none has no age.
    func testEachThreadIsAgedFromTheTimeItsKindUses() {
        let found = sections([
            thread("p", "pending", activity("needs_you", approvals: 1, at: 1)),
            thread("q", "unraised", activity("needs_you", approvals: 1)),
            thread("w", "waiting", activity("idle", message: "Done", at: 10_000_000 - 2_400_000)),
            thread("u", "turn", activity("working", turn: 10_000_000 - 840_000)),
            thread("f", "failed", activity("needs_you", at: 1)),
        ], raised: ["p": 10_000_000 - 4_920_000])
        func age(_ id: String) -> InboxAge? {
            found.flatMap(\.rows).first { $0.sessionID == id }?.age
        }
        XCTAssertEqual(age("p"), InboxAge(words: "1h 22m", isOverdue: true))

        // An approval is never aged from a record that carries no raise time.
        XCTAssertNil(age("q"))
        XCTAssertEqual(age("w"), InboxAge(words: "40m", isOverdue: false))
        XCTAssertEqual(age("u"), InboxAge(words: "14m", isOverdue: false))
        XCTAssertNil(age("f"))
    }

    /// A find waits on no one, so its age is never marked as long, but an ask and a
    /// stuck strand are.
    func testOnlyAnAskOrAStuckStrandIsMarkedAsLong() {
        let found = sections([thread("a", "A", nil)], feed: [
            feed("a", asks: [ask("ask-1", 0)], finds: [find("find-1", 0)], stuck: [AttentionStuck(strand: "s", failedAt: 0)]),
        ], now: 4_920_000)
        let rows = found.flatMap(\.rows)
        XCTAssertEqual(rows.map(\.age?.isOverdue), [true, true, false])
        XCTAssertEqual(rows.map(\.age?.words), ["1h 22m", "1h 22m", "1h 22m"])
        XCTAssertEqual(rows.map(\.kind), [.ask, .stuck, .find(.bug)])
    }

    // MARK: Stuck words

    /// Ports `a_stuck_head_names_the_time_it_failed_test` and
    /// `every_failure_has_a_title_and_a_head_test`.
    func testAStuckHeadNamesTheTimeItFailed() {
        let clock: (Int) -> String = { "\($0)" }
        func head(_ reason: String?, _ at: Int?) -> String {
            InboxRule.stuckHead(AttentionStuck(strand: "s", failedAt: at, reason: reason), clock: clock)
        }
        XCTAssertEqual(head("rate_limited", 1000), "Rate-limited at 1000, has not retried")
        XCTAssertEqual(head("timeout", 2000), "Provider timed out at 2000, has not retried")
        XCTAssertEqual(head("overloaded", nil), "Provider overloaded, has not retried")
        XCTAssertEqual(head("rate_limited", nil), "Rate-limited, has not retried")
        XCTAssertEqual(head("provider_error", 5), "Stopped on a failed run")
        XCTAssertEqual(head(nil, 5), "Stopped on a failed run")
    }

    func testTheDefaultClockIsTheLocalTimeOfDay() {
        // The zone is the machine's, so the test states the expectation in that zone
        // and does not depend on what it is.
        let ms = 1_763_400_000_000
        XCTAssertEqual(ClockTime.local(ms), ClockTime.words(ms, in: .current))
        XCTAssertEqual(ThreadRule.render([.clock(ms)]), ClockTime.words(ms, in: .current))
    }

    // MARK: Folders

    private func mixed() -> [InboxSection] {
        sections([
            thread("b", "approval", activity("needs_you", approvals: 1, message: "Approve the push?")),
            thread("a", "finished", activity("idle", message: "Done.")),
            thread("c", "working", activity("working", glances: [("", "reading the spec")])),
        ])
    }

    /// Ports `only_the_groups_that_hold_something_have_a_folder_test`.
    func testOnlyTheGroupsThatHoldSomethingHaveAFolder() {
        let entries = InboxRule.folderEntries(mixed())
        XCTAssertEqual(entries.map(\.folder), [.everything, .needing, .updating])
        XCTAssertEqual(entries.map { $0.count }, [nil, 1, 1])
        XCTAssertEqual(entries.map(\.folder.title), ["Everything, by need", "Needs you", "Updates"])
    }

    /// Ports `a_press_narrows_the_list_and_everything_clears_it_test`: Waiting and the
    /// folded line have no folder, so they show only under Everything.
    func testAFolderNarrowsTheListAndEverythingClearsIt() {
        let all = mixed()
        XCTAssertEqual(InboxRule.visible(all, in: .updating).map(\.group), [.updates])
        XCTAssertEqual(InboxRule.visible(all, in: .needing).map(\.group), [.needsYou])
        XCTAssertEqual(InboxRule.visible(all, in: .everything).map(\.group), [.needsYou, .waiting, .updates])
    }

    /// Ports `a_press_for_an_unlisted_folder_changes_nothing_test` and
    /// `an_emptied_folder_draws_as_everything_test`.
    func testAnUnlistedOrEmptiedFolderShowsEverything() {
        let all = mixed()
        XCTAssertEqual(InboxRule.shownFolder(chosen: .reviewing, sections: all), .everything)
        XCTAssertEqual(InboxRule.shownFolder(chosen: .finding, sections: all), .everything)
        XCTAssertEqual(InboxRule.shownFolder(chosen: .updating, sections: all), .updating)

        let emptied = sections([thread("c", "working", activity("idle"))])
        XCTAssertEqual(InboxRule.shownFolder(chosen: .updating, sections: emptied), .everything)
    }

    // MARK: The board

    private func board(
        _ threads: [InboxThread], feed rows: [AttentionRow] = [], saved: InboxSaved = .unchecked, now: Int = 10_000_000
    ) -> InboxBoard {
        InboxRule.board(
            threads: threads, feed: Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionID, $0) }),
            saved: saved, now: now, clock: { "t\($0)" }
        )
    }

    /// Ports `the_bar_counts_what_waits_on_the_owner_test`: the badge is the "Needs
    /// you" count, and a calm inbox has none. It now reads the board, which counts a
    /// failed run as well.
    func testTheBadgeCountsWhatWaitsOnTheOwner() {
        XCTAssertEqual(board([thread("b", "approval", activity("needs_you", approvals: 1, message: "Approve?"))]).needing, 1)
        XCTAssertEqual(board([thread("c", "w", activity("working"))]).needing, 0)
        let more = board([thread("a", "A", activity("needs_you"))], feed: [feed("a", asks: [ask("ask-1", 1)], stuck: [AttentionStuck(strand: "s")])])
        XCTAssertEqual(more.needing, 3)
    }

    /// A session whose only open item is an ask is idle to the daemon's activity read,
    /// and the board still counts it. This is the case the old count missed.
    func testAnAskOnlySessionRaisesTheCountOnEverySurface() {
        let waiting = board([thread("a", "Ask only", activity("idle"))], feed: [feed("a", asks: [ask("ask-1", 1)])])
        XCTAssertEqual(waiting.needing, 1)
        XCTAssertEqual(waiting.subtitle, "1 waiting")
        XCTAssertEqual(waiting.dockLabel, "1")
        XCTAssertEqual(waiting.needingSessions, ["a"])
        XCTAssertEqual(waiting.needsYou.map(\.kind), [.ask])
        XCTAssertTrue(InboxRule.headline(waiting.tally).hasPrefix("1 needs you"))
    }

    /// An approval and an ask count two, whether they sit on one session or two, and
    /// a session with both is one entry in the sessions that need the owner.
    func testAnApprovalAndAnAskCountTwo() {
        let one = board([thread("a", "Both", activity("needs_you", approvals: 1))], feed: [feed("a", asks: [ask("ask-1", 1)])])
        XCTAssertEqual(one.needing, 2)
        XCTAssertEqual(one.subtitle, "2 waiting")
        XCTAssertEqual(one.needsYou.count, 2)
        XCTAssertEqual(one.needingSessions, ["a"])

        let two = board(
            [thread("a", "A", activity("needs_you", approvals: 1)), thread("b", "B", activity("idle"))],
            feed: [feed("b", asks: [ask("ask-1", 1)])]
        )
        XCTAssertEqual(two.needing, 2)
        XCTAssertEqual(Set(two.needingSessions), ["a", "b"])
    }

    /// A failed run needs the owner, as the web's "Needs you" band holds it.
    func testAFailedRunCountsAsNeedingTheOwner() {
        let failed = board([thread("a", "Failed", activity("needs_you"))])
        XCTAssertEqual(failed.needing, 1)
        XCTAssertEqual(failed.needsYou.map(\.kind), [.failed])
    }

    /// Nothing waiting is zero on every surface: no subtitle, no Dock label, no
    /// session to jump to. Working and finished sessions do not need the owner.
    func testNothingWaitingCountsZero() {
        let calm = board([
            thread("a", "Working", activity("working")), thread("b", "Done", activity("idle", message: "Done.")),
            thread("c", "Quiet", activity("idle")),
        ], feed: [feed("a", finds: [find("find-1", 1)])])
        XCTAssertEqual(calm.needing, 0)
        XCTAssertEqual(calm.subtitle, "")
        XCTAssertNil(calm.dockLabel)
        XCTAssertEqual(calm.needingSessions, [])
        XCTAssertEqual(calm.needsYou, [])
        XCTAssertEqual(board([]), .empty)
    }

    /// The saved sessions' summaries count in the same number, as the web's top-bar
    /// pill counts them, though they have no row.
    func testTheBoardCountsSavedSessionsWithoutRowsForThem() {
        let saved = InboxSaved.read(listed: ["s1"], rows: ["s1": SavedAttention(sessionID: "s1", pendingApprovals: 1, openAsks: 1, openFinds: 0, updatedAt: 5)])
        let counted = board([thread("a", "A", activity("idle"))], feed: [feed("a", asks: [ask("ask-1", 1)])], saved: saved)
        XCTAssertEqual(counted.needing, 3)
        XCTAssertEqual(counted.needsYou.count, 1)
        XCTAssertEqual(counted.subtitle, "3 waiting")
    }

    /// Counting the ages to a later time moves no count and no group.
    func testAgingTheBoardMovesOnlyTheAges() {
        let first = board([thread("a", "A", activity("idle"))], feed: [feed("a", asks: [ask("ask-1", 9_000_000)])], now: 9_000_000)
        let later = first.aged(now: 9_000_000 + 2 * 3_600_000)
        XCTAssertEqual(first.needsYou.first?.age?.words, "now")
        XCTAssertEqual(later.needsYou.first?.age?.words, "2h 00m")
        XCTAssertEqual(later.needing, first.needing)
        XCTAssertEqual(later.sections.map(\.group), first.sections.map(\.group))
    }

    /// The sidebar's Needs You group is built from the same board: a session with an
    /// ask leads the status grouping though its activity read says idle, and says so.
    func testTheSidebarsNeedsYouGroupReadsTheBoard() {
        let sidebar = SidebarTests.sidebarRecord("a")
        let quiet = SidebarTests.sidebarRecord("b")
        let found = board([thread("a", "A", activity("idle")), thread("b", "B", activity("idle"))], feed: [feed("a", asks: [ask("ask-1", 1)])])
        let sections = SidebarRows.sections(
            [sidebar, quiet], activity: ["a": activity("idle"), "b": activity("idle")], grouping: .status,
            machine: { _ in "m" }, needing: Set(found.needingSessions)
        )
        XCTAssertEqual(sections.map(\.title), ["Needs You", "Idle"])
        XCTAssertEqual(sections[0].rows.map(\.id), ["a"])
        XCTAssertEqual(sections[0].rows.first?.standing, "needs you")
        XCTAssertEqual(sections[1].rows.map(\.id), ["b"])
    }

    /// A quiet session with any feed row is not folded. The web folds it as well as
    /// listing the item; this app departs from that until Loom changes.
    func testAQuietSessionWithAFeedRowIsNotFolded() {
        for items in [feed("a", asks: [ask("ask-1", 1)]), feed("a", stuck: [AttentionStuck(strand: "s")]), feed("a", finds: [find("find-1", 1)])] {
            let groups = sections([thread("a", "Quiet", activity("idle"))], feed: [items]).map(\.group)
            XCTAssertFalse(groups.contains(.quiet), "\(items) left the session folded: \(groups)")
        }

        // With nothing in the feed it is folded as before, and so is a quiet session
        // whose feed row is empty.
        XCTAssertEqual(sections([thread("a", "Quiet", activity("idle"))]).map(\.group), [.quiet])
        XCTAssertEqual(sections([thread("a", "Quiet", activity("idle"))], feed: [feed("a")]).map(\.group), [.quiet])

        // The item still lists, under its own group.
        let found = sections([thread("a", "Quiet", activity("idle"))], feed: [feed("a", finds: [find("find-1", 1)])])
        XCTAssertEqual(found.map(\.group), [.finds])
    }

    // MARK: Selection

    /// Ports `the_selection_defaults_to_the_first_thread_and_forgets_stale_choices_test`.
    func testTheSelectionDefaultsToTheFirstThreadAndForgetsStaleChoices() {
        let all = sections([thread("w", "work", activity("working")), thread("n", "need", activity("needs_you", approvals: 1))])
        XCTAssertEqual(InboxRule.selection(all, chosen: nil), .session("n"))
        XCTAssertEqual(InboxRule.selection(all, chosen: .session("w")), .session("w"))
        XCTAssertEqual(InboxRule.selection(all, chosen: .session("gone")), .session("n"))
        XCTAssertNil(InboxRule.selection([], chosen: .session("w")))
        XCTAssertNil(InboxRule.selection([], chosen: nil))

        // The folded quiet line holds names, not threads.
        let quiet = sections([thread("q", "quiet", activity("idle"))])
        XCTAssertNil(InboxRule.selection(quiet, chosen: nil))

        // An ask and a stuck strand that share a text are different threads.
        let both = sections([thread("a", "A", nil)], feed: [feed("a", asks: [ask("x", 1)], stuck: [AttentionStuck(strand: "x", failedAt: 2)])])
        XCTAssertEqual(InboxRule.selection(both, chosen: .stuck(session: "a", strand: "x")), .stuck(session: "a", strand: "x"))
        XCTAssertEqual(InboxRule.selection(both, chosen: .find(session: "a", id: "x")), InboxRule.selection(both, chosen: nil))
    }

    /// Property: whatever is chosen, the selection is a row that is listed, and it
    /// is nothing only when no selectable row exists.
    func testTheSelectionIsAlwaysARowThatIsListed() {
        var generator = SeededGenerator(seed: seed)
        for _ in 0..<100 {
            let threads = (0..<Int.random(in: 0..<7, using: &generator)).map { index -> InboxThread in
                let state = ["needs_you", "working", "idle"].randomElement(using: &generator)!
                return thread("s\(index)", "n\(index)", activity(state, approvals: Int.random(in: 0..<2, using: &generator), message: Bool.random(using: &generator) ? "m" : nil))
            }
            let found = sections(threads)
            let chosen: InboxSubject? = [nil, .session("s0"), .session("s3"), .session("none")].randomElement(using: &generator)!
            let picked = InboxRule.selection(found, chosen: chosen)
            let selectable = found.filter { $0.group != .quiet }.flatMap(\.rows).map(\.subject)
            XCTAssertEqual(picked == nil, selectable.isEmpty)
            if let picked { XCTAssertTrue(selectable.contains(picked)) }
        }
    }

    // MARK: Counts

    /// Ports `the_headline_says_what_it_read_test` and the tally cases of
    /// `running_sessions_count_their_rows_and_an_activity_approval_test`, with the
    /// departure that this client never reads saved sessions.
    func testTheHeadlineSaysWhatItRead() {
        let threads = [
            thread("a", "A", activity("needs_you", approvals: 1)),
            thread("b", "B", activity("needs_you")),
            thread("c", "C", activity("working")),
        ]
        let rows = Dictionary(uniqueKeysWithValues: [
            feed("a", asks: [ask("ask-1", 1)], finds: [find("find-1", 1)]),
            feed("c", stuck: [AttentionStuck(strand: "s")]),
        ].map { ($0.sessionID, $0) })
        let tally = InboxRule.tally(threads: threads, feed: rows)

        // The approval, the ask, the stuck strand and the failed run (b) count, since
        // the board counts what the web's "Needs you" band holds; b has no feed row.
        // The failed run is counted as of the one-count change; it was not before.
        XCTAssertEqual(tally, InboxTally(needing: 4, finds: 1, running: 3, unread: 1))
        XCTAssertEqual(InboxRule.headline(tally), "4 need you \u{00B7} 1 find \u{00B7} 3 running sessions read live, 1 not checked; saved sessions not checked")
        XCTAssertEqual(InboxRule.headline(InboxTally(needing: 1, finds: 0, running: 1, unread: 0)), "1 needs you \u{00B7} 1 running session read live; saved sessions not checked")
        XCTAssertEqual(InboxRule.headline(InboxTally()), "Nothing needs you \u{00B7} 0 running sessions read live; saved sessions not checked")
        XCTAssertEqual(InboxRule.headline(InboxTally(needing: 0, finds: 2, running: 2, unread: 0)), "Nothing needs you \u{00B7} 2 finds \u{00B7} 2 running sessions read live; saved sessions not checked")
    }

    /// A count the row reports is read as the daemon counted it, which may be more
    /// than the items the row had room to carry.
    func testTheTallyReadsTheRowsCountsAndNotJustItsItems() {
        let row = AttentionRow(sessionID: "a", asks: .init(count: 5, items: [ask("ask-1", 1)]))
        XCTAssertEqual(InboxRule.tally(threads: [thread("a", "A", activity("idle"))], feed: ["a": row]).needing, 5)
    }

    /// Ports `the_rail_note_says_what_the_counts_read_test`.
    func testTheRailNoteSaysWhatTheCountsRead() {
        XCTAssertEqual(InboxRule.countNote(running: 6), "Counts read 6 running sessions. Saved sessions are not checked.")
        XCTAssertEqual(InboxRule.countNote(running: 1), "Counts read 1 running session. Saved sessions are not checked.")
    }

    // MARK: Saved sessions

    private func saved(_ id: String, approvals: Int = 0, asks: Int = 0, finds: Int = 0) -> SavedAttention {
        SavedAttention(sessionID: id, pendingApprovals: approvals, openAsks: asks, openFinds: finds, updatedAt: 5)
    }

    /// Ports `attention_rule.tally`'s saved arm: a saved session counts its summary's
    /// approvals and asks as needing the owner, its finds apart, and is counted as
    /// taken from the catalogue.
    func testASavedSessionCountsFromItsSummary() {
        let tally = InboxRule.tally(
            threads: [thread("a", "A", activity("idle"))], feed: ["a": feed("a", asks: [ask("ask-1", 1)])],
            saved: .read(listed: ["s1", "s2"], rows: ["s1": saved("s1", approvals: 1, asks: 2, finds: 3), "s2": saved("s2")])
        )
        XCTAssertEqual(tally, InboxTally(needing: 4, finds: 3, running: 1, unread: 0, fromCatalogue: 2))
    }

    /// A listed saved session with no summary is not checked, as the web's `SavedUnread`.
    func testASavedSessionWithNoSummaryIsNotChecked() {
        let tally = InboxRule.tally(
            threads: [], feed: [:], saved: .read(listed: ["s1", "s2", "s3"], rows: ["s2": saved("s2", asks: 1)])
        )
        XCTAssertEqual(tally, InboxTally(needing: 1, finds: 0, running: 0, unread: 2, fromCatalogue: 1))

        // A row for a session the list no longer holds is not counted.
        XCTAssertEqual(InboxRule.tally(threads: [], feed: [:], saved: .read(listed: ["s1"], rows: ["gone": saved("gone", asks: 9), "s1": saved("s1")])).needing, 0)
    }

    /// The web words the saved counts only when a summary was found
    /// (`home.gleam`'s `SavedFromCatalogue` choice). With none found, or no read, the
    /// tally is what it was before the command and the line says saved sessions are
    /// not checked.
    func testNoSummaryFoundLeavesTheTallyAsItWas() {
        let threads = [thread("a", "A", activity("working"))]
        let before = InboxRule.tally(threads: threads, feed: [:])
        XCTAssertEqual(InboxRule.tally(threads: threads, feed: [:], saved: .unchecked), before)
        XCTAssertEqual(InboxRule.tally(threads: threads, feed: [:], saved: .read(listed: ["s1"], rows: [:])), before)
        XCTAssertEqual(InboxRule.tally(threads: threads, feed: [:], saved: .read(listed: [], rows: [:])), before)
    }

    /// Fixture: the example of `attention_rule.headline` in loom
    /// packages/web_view/src/web_view/attention_rule.gleam, which has no
    /// not-checked sessions, and the same line with some.
    func testTheHeadlineSaysHowManySavedSessionsCameFromTheCatalogue() {
        XCTAssertEqual(
            InboxRule.headline(InboxTally(needing: 1, finds: 2, running: 3, unread: 0, fromCatalogue: 4)),
            "1 needs you \u{00B7} 2 finds \u{00B7} 3 running sessions read live, 4 saved from the catalogue"
        )
        XCTAssertEqual(
            InboxRule.headline(InboxTally(needing: 0, finds: 0, running: 1, unread: 2, fromCatalogue: 1)),
            "Nothing needs you \u{00B7} 1 running session read live, 1 saved from the catalogue, 2 not checked"
        )
    }

    /// Fixture: `inbox_rule.count_note`'s `SavedFromCatalogue` words in loom
    /// packages/web_view/src/web_view/inbox_rule.gleam.
    func testTheRailNoteSaysSavedSessionsWereReadFromTheCatalogue() {
        XCTAssertEqual(
            InboxRule.countNote(running: 6, fromCatalogue: 2),
            "Counts read 6 running sessions live and each saved session from the catalogue's summary."
        )
        XCTAssertEqual(
            InboxRule.countNote(running: 1, fromCatalogue: 1),
            "Counts read 1 running session live and each saved session from the catalogue's summary."
        )
        XCTAssertEqual(InboxRule.countNote(running: 1, fromCatalogue: 0), "Counts read 1 running session. Saved sessions are not checked.")
    }

    func testTheLeadNamesWhatNeedsYou() {
        XCTAssertEqual(InboxRule.lead(InboxTally()), "Nothing needs you")
        XCTAssertEqual(InboxRule.lead(InboxTally(needing: 1)), "1 needs you")
        XCTAssertEqual(InboxRule.lead(InboxTally(needing: 4)), "4 need you")
    }

    // MARK: Text

    func testModelTextStaysTextOnTheRow() {
        let hostile = "<script>alert(1)</script> **bold**"
        let found = sections([thread("a", "A", activity("idle", message: hostile))])
        XCTAssertEqual(found[0].rows[0].head, hostile)
    }
}

/// A seeded random source, so a property test draws the same cases on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
