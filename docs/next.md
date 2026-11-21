Baseline: 8ce2692 on inbox/answer-asks (2026-11-21)

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
- `the_inbox_groups_threads_by_need_and_the_rail_narrows_them` is red for a real reason, not a flake: it asserts the headline starts "3 need you", but with this branch earlier scenarios' saved sessions are counted from the catalogue ("7 need you ... 119 saved from the catalogue"). The assertion needs to separate the live rows from the saved count; it was not edited here because the rule is to report an assertion that seems wrong. It passes on a fresh daemon with no saved sessions.
- `generation_speed_is_timed_from_the_stream` passed in both full runs.
- README screenshots retaken at 1400 by 900 (`tests/ui/readme_shots.py`), plus `inbox.png` and `answer.png`.

## What to do next

Ordered.

### 1. The two order-dependent press failures

On #1's last full run, two older scenarios failed and each passes alone. On #2's two runs, `evolution_tab_reads_the_board_and_core` failed both times and `generation_speed_is_timed_from_the_stream` passed both:

- `evolution_tab_reads_the_board_and_core`: the press on the "Daemon core" disclosure returns `ok` but nothing opens, after `changes_say_how_each_file_changed` or `a_strand_is_forked_from_a_form`.
- `generation_speed_is_timed_from_the_stream`: `press Context window` returns `ok` but the popover never appears. It passed in a run before the code-mode seed existed; whether the seed matters is not isolated.

Find what the earlier scenarios leave behind that makes an AX press a no-op (a
held focus, an open popover in another window, a disclosure's state cached
across sessions). Never loosen the assertions; a scenario that cleans up after
itself is the fix.

### 2. The Mac-native refinement pass

The owner's ask (2026-11-21): once the port is at parity, do a pass so the app
does not just copy the web UI but uses patterns suited to SwiftUI and the Mac,
so it captures the web view's intent rather than reading as a port. Method:

1. A mini council of Sonnet 5.5 critics reviews the running app from
   screenshots and the code, each seat with one lens: Mac interface guidelines
   and platform habits; SwiftUI structure and state; what the web view gets
   right in spirit and must keep.
2. A written proposal of which Mac patterns replace which web shapes.
   Candidates to weigh, not decisions: a real three-column
   `NavigationSplitView` with native column collapse instead of the
   hand-sized folder rail, toolbar items and menu-bar commands with keyboard
   shortcuts for every inbox action, an inspector for the reading pane's
   evidence, system notifications for an ask or approval, a Dock badge for
   "needs you", Quick Look for files in the review thread, and native
   context menus on rows.
3. Slices, each with before and after captures and its scenarios, like the web
   mockup-fidelity pass.

### 3. Open parity rows

- AI-06, AI-15, AI-17 and AI-31 are `code` with no scenario. AI-17 is sending from the message bar.
- AI-26 stays `code`: "Session state" has an accessibility label that hides the stream-head words, so no scenario can read them.
- AI-33 and AI-44 differ from the web by design: committed work and the working tree arrive merged on the wire, and saved sessions are counted, not listed.

### 4. Carried over from the 2026-11-05 edition, still unanswered

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
- **Provisional (2026-11-21, commit `55ff39c`):** below 920 pt of inbox width the folder rail is replaced by a toolbar "Folder" menu, and the reading pane keeps at least 340 pt. A wider pane at 880 would squeeze the list below its floor. Revisit in the Mac-native pass.
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
