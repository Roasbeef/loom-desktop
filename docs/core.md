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
| `Readers` | `LoomCore/Readers.swift` | which background reads are due, within the daemon's budgets | `LoomShell/ReadHost`; the thread pane, the update cards, the rail, an ask's record, the jobs tab and the side question hold surfaces there |
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
| `SessionModel` | lost reply after apply, duplicate push, reordered pushes, disconnect (inside a transfer too), a lost request, attaching as an observer |
| `DaemonModel` | lost reply, socket closed mid-poll, daemon restart (new epoch), a lane ending, a refused poll, the daemon down, a replaced controller reporting its end late |
| `DispatchModel` | create reply lost, create refused, open fails, first prompt refused or lost, worktree ignored |
| `AppCoreModel` | session vanishes, feed row gone, app restart from persisted digests, reply changes |
| `ReadersModel` | read fails, slow read |
| `DispatchFormModel` | create reply lost, worktree ignored, first prompt lost, create refused |

## Rules

The lane's tags are Loom's own, from `session_channel_property_test.gleam`: I1 to I8, L1 to L5 and N1.
The rest are this app's:

- T1 to T7: the transcript only grows, a stream is handed to its reserved entry, a token changes nothing a
  view reads, one stream write per flush window, an identical cut changes nothing, and the held stream equals
  what the daemon streamed when no fault lost a fragment (T7).
- X1 to X4: a block appears once, nothing is still drawn as live once every turn has settled (X2), an approval
  appears once and only if the daemon raised it (X3), and none stays drawn as pending after it was decided (X4).
- O1 to O5: a sent message is in exactly one place, one write per message, an answer to an approval carries
  the sequence of a record the session held when it was given (O3), one key names one request, an observer
  sends no mutation (O5).
- B1 to B7: the Dock label equals the board's (B1), the board equals the rule over the facts (B2), the open
  thread (B3), the place shown is a listed session or the core moved it and said why (B4), the project
  selection names a project the core holds (B5), lanes per epoch (B6), unseen marks (B7). F1: a resident session
  goes at most three polls with no attention read covering it.
- N2 (a notice once), P1 and P2 (persisted values decode; nothing but reply digests is persisted), H2 and H6
  (first prompt, owner before background), R0 to R3, R5 and R6 (reads; a surface that becomes shown is read at
  once unless it settles first, and never before its settle time), and liveness after the heal.

Each is a named check in the model's file, with the reason it holds.

One excuse is counted and not failed: a stream replaced by a newer generation on its strand before its
entry is held. Loom replaces it too, so this is a policy question, tracked in the PR that introduced it.

## The fake daemon streams what the real one does

`FakeDaemon` streams thinking, text and tool-call fragments with the real field set (`strand`, `op`,
`generation`, `ephemeral`, `kind`, and `call_id`, `tool_name` and `arguments_fragment` for a tool call), splits
realistic text (markdown with code fences, CJK, ZWJ emoji, combining accents, long replies) at scalar
boundaries, runs several strands at once, and ends a turn four ways: its entry lands, it is aborted, it fails
with an entry, or it fails with none. It raises approvals mid-turn, writes the operation-keyed result
(`fact.custom/operation-result/{op}`) beside `strand.last_result`, decides approvals by sequence, and sends
`oldest_seq` as the real daemon does (null on every catch-up cut and on a recent window with no entry).

Three sources keep the fake honest. `make record LOOMD_BIN=<loomd>` records real sessions against a daemon it
starts itself, with its own state directory and port (17741, never 7440 or `~/.loom`) and the scripted model
`scripts/fake_provider.py`, so it needs no provider key. The recorded traces (`Tests/LoomCoreTests/Traces`: a
plain reply, reasoning, tool calls, an aborted turn, a failed turn, an approval, two prompts) are replayed through the
production lane and conversation by `TraceReplayTests`, clean and under each push fault, and the clean replay is
the reference. `make conformance LOOM_CHECKOUT=<loom checkout>` runs the same frames through Loom's own
`session_view` in a scratch Gleam project and writes what it draws; a Swift test requires the core to say the
same things in the same order. The two agree on all seven traces. `make contract LOOMD_BIN=<loomd>` runs the
shell's real sockets against a real daemon.

## The hosts are tested too

The simulation drives the core values. The shell that carries them out has its own tests, which run the
real `DaemonHost` and `ReadHost` over a `HostClock` that a test replaces with a virtual clock, and `DaemonHost`
over a fake control socket backed by the simulated control daemon (`DaemonHostTests`, `ReadHostTests`,
`HostTestSupport`). They cover what a core simulation cannot see: holders and tasks, parked callers, the timer,
a call after `stop`, a refresh that must wait for a poll that starts after the change, and a late report about
an old lane. The app's own hosts are tested in `Tests/LoomAppTests`, over the executable target:
`SessionController` (a closed lane is always reported to the daemon core) and `DaemonConnection` (a refused
stop leaves the lane attached). Two UI scenarios found bugs the simulation could not see, because both were in
what the app host reports to the core and not in what the core decides; each now has a test at that seam.

## Commands

```sh
make test                                    # unit tests and a short run of every simulation
make sim SIM_RUNS=50000 SIM_SEED=7           # a long, reproducible campaign
make sim-replay MODEL=SessionModelTests SEED=<hex>   # one seed, step by step
SIM_BENCH=1 swift test --filter SimBenchTests         # schedules per second
make coverage                                # line coverage of the core under the simulations alone
make recall WT=<scratch worktree>            # blind recall; see scripts/recall.sh
make record LOOMD_BIN=<loomd>                # record traces from a real loomd (own state dir and port)
make conformance LOOM_CHECKOUT=<loom>        # regenerate Loom's projection of the traces
make contract LOOMD_BIN=<loomd>              # the shell's real sockets against a real loomd
scripts/cross-process.sh                     # the same seeds in two processes with different hash seeds
make sim-nightly WT=<scratch worktree>       # long campaign, cross-process run and recall, for a schedule
```

## Blind recall

`scripts/recall/*.patch` each reintroduce one fixed bug into the production core. `scripts/recall.sh`
applies one in a scratch worktree and runs the generic swarm from generator seed 1, then 2, and prints
the run at which it failed. Nothing in the harness is specific to a patch. A miss is a harness gap, and a
change that makes the harness miss a patch is a regression.

## Known gaps

- `AppCore`'s inputs are gathered from observed models, so a change is reported one main-actor turn later,
  as the old observation reported it. Feeding each input to the core where it changes would touch every
  setter of `AppModel`'s observed properties (the catalogue, the feed rows, the reviews, the project boards,
  the machines, the sessions' replies) and would make the core's input order depend on view code. The core's
  own rules do not depend on the delay (B2 recomputes the board from the facts it holds), and the UI scenarios
  read the surfaces after the turn.
- `SessionController.inherit` drops images in flight.
- Layout, focus, the accessibility tree, real WebSocket framing and the real daemon are not simulated beyond
  the recorded traces and the opt-in contract test.
- The recorded traces do not reproduce a turn that fails before its entry lands (the scripted failing model
  writes the failure as an entry), so the failed-turn stream rule rests on the simulation and its unit tests.
- A message sent before the first cut says who the session talks to can be written by an observer's lane
  until that cut arrives; the lane refuses the named mutations from then on, and the daemon refuses by code
  before it. Nothing earlier can know the role.

## What the widened simulation found

By itself, with no reading of the code to point it there: a stream whose turn failed before its entry landed
stayed drawn (X2, fixed from the daemon's operation-keyed result), and a fake daemon that sent `oldest_seq` as
the real one does made a lost message impossible to settle (liveness, fixed by reading a null `oldest_seq` on
an empty recent window as the protocol defines it). Writing the rules B4 and B1 to B5 found that the core never
moved the window off a session no daemon lists. Reading found, in the same round: a lane closed by the app was
never reported to the core (`older_turns_page_in`), the attention feed waited a whole period for a new session
(`appearance_and_size_matrix`), a refused stop left a running session without its lane, a refused card message
was shown nowhere, and the thread pane's settle and worktree read bypassed the scheduler.
