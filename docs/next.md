Baseline: 107bf9d on main (2026-11-23), plus branch `native/split-inbox` (native pass slice 2, three commits, no PR yet)

# Next: Loom Desktop handoff

Loom Desktop is the native SwiftUI client of `loomd` (the Gleam daemon in
`Roasbeef/loom`). It speaks the daemon's protocol; anything that needs the
daemon to change goes through a Loom PR. This file says where the tree is,
what to do next, what was decided, and what is left open. Where it disagrees
with the code, measure before believing it.

The previous edition (2026-11-05, on `perf/transcript-scroll`) is superseded.
Its in-flight items either landed in the parity work below or moved to
"Deliberately open".

## Where the tree is

### Native pass state (2026-11-23)

| Work | Where | State |
| --- | --- | --- |
| Inbox port (#1, #2) | `main` | Merged 2026-11-21. |
| Native pass plan | `docs/native-pass.md` on `main` | Merged with slice 1. |
| Native pass slice 1 (#3) | `main` | Merged 2026-11-21. |
| Ask card above the composer, approval arming (#6) | `main` | Merged 2026-11-23. |
| Native pass slice 2: the inbox as an `HSplitView` with a toolbar folder picker, one selection on the model, a refresh never moves it (`InboxRule.settle`) | branch `native/split-inbox`, worktree `/Users/roasbeef/gocode/src/github.com/roasbeef/ld-native` | Rebased on `107bf9d`, three commits (model, view, tests). `make test` 405 tests pass, the release bundle builds, and the full UI run was 134 passed, 7 failed. Two failures are known on main, four passed when run alone, and `an_executor_loss_is_reported` fails alone and on main. See "Verification state". Not pushed, no PR. |
| Slice 4 (native controls in the reading pane) | branch `native/reading-pane` | PR open. See slice 4 in `docs/native-pass.md`; the answer options were deliberately not converted. |
| Slice 5 (notifications) | `docs/native-pass.md` | PR open on `native/notifications`. |

### The attention inbox port

The web view's attention inbox (Loom #1316) is ported in two PRs:

| PR | Branch | What it adds |
| --- | --- | --- |
| #1, merged 2026-11-21 | `inbox/attention-design` | The inbox grouped by need, the folder rail, threads, the reading pane per kind (approval, ask, find, stuck strand, failed run, update, review), the review thread with the outbox, the lifted rail on the session page, gutter times. |
| #2 | `inbox/answer-asks` (worktree `/Users/roasbeef/gocode/src/github.com/roasbeef/ld-ask`) | Answering an ask from its pane and the rail (`attention.answer`) and counting saved sessions (`sessions.saved_attention`), both from Loom protocol-change 128 (Loom #1322). Falls back cleanly on an older daemon. |

The owner said on 2026-11-21 to merge these as needed. The local `main` in
`/Users/roasbeef/gocode/src/github.com/roasbeef/loom-desktop` fast-forwards to
`origin/main`; #1 contained its ten unpushed commits.

The other `ld-*` worktrees (`ld-inbox`, `ld-pane`, `ld-rail`, `ld-shots`,
`ld-perf`) are merged or older; remove them with `git cow remove`.

### Verification state, honestly

- `make test`: Executed 366 tests, with 0 failures (the trailing "0 tests in 0 suites" is the empty Swift Testing runner).
- `python3 tests/ui/parity_check.py` exits 0: 327 rows, 240 `yes`, 46 `code`, 17 `partial`, 24 `no`.
- Daemon: the frozen `/Users/roasbeef/loom-drives/desktop-loomd/bin/loomd` (Loom `queue/four-prs`, includes protocol-change 128), slot 6.
- Answering and saved counts have scenarios: `an_ask_is_read_and_answered_in_its_pane` (AI-10, 12, 40), `an_ask_is_answered_from_the_session_pages_rail` (AI-23, 40, 42) and `saved_sessions_are_counted_from_the_catalogue` (AI-08). They pass alone. AI-41 (refusal words, the held form) and AI-44 stay `code`/`no`; the pane's own observer case has unit tests only, because `asrole` acts on the open session.
- First full run: 125 passed, 11 failed. Six consecutive scenarios (`evolution_tab_reads_the_board_and_core`, `a_machine_is_read_in_detail`, `two_sessions_are_linked_and_unlinked`, `sidebar_rows_say_what_each_session_is_doing`, `the_sidebar_foot_opens_people_and_mission_control_lists_everyone`, `a_session_starts_on_another_daemon`) timed out on presses, four more died with "Connection closed" after the inbox scenario, and the cause is not found. All six pass together in a fresh run, and the second full run did not repeat it.
- Second full run: 133 passed, 3 failed. `evolution_tab_reads_the_board_and_core` (known, passes alone); `appearance_and_size_matrix` (`inbox-light-880` differed 3.8%, passes alone, flaky once in three runs); `the_inbox_groups_threads_by_need_and_the_rail_narrows_them`.
- Third full run, after the fixes below: 134 passed, 2 failed. `evolution_tab_reads_the_board_and_core` (known, passes alone) and `appearance_and_size_matrix`, whose cause was a capture taken before the inbox feed read landed ("2 not checked" in one run and not the next). The matrix now waits for the read, the inbox baselines were retaken in that state (`15e092a`, `0ab2a54`), and the matrix passes.
- `the_inbox_groups_threads_by_need_and_the_rail_narrows_them` failed in the first two runs because the headline counts saved sessions earlier scenarios left in the catalogue. The inbox snapshot now carries the running sessions' part of the tally, and the scenario checks its own threads exactly and the headline's total and catalogue clause (`be6a231`). It passes in the third full run.
- `generation_speed_is_timed_from_the_stream` passed in both full runs.
- README screenshots retaken at 1400 by 900 (`tests/ui/readme_shots.py`), plus `inbox.png` and `answer.png`.

## What to do next

Ordered.

### 1. Open the slice 2 PR

Push `native/split-inbox`, open the PR against `main` with the before and after
captures from `/Users/roasbeef/loom-drives/native-pass/slice2/`, and merge on
the owner's standing go once the gates pass. Slice 2's own work is done. Two
things are left for whoever picks it up:

- The `appearance_and_size_matrix` frames at 880 pt do not match on this machine,
  with or without slice 2 (about 6 percent against main's baselines too).
  Retake them on the machine that owns the baselines, or find why a capture
  here is at a different scale, before trusting that scenario again.
- `an_executor_loss_is_reported` times out waiting for a Machines item in the
  attention feed, on main as well. It was not in the list of known failures.

### 1a. What the owner found on 2026-11-23

The owner ran a build of `main` (`7604fdb`) against their daemon. Fix these
before or alongside slice 2, each with a UI scenario.

- **An open ask is not visible on a session's page.** An agent's `ask` was
  recorded as open (`open_asks = 1` in the daemon's catalogue), but the owner,
  reading the transcript, saw nothing, typed "continue", and the agent went
  ahead on its own pick. An ask was drawn only as an Inbox thread and in the
  Inspector's lifted rail, which starts hidden (⌥⌘I).
  **Done on `session/ask-card`.** `ComposerStack` draws an `AskCardView`
  (`App/Sources/AskCardView.swift`) for each open ask routed to the owner,
  oldest first, above the approval cards, so an ask appearing or leaving moves
  nothing below it. The card is headed "Ask · waiting since 13:40 · main" and
  holds the same `AskAnswering` form the Inbox pane and the rail draw. An
  observer sees the questions and the words "Only the owner or an operator can
  answer an ask." It scrolls inside itself past 300 points, and it takes no
  focus. The feed row it reads from is refreshed every five seconds, as the
  rail's is, so an ask can take up to that long to appear. The turn that called
  `ask` is marked "Ask": on its fold in the usual case, since the model's prose
  before the call is folded as narration, and on the message when the model
  wrote one after it. Which asks show, their order and the mark are
  `MissionKit/AskCard.swift`, tested in `AskCardTests`; the scenario is
  `an_ask_is_answered_from_the_card_above_the_composer`.
- **An answer showed in the transcript as raw JSON.** Loom #1348 changed the
  daemon to deliver the answer as text: "Answer to your ask ask-…", then each
  question numbered with its answer indented three spaces under it. The user
  row already draws a message's lines and indent as they arrive, and the new
  scenario checks that with the daemon of Loom main. An older daemon still
  sends a fenced JSON record, which is drawn as it is sent, so the raw JSON
  stays visible against an older daemon. That was not changed here.
- The web view's list of the same day is in Loom's `docs/next.md`; its items
  on navigation and the ask thread's layout apply here wherever the desktop
  draws the same thing.

### 2. Slices 4 and 5 of the native pass (slices 2 and 3 are done)

In the order and with the guardrails in `docs/native-pass.md`. The guardrails
that matter most: no notification, row or toolbar button decides an approval;
no unread or archive state on Needs-you rows; a menu Allow/Deny only while an
armed card is visible (now in the Inbox menu, one action list with the context
menus: `MissionKit/InboxCommands.swift`). Slice 5 settled the notifier change slice 1
made: a notice is keyed per row and kind, so a second approval on a session with
one already waiting sends no new notification, by ruling (see slice 5 in
`docs/native-pass.md`).

### 3. Verification of slice 2

Full UI run on slot 8 with `--foreground`: 134 passed, 7 failed.
`appearance_and_size_matrix` and `changes_say_how_each_file_changed` are known
failures on main. `evolution_tab_reads_the_board_and_core`,
`archive_and_delete_ask_first`, `effort_and_profile_are_changed_on_a_running_session`
and `two_sessions_are_linked_and_unlinked` passed when run alone. The inbox
scenarios, including the one known to fail on main, passed on their own.

### 3a. The two order-dependent press failures

On #1's last full run, two older scenarios failed and each passes alone. On #2's two runs, `evolution_tab_reads_the_board_and_core` failed both times and `generation_speed_is_timed_from_the_stream` passed both:

- `evolution_tab_reads_the_board_and_core`: the press on the "Daemon core" disclosure returns `ok` but nothing opens, after `changes_say_how_each_file_changed` or `a_strand_is_forked_from_a_form`.
- `generation_speed_is_timed_from_the_stream`: `press Context window` returns `ok` but the popover never appears. It passed in a run before the code-mode seed existed; whether the seed matters is not isolated.

Find what the earlier scenarios leave behind that makes an AX press a no-op (a
held focus, an open popover in another window, a disclosure's state cached
across sessions). Slice 1 found one cause of this family: an earlier
scenario's `deactivate` leaves the app without a key window, and SwiftUI then
delivers no focused value to the menu; `app.take_focus()` re-fronts the run's
own app copy. Never loosen the assertions; a scenario that cleans up after
itself is the fix.

### 4. Open parity rows

- AI-06, AI-15, AI-17, AI-31 and AI-41 are `code` with no scenario. AI-17 is sending from the message bar.
- AI-26 stays `code`: "Session state" has an accessibility label that hides the stream-head words, so no scenario can read them.
- AI-33 and AI-44 differ from the web by design: committed work and the working tree arrive merged on the wire, and saved sessions are counted, not listed.

### 5. Carried over from the 2026-11-05 edition, still unanswered

- A friendlier Changes-tab message for "worktree observation exceeded its output budget" (the daemon's `status_byte_limit` in `worktree_diff.gleam`).
- Per-session worktrees with git-cow from the new-agent sheet. Needs a Loom protocol change to `sessions.create`; ask the owner first.
- "Projects popover polish", never specified.

## Rulings already made (do not re-litigate)

- The app changes nothing in the daemon. Anything needing the daemon goes through a Loom PR.
- **Calm and native.** No raw JSON in the UI; at-a-glance figures (model, tokens, speed, cost, context) belong in the composer bar, not behind a click.
- Normal is grey, amber means a decision is waiting, red means failed, green appears only in diffs. No left-edge accent bars or card shadows.
- Diffs are always red removed, green added.
- Agent-written text (a last message, a find, an ask) is labelled untrusted where it is drawn.
- A review's staged items are discarded when another thread opens; the outbox says so.
- An answer form holds after every send until the re-read lands, so one ask is never answered twice.
- **Settled by native-pass slice 2:** the inbox is an `HSplitView` of list (260 to 480 pt) and pane (at least 340 pt), the folder is a toolbar `Picker` at every width, and the rail and its 920 pt breakpoint are gone.
- **Provisional (Loom protocol-change 128):** an Operator member may answer an ask over the control socket, where the web view lets only the owner answer.
- Commit authorship is the repository owner, no AI attribution lines or trailers. Branch and worktree names never include "claude".
- Use absolute paths and `git -C` / `make -C`; a `cd` triggers a permission prompt.

## Hazards (each cost real time)

- **SwiftUI fills its accessibility tree only after the app has been active once.** A copy launched behind another app has about seven unnamed nodes; `no_unnamed_controls` and the pixel matrix still pass on it, and the first scenario that reads text times out, so the run looks healthy and then collapses. The driver activates the app for 600 ms at launch (`9885926`).
- **The UI daemon needs a code-mode seed** or code mode and evolution report unavailable. `dev-cluster.sh` passes `--codemode-seed` from `LOOM_CODEMODE_SEED` or `build/codemode-seed` beside `LOOMD_BIN`.
- **Never let the daemon under test change mid-run.** Building Loom in the worktree `LOOMD_BIN` points into replaces the binaries. Use a frozen worktree (`/Users/roasbeef/loom-drives/desktop-loomd`, built with `make binaries server-shipment codemode-seed`) and rebuild it only between runs.
- **Run the suite in the foreground**, or through the agent tool's background mode; a shell-detached `( … &)` run collapsed at scenario 4.
- **A thread's reads are keyed on its id and kind** (`7f913a2`). Keyed on the id alone, a session promoted from Waiting to To review stayed on "Reading the worktree…".
- **`Menu` has no accessible name on macOS 26.** Use a Button with a popover so the UI tests can find it. Popovers opened from a sheet are child windows of the sheet; `DebugDriver.searchRoots` includes `childWindows` for that reason.
- **Selection works only within one `Text`.** Selection across blocks needs a single `AttributedString` `Text` per prose run (`MarkdownRun` in `Theme.swift`).
- **Large label closures hit "unable to type-check in reasonable time".** Extract subviews.
- **`TraceBoard.fold` runs on the main thread.** Profile with `sample <pid> 5` before adding work there.
- **UI harness conventions.** `see` / `not_see` match the AX name or value; `not_see` has no timeout. Wrap long suites in `caffeinate -di`; on a locked screen scenarios report `blocked`. Use `LOOM_UITEST_SLOT=n` to run beside another suite.

## Where to look

- `docs/architecture.md` and `docs/design.md`: structure and performance figures.
- `docs/testing.md`: the harness, the scripted model's keywords, and the inbox snapshot fields (`drawn`, `open`, `paneWidth`, `folderControl`).
- `docs/parity.md`: the capability table with the scenario that proves each row; the AI- rows are the inbox.
- `tests/ui/scenarios_inbox.py`: the inbox scenarios.
- Loom side: `docs/design-notes/attention-inbox/` (the mockup and fact sheet), `protocol-change/120`, `122`, `125`, `126` and `128`.

## Deliberately open

- Whether the 880 pt layout should instead raise the minimum window width.
- The order-dependent press failures' cause.
- Whether project mode's ticket view comes to the desktop; the web page comes first (Loom #1167), and the desktop ports it later.
