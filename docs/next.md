Baseline: dc8f6ef on perf/transcript-scroll (2026-11-05)

# Next: Loom Desktop handoff

Loom Desktop is the native SwiftUI client of `loomd` (the Gleam daemon in
`Roasbeef/loom`). It speaks the existing protocol and changes nothing in the
daemon. This file says where the tree is, what to do next, what was decided,
and what is left open. Where it disagrees with the code, measure before
believing it.

## Where the tree is

### Checkouts and branches

| Path | Branch | What it is |
| --- | --- | --- |
| `/Users/roasbeef/gocode/src/github.com/roasbeef/loom-desktop` | `parity/integration` | The user's main checkout. They run `build/Loom.app` from here and do the merges themselves. It is fast-forwarded to `3779309`; `perf/transcript-scroll` is 13 commits ahead of that. |
| `/Users/roasbeef/gocode/src/github.com/roasbeef/ld-perf` | `perf/transcript-scroll` | The worktree all recent work is in. HEAD is `dc8f6ef`. Nothing here is pushed. |

Both are on the same repository (`Roasbeef/loom-desktop`, public). To get the
latest into the user's app, the user runs:

```bash
git -C /Users/roasbeef/gocode/src/github.com/roasbeef/loom-desktop merge --ff-only perf/transcript-scroll
make -C /Users/roasbeef/gocode/src/github.com/roasbeef/loom-desktop run
```

Do not merge or push for them unless they say so. If the fast-forward is
refused, `parity/integration` has moved: say so and ask.

### Commits on `perf/transcript-scroll` up to and including `3779309` (all committed, none pushed)

Each is one user request. Oldest first.

| Commit | What it does |
| --- | --- |
| `3779309` | Every strand card and "Started" row names its model. |
| `47487f9` | The new-agent sheet lists recent project folders in a "Projects" popover. |
| `62ca9d6` | The proposal card above the composer opens to the whole change. |
| `fb3e9b2` | A config reload or profile switch keeps the page and state through the session reopen. |
| `eb2ff33` | The composer bar shows model, tokens, speed and cost again. |
| `3dcee1d` | A closed step line names a `code_mode` program and its call count. |
| `a1311d3` | Shift-Return and Option-Return add a line to the draft. |
| `17736cb` | The trace fold reads only the newest programs (CPU hot path, see below). |
| `9fb2244` | Anchored `fs_edit` hunks draw as red and green diffs; a finished turn's steps ease closed. |
| `06a6889` | A selection can cross paragraphs of a reply. |
| `100e1c5` | The toolbar's agent name is centred. |
| `fd986dc` | An `agent_note` opens to its key and value as native fields. |
| `d7cb413` | Consecutive identical failures collapse to one row with "×N" and "over <duration>". |
| `dc8f6ef` | The context figure never vanishes from the bar: `ctx —` until a reading loads. |

### Verification state, honestly

- Unit tests: 179 pass (`swift test`) as of `d7cb413`. Not re-run after `dc8f6ef`, which only touched two view files; `swift build` is clean.
- UI suite: the last full run (before `dc8f6ef`) was 121 passed, 3 failed. `older_turns_page_in` and `idle_is_quiet` pass when run alone on the new build, so they are load-related. `evolution_tab_reads_the_board_and_core` is a known timing flake. The suite has not been run after `dc8f6ef`.
- Not seen drawn in the running app: the repeated-failure row (no scenario; offline there is no way to force repeated 429s), the `ctx —` fallback, and a real mouse drag-selection across paragraphs.
- Not re-measured: CPU after the `TraceBoard.fold` fix. Measuring needs the user's rebuilt app (the profile was taken with `sample` on the user's own `loom-desktop/build/Loom.app`).
- Not verified end to end: the Vision model choice in the new-agent sheet (`3aed58a`, `9179cec`). It needs Loom PRs #1181 and #1183 merged and `loomd` rebuilt. Both are open.

## What to do next

Ordered. Items 1 and 2 are small and finish what is in flight. Items 3 to 5
are the offered follow-ups the user has not yet answered; do not start them
without their word.

### 1. Run the suite on `dc8f6ef` and fix what is yours

```bash
cd /Users/roasbeef/gocode/src/github.com/roasbeef/ld-perf
swift test
CONFIG=release SWIFT_FLAGS="-Xswiftc -DDEBUG" scripts/bundle.sh
caffeinate -di python3 tests/ui/run.py
```

(`make uitest` does the build and run in one go.) Done when `swift test` exits 0
and the suite's failures are only the known flakes, each of which passes on
`--only <name>`. Do not rebuild while a suite is running; the suite launches the
bundle that the build overwrites.

### 2. Add UI scenarios for the three things never seen drawn

- **`ctx —`.** A scenario that opens a session before any context read has landed (or with the read failing) and asserts `see("Context window")` with value `ctx —`. `ContextFigure` is `App/Sources/ContextFigure.swift`; its AX label is "Context window".
- **Repeated failure row.** Add a fake-provider scenario in `scripts/fake_provider.py` that returns the same error several times, and assert the row's "×N". The grouping itself is unit-tested (`testRepeatedFailuresAreOneRowThatCountsThem`, `Tests/LoomKitTests/MarkupTests.swift`).
- **Cross-paragraph selection.** The driver injects actions and cannot drag. This is the one that wants real input. See "Computer use" below.

A scenario tag such as `TR-40` must exist in `docs/parity.md`; otherwise use an
untagged `@scenario()`. `python3 tests/ui/parity_check.py` fails the gate if
`docs/parity.md` claims a capability no scenario covers.

### 3. Friendlier text for the Changes-tab error (offered, unanswered)

The user saw "worktree observation exceeded its output budget". It comes from
the daemon, not the app: `worktree_diff.gleam` caps `git status` at
`status_byte_limit` 262,144 bytes (the board is limited to 24 files and 40,960
bytes). It fires on a very large untracked tree. The offer is to word it in
plain language in the Changes tab and say what to do (ignore or commit the
large directory). App-only change; the error text arrives through the
`worktree_diff` snapshot (`Conversation.worktree`).

### 4. Per-session worktrees with git-cow (offered, unanswered; needs the user's go)

The user asked for a checkbox in the new-agent sheet to open a worktree with a
given name using git-cow. Today:

- Worktree mode is configured per workspace in `loom.toml` (`mode = "worktree"`), not per session. `sessions.create` has no worktree option.
- The daemon does a plain `git worktree add`, not `git cow`.

So the work is in two repositories:

1. **Loom (daemon).** A protocol change (`protocol-change/NNN.md` in `Roasbeef/loom`, the only way to change a frozen interface) adding an optional worktree request to `sessions.create`, plus a daemon change that creates it, using `git cow add` when available and `git worktree add` otherwise. The user's convention is to dispatch Sonnet 5.5 workers and have a Fable-tier review before merge.
2. **loom-desktop.** A checkbox and name field in `App/Sources/NewSessionSheet.swift`, sent when the daemon advertises the capability.

Do not open the Loom PRs or start the sub-agent without the user's go. Loom
PRs target `main`, and merges are the user's by default.

### 5. Projects popover polish (offered, unanswered)

The "Projects" Button in `NewSessionSheet.swift` opens a popover of recent
folders (AX "Project <path>"). Polish was offered, not specified; ask what they
want before changing it.

### 6. Open parity rows

`docs/parity.md` lists 292 web-UI capabilities. The README counts (from
`python3 tests/ui/parity_check.py`) were 218 `yes`, 37 `code`, 16 `partial`, 21
`no`; they are stale after the recent commits, so rerun the script and update the
README table. The `code` rows (implemented, no scenario) are the cheapest gains.

## What to hand off, and to whom

- **To the user, now:** the merge and `make run` commands above, and the note that Vision needs Loom PRs #1181 and #1183 merged and `loomd` rebuilt.
- **Ask the user first:** items 3, 4 and 5; anything that pushes, merges, or opens a PR in either repository.
- **To a sub-agent (only if they say so):** the Loom half of item 4. Brief it with the files (`packages/` for `sessions.create` and the worktree code, `worktree_diff.gleam`, `docs/configuration.md`, `protocol-change/001.md` and `006.md` as format), the done-when (a merged-ready PR passing `make check` in its own worktree), and that it must stop and report rather than merge. One builder per worktree; give it a task-unique scratch file name.

## Rulings already made (do not re-litigate)

- The app changes nothing in the daemon. Anything needing the daemon goes through a Loom PR.
- **Calm and native.** No raw JSON in the UI (hence native `agent_note` fields); at-a-glance figures (model, tokens, speed, cost, context) belong in the composer bar, not behind a click. The user reversed an earlier declutter for exactly these.
- Normal is grey, amber means a decision is waiting, red means failed, green appears only in diffs. No left-edge accent bars or card shadows.
- Diffs are always red removed, green added.
- A new agent's model choice comes from the daemon's configuration (`9179cec`), not a hard-coded list.
- Live-step insertion in the transcript is deliberately not animated; only a finished turn's fold eases closed.
- Commit authorship is the repository owner, no AI attribution lines or trailers. Branch and worktree names never include "claude".
- Use absolute paths and `git -C` / `make -C`; a `cd` triggers a permission prompt.

## Hazards (each cost real time)

- **`Menu` has no accessible name on macOS 26.** Use a Button with a popover so the UI tests can find it. Popovers opened from a sheet are child windows of the sheet; `DebugDriver.searchRoots` includes `childWindows` for that reason.
- **Selection works only within one `Text`.** Selection across blocks needed a single `AttributedString` `Text` per prose run (`MarkdownRun`, `proseLimit = 8`, in `Theme.swift`).
- **Large label closures hit "unable to type-check in reasonable time".** Extract subviews.
- **A lazy transcript stack with long replies is split a row per run (`splitAbove = 6`)** or scrolling stalls.
- **`TraceBoard.fold` runs on the main thread** through `syncAll → conversation.traceBoard`. It folds only the newest 12 programs and bounds clip input (`maxCharacters * 25`). Before adding work there, profile with `sample <pid> 5` first.
- **UI harness conventions.** `see` / `not_see` match the AX name or value; a Button's AX is its label with its value; combined static text reads "name, value"; `not_see` has no timeout parameter. DebugDriver key modifiers are "cmd", "shift", "opt", "ctrl". Wrap long suites in `caffeinate -di`; on a locked screen 22 scenarios report `blocked`.
- **`SessionController.inherit(from:)`** carries view state across a lane reattach, and `SessionScreen.isReopening` holds the page for 10 s while the session is not resident. Changes to reopen behaviour must keep both.
- **Do not rebuild while a suite is running**, and do not rebuild the user's own checkout to measure; they run `make run` themselves.

## Where to look

- `docs/architecture.md` (507 lines) and `docs/design.md`: structure and performance figures.
- `docs/testing.md`: the harness. `Tests/ui/loomui.py` is the Python client for `DebugDriver` (`App/Sources/DebugDriver.swift`); scenarios are in `Tests/ui/scenarios*.py`; `scripts/fake_provider.py` is the scripted model backend (scenario `agentnote` and others).
- `docs/parity.md`: the capability table, row by row, with the scenario that proves each.
- The previous long conversation's transcript, if needed for exact snippets: `/Users/roasbeef/.claude/projects/-Users-roasbeef-gocode-src-github-com-roasbeef-loom--claude-worktrees-swiftui-loom-native-640262/821fc93e-4f7c-4c1f-a189-60ef89dfdc9a.jsonl`.

## Computer use (brainstorm, not a commitment)

The user asked whether an agent could drive the app like a person. The record
so far: the AX-driven suite is fast and unattended but cannot drag, hover or
scroll with real physics; computer use (`mcp__computer-use__*`) can, but needs
screen access, a free display, and is slow. IDEs such as Xcode are click-only
tier, which does not matter since `scripts/bundle.sh` builds from the shell. The
useful trial is one real drag-select across two paragraphs in a built app, to
settle whether `06a6889` works. Nothing was built for this.

## Deliberately open

- Whether per-session worktrees are worth a Loom protocol change (item 4).
- What "Projects popover polish" means.
- Whether the repeated-failure row reads well; it has not been seen.
- CPU after the fold fix, unmeasured.
- Vision model selection, unverifiable until Loom #1181 and #1183 merge.
