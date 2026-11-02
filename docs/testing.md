# Testing the app

The test tools exist to answer one question: does the app a person runs do what `docs/parity.md` claims? Unit tests cover the pure rules in `Sources/`, and everything else runs against the real app and a real daemon.

## The layers

| Layer | Command | What it proves | Judge |
| --- | --- | --- | --- |
| Pure rules | `make test` | Protocol assembly, projection, markdown, diffs, merge rules | XCTest |
| Scenarios | `make uitest` | Features work end to end against a real cluster | Accessibility tree and app state |
| Foreground | `make uitest-foreground` | Real key equivalents with a key window. Takes focus briefly | App state |
| Parity | `make parity` | No row claims `yes` without a scenario | `tests/ui/parity_check.py` |

## How a scenario sees the app

`tests/ui/loomui.py` talks to `App/Sources/DebugDriver.swift`, which compiles only into debug-flagged builds. Commands go through a file, and each waits on its own reply rather than on a sleep.

| Tool | Use it for |
| --- | --- |
| `app.snap()`, `app.session()` | The app's state as JSON. Prefer this for assertions. |
| `app.see(regex)`, `app.not_see(regex)` | Whether text reached the accessibility tree, which is what a person's screen reader gets. |
| `app.press(label)` | Presses a control by accessibility name, through the action VoiceOver uses. It needs no coordinates and takes no focus. It also finds controls in a popover, and treats a disabled control as absent, so a press waits for it to arm. |
| `app.menu(title)` | Invokes a menu item. Native menus cannot be pressed while tracking, so an action reachable only inside a `Menu` also belongs in the menu bar. |
| `app.focus(label)`, `app.fill(label, text)`, `app.enabled(label)` | Put the caret in a text field of the open sheet by its accessibility name, replace its contents, and read whether a control is enabled. Typing goes to the open sheet, as it does for a person. |
| `app.key(name, mods)`, `app.type(text)` | Real key events. Text goes to the focused field. Shift-modified menu shortcuts cannot be synthesized this way. |
| `app.dispatch`, `app.prompt`, `app.open_session` | Create and drive sessions. |
| `app.shot(path)` | A capture from the window server, with glass composited, which `cacheDisplay` would not show. |
| `app.hitch(seconds)`, `app.stats()` | Frame gaps and CPU. |
| `app.audit()` | Controls with no accessibility name. |
| `cluster.kill(name)` | Fault injection against `orch` or `exec`. |
| `app.snap()["sidebar"]` | The sidebar's rows in every grouping, the saved rows, the machine filter and its counts. The rows are not in the accessibility tree, and the sidebar draws these same values from `SidebarRows`. `app.cmd("select <id>")` selects a row as a click does. |
| `app.cmd("attach <name> <address>")`, `app.cmd("unattach <name>")` | Connect a second daemon without saving it, with the credential in the driver directory's `token` file, and remove it. A scenario that connects through the Connect a Daemon sheet removes the saved daemon with `unattach`. |
| `app.cmd("run <command> <json>")` | Sends one session command from the open session, for set-up a scenario does not itself test. |

The scripted model in `scripts/fake_provider.py` chooses its reply from keywords in the prompt: `demo`, `escalate`, `long`, `slow`, `hang`, `explode`, and for the tools a panel shows `todoboard`, `writenote`, `proposerule`, `heartbeat`, `backgroundjob` and `commitwork`. It reports token usage, and the cluster prices the model, so a session has an estimated cost. The advisor is routed to the same model, and it ignores these keywords.

The cluster has an orchestrator `orch`, an executor `box` with a pool `boxes`, a plain repository `proj`, and a second repository with a linked worktree for the rows that name one. It has a single orchestrator. Linking a second one needs a membership ledger, which a static deployment does not have, so the rows that need two stay at `code`. Scenarios that kill the executor run last, and `tests/ui/scenarios_down.py` holds them.

## Adding a scenario

Add a function to `tests/ui/scenarios.py`, and name the parity rows it proves.

```python
@scenario("GO-03", "GO-04")
def goal_pauses_and_resumes(c):
    """Pause stops a goal's spending, and Resume continues it."""
    sid = c.app.dispatch("Goal check", WORKSPACE)
    c.app.open_session("Goal check")
    c.app.press("Pause Goal")
    c.app.see("Paused")
```

Then change the row in `docs/parity.md` to `yes`. Every scenario starts with all daemon slots free. Assert what a person would see, and wait with `wait_for` or `see`, never with a bare `sleep` before an assertion.

## Running several at once

`LOOM_UITEST_SLOT=n` offsets every port, path and node name, so independent runs share nothing. `tests/ui/run.py --only text` filters by scenario name or parity id, and `--seed n` reproduces a random walk.

## Visual baselines

`appearance_and_size_matrix` runs first, on a fresh daemon with fixed content, and compares three screens in both appearances at two sizes against `tests/ui/baselines/`. Differences appear as images in `build/uitest/diffs/`. After a deliberate change, run `make uitest-update` and review the changed baselines in the diff.

## What the tools cannot do

- The sidebar's rows are not in the accessibility tree, so a scenario cannot press a row, a project heading or a row's context menu. Each row action is also in the Session menu, which acts on the session in the window, and scenarios use that.
- A pop-up menu opens as its own tracking menu, which neither the tree nor `press` can reach. A choice among a few options is drawn as segments, which `press` can select.
- A locked screen composites nothing: captures come back blank, frames stop, and the inspector's column is not laid out, so its tabs never reach the accessibility tree. Scenarios marked `needs_display` report `blocked` on a locked screen, and a run with any blocked scenario does not exit zero.
- Windows are captured without being frontmost, so controls render in their inactive state. `LOOM_FORCE_ACTIVE=1` approximates active controls. Only `open -b com.roasbeef.loom-desktop` gives the true state, and that takes focus.
- A scripted model cannot show how a real model behaves over a long session.
- The checks read the accessibility tree in process, which is not the same as listening to VoiceOver.
