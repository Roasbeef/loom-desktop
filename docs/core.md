# The pure core and its simulation

`Sources/LoomCore` holds the decisions of the app as values that decide and never act. A host
feeds a value an event and a clock reading, and performs the effects the value returns. The
simulation in `Tests/LoomCoreTests` runs those same values against a simulated world, from a
seed, and checks rules after every step. Loom's own pure state machines are the model:
`session_view/session_channel.gleam`, `step.gleam`, `stream_identity.gleam` and
`project/engine.gleam`.

## The seam

| Value | File | Decides | Host |
| --- | --- | --- | --- |
| `Lane` | `LoomCore/Lane.swift` | one session socket: stop-and-wait credit, transfers, deadlines, the idle refresh, what a lost reply means | `Session` |
| `Session` | `LoomCore/Session.swift` | a lane plus its conversation, the sent drafts, the stream flush; what a view is shown when | `SessionController` |
| `ControlLane` | `LoomKit/ControlLane.swift` | the control socket: `hello`, one command at a time, owner commands before background reads | `ControlClient` |
| `Daemon` | `LoomCore/Daemon.swift` | the poll saga, the catalogue, epochs, which sessions need a lane, the periodic reads, the reconnect | `LoomShell/DaemonHost`, beneath `DaemonConnection` and the app's `ControlClient` |
| `Dispatch` | `LoomCore/Dispatch.swift` | create, open, attach, first prompt | `DaemonConnection.dispatch` |
| `AppCore` | `LoomCore/AppCore.swift` | the board, the open thread, the folder, the project selection, notices, what is persisted | `AppModel` |
| `Readers` | `LoomCore/Readers.swift` | which background reads are due, within the daemon's budgets | `App/ReadHost`; the thread pane, the update cards, the rail, an ask's record, the jobs tab and the side question hold surfaces there |
| `DispatchForm` | `LoomCore/DispatchForm.swift` | the new-session form's rules and its idempotency key | `DispatchSheet` |

A core value has no `async`, no clock, no timer and no OS call. `scripts/core-purity.sh` fails
`make test` if anything under `Sources/LoomCore` (and `LoomKit/ControlLane.swift`) names one, as
Loom's lint R6 does for its portable packages. Every type is `Equatable`, so a snapshot compares
with `==`. Sockets, timers, the keychain, preferences and the file system live in the shell, which
only forwards frames as events and carries effects out in order, with one timer armed for the
core's `nextDue`.

Timing follows Loom's lane, not the earlier Swift one: a command has 10 s and a capture 30 s
(`session_channel` and client protocol section 4.3), and the idle refresh is 250 ms until the
daemon has pushed a frame to the lane and 5 s after (section 8, "Timeouts").

## What runs for real and what is simulated

| Component | In a simulation |
| --- | --- |
| `Lane`, `Session`, `Conversation`, `TransferAssembler`, `DraftLedger`, `ControlLane`, `Daemon`, `Dispatch`, `AppCore`, `Readers`, `DispatchForm`, `InboxRule`, `Notices` | production, unchanged |
| a socket | a FIFO of frames with faults at both ends |
| the daemon | `FakeDaemon` (session half), `FakeControl` (control half), strict where the real one is |
| the clock | virtual: moves only on a generated tick or a jump to `nextDue` |
| the shell | the harness's `Host`, which performs effects as the app does and keeps what a view would observe |
| the disk, the keychain, preferences | judgements and stores the schedule controls |

## Seeds, phases and faults

A seed is a mode byte, a 16-bit fault mask and ops. `op % 16` selects a kind and `op / 16` is its
argument. An op whose fault class is off performs an honest action, so every seed makes progress.
The order seed, which breaks ties, is a hash of the op bytes. A run has four phases:

1. **Setup.** The production values are built, the daemon holds its start state.
2. **Scripted.** One op per step; the invariants run after each.
3. **Heal.** Faults off, the world finishes its work, time moves by `nextDue`. The heal never
   reconnects or resets anything production would not reconnect or reset for itself: the session
   host reattaches by the app's own rule, three seconds after the lane ends.
4. **Settle and snapshot.** Quiescence is checked and the final state is snapshotted.

Every corpus seed runs twice and the snapshots are compared. A failing seed is shrunk by deleting ops
and clearing fault bits while the same rule keeps failing.

| Model | Faults (one bit each) |
| --- | --- |
| `LaneModel` | refuse, stale reply, garbage, disconnect, close, old notice |
| `SessionModel` | lost reply after apply, duplicate push, reordered pushes, disconnect (inside a transfer too) |
| `DaemonModel` | lost reply, socket closed mid-poll, daemon restart (new epoch), a lane ending |
| `DispatchModel` | create reply lost, create refused, open fails, first prompt refused or lost, worktree ignored |
| `AppCoreModel` | session vanishes, feed row gone, app restart from persisted digests, reply changes |
| `ReadersModel` | read fails, slow read, command unknown, epoch change |
| `DispatchFormModel` | create reply lost, worktree ignored, first prompt lost, create refused |

## Rules

The lane's tags are Loom's own, from `session_channel_property_test.gleam`: I1 to I8, L1 to L5 and N1.
The rest are this app's: T1 to T6 (transcript only grows, a stream is handed to its reserved entry,
a token changes nothing a view reads, one stream write per flush window, an identical cut changes
nothing), O1, O2 and O4 (a sent message is in exactly one place, one write per message, one key names one
request; O3 and O5, about approvals and observers, are not checked yet), B2, B3, B6 and B7 (board, open
thread, lanes per epoch, unseen marks; B1, B4 and B5 are not checked yet), N2 (a notice once), P1 and P2 (persisted values decode; nothing but reply digests is
persisted), H2 and H6 (first prompt, owner before background), R0 to R4 (reads), and liveness
after the heal. Each is a named check in the model's file, with the reason it holds.

One excuse is counted and not failed: a stream replaced by a newer generation on its strand before its
entry is held. Loom replaces it too, so this is a policy question, tracked in the PR that introduced it.

## Commands

```sh
make test                                    # unit tests and a short run of every simulation
make sim SIM_RUNS=50000 SIM_SEED=7           # a long, reproducible campaign
make sim-replay MODEL=SessionModelTests SEED=<hex>   # one seed, step by step
SIM_BENCH=1 swift test --filter SimBenchTests         # schedules per second
make coverage                                # line coverage of the core under the simulations alone
make recall WT=<scratch worktree>            # blind recall; see scripts/recall.sh
```

## Blind recall

`scripts/recall/*.patch` each reintroduce one fixed bug into the production core. `scripts/recall.sh`
applies one in a scratch worktree and runs the generic swarm from generator seed 1, then 2, and prints
the run at which it failed. Nothing in the harness is specific to a patch. A miss is a harness gap, and a
change that makes the harness miss a patch is a regression.

## Known gaps

- `ControlLaneExchange` (a client that owns its own control socket, used by `loom-probe` and the tests) still exists beside
  `DaemonHost`; the app uses only the host. The thread reader's first-read settle delay and the worktree read, which is
  made once, are not scheduled by `Readers`.
- `AppCore`'s inputs are gathered from observed models, so a change is reported one main-actor turn later,
  as the old observation reported it.
- `SessionController.inherit` drops images in flight.
- A stream whose turn is interrupted or fails before its entry is published stays drawn until the strand's next
  generation. Loom also stops waiting when the operation is over, but a cut's metadata can be older than a push
  that reached the client first, so an idle strand in a cut is not proof that the entry will never land.
- The lost-message settlement needs the window's `oldest_seq`; a daemon that omits it leaves a lost message unknown.
- Layout, focus, the accessibility tree, real WebSocket framing and the real daemon are not simulated.
