# Loom Desktop: design

Loom Desktop is a native macOS client for `loomd`. It adds no agent logic. The
daemon stays exactly as it is, and this app is one more client of the same v2
WebSocket protocol the terminal speaks.

The app answers two questions: what is one agent doing, and what across all my
agents needs me now.

## How it reaches the daemon

The app discovers a daemon the way the terminal does. It reads `daemon.endpoint`
and `owner.token` under `~/.loom`, then proves the daemon is alive with the
authenticated `hello` on `/v2/control`. A bearer is only ever sent to a loopback
address.

| Connection | Used for | How it updates |
|---|---|---|
| `/v2/control` | The catalogue, capacity, activity, create, open and stop | Polled every 2 s, because this socket pushes nothing after `hello` |
| `/v2/sessions/<id>/ws` | One conversation | Pushes for streaming, plus `catch_up` after a notice and at least every second |
| Substrate `GET /api/v1/command/feed` | The fleet of Substrate agents | Reloaded when the `/ws` hub announces a change, and every 15 s as a repair |

A session gets a socket only when a person opens it, or when its activity reports
a pending approval, since that count does not include the record the inbox must
show. Listing never opens a saved session. Resuming one claims a daemon slot, so
it is an explicit button.

## Why the code is laid out this way

| Target | Holds | Depends on |
|---|---|---|
| `LoomKit` | Wire, transfer assembly, the session lane, the `Conversation` projection | Foundation |
| `SubstrateKit` | The feed, replies, plan decisions, the hub listener | Foundation |
| `MissionKit` | The merged attention list and agent cards | Both kits |
| `App/Sources` | SwiftUI views and the object that owns sockets and timers | All three |

The split follows the rule the Loom tree already uses: an engine that decides and
a host that acts. `TransferAssembler`, `Conversation` and `Mission` are pure
values, so their rules are tested from captured frames with no socket. No shared
code with the Gleam `session_view` is possible, so the protocol is the contract.

The kits avoid AppKit, so an iOS client can reuse them later. That client needs a
TLS route to the daemon, which binds loopback only and terminates no TLS.

## Packaging

**Recommendation: a Developer ID signed, notarized app outside the Mac App Store,
built by SwiftPM and `scripts/bundle.sh`.**

- The Mac App Store is ruled out. Its sandbox forbids reading `~/.loom/owner.token`
  and starting `loomd`.
- There is no Xcode project to maintain. `swift build` and a short script produce
  the bundle, and the same path works in CI. Xcode is still needed for its
  toolchain and for simulator work on a future iOS target.
- Updates would come through Sparkle, which is not yet integrated.

Two stages, in order:

1. **Client only, as today.** The app attaches to a `loomd` installed by
   `make install` or the release tarball. This is what exists now. Starting a
   daemon from the app is not built. The terminal's launch ladder (lock, paused
   child, identity record) is intricate, so the app should run `loom` to perform
   it rather than reimplement it.
2. **Bundled daemon.** Put the self-contained release (`make release`, which
   carries ERTS and the helper) under `Contents/Resources`, and register it with
   `SMAppService` as a login agent. Each nested binary must then be signed for
   notarization, and the BEAM's JIT will need the
   `com.apple.security.cs.allow-jit` entitlement under the hardened runtime. This
   stage has not been tried, so that cost is an estimate.

## The interface

References, and what each contributed:

| Reference | Taken |
|---|---|
| Claude Code desktop | Session sidebar, a transcript with collapsed tool rows, a side pane for review |
| Codex app | Project grouping in the sidebar, a review pane over the worktree diff |
| herdr | Blocked, working and done as the only states worth a glance. It is a terminal multiplexer, with no desktop app to borrow from |
| Plannotator Inbox | Threads grouped by what they need, one place to answer, nothing sent until you send |
| Substrate Command Center | Agent dossier cards, the heartbeat trace, a needs-you tray, a steer box on each card |

Rules the views follow:

- Colour means state. Orange is waiting on you, green is running, red is failed,
  and everything else is neutral.
- Motion means work. Only a working agent's trace animates.
- Surfaces are a tinted fill and a hairline border, with no accent bars and no
  shadows. Diffs are full red and green.
- A healthy fleet takes little space. Items needing a person come first.

Three screens:

- **Inbox** merges Loom approvals and failed runs with Substrate questions, plans
  and blocked agents, grouped by what each needs.
- **Mission Control** shows fleet counts, daemon slot use and one card per agent.
  A Loom session and a Substrate agent use the same card.
- **Session** shows the transcript, live streaming, approvals above the composer,
  steer and stop while busy, and the worktree diff in an inspector.

The approval card follows protocol section 5.10. The tool is always named, the
requested authority is listed literally, the model-written preview has its
controls escaped and sits in a bounded block, and the card says the preview is a
sample of a larger action. A grant kind the client cannot translate disables
Allow, because approving part of a request without saying so would misstate it.

## What the protocol document got wrong

`docs/client-protocol.md` was enough to build from, and the first connection
worked. Live frames contradicted it in two places, and both matter to any third
client:

- Entries in a snapshot transfer carry the durable record, so a `toolCall` block
  is inlined. The document's wire form, nested under `toolCall`, is true only of
  the pushed `entry` event.
- Pending escalations reach a transfer as `fact.custom` cells keyed
  `escalation/<id>`. Their grants use `grant` as the discriminator and `cpu_s`
  style limit names, whereas `approve` needs `type` and `cpu_seconds`. The client
  must translate, as `session_view/approval.wire_grant` does. The document
  describes only the `escalation` event's shape.

## Gaps

| Gap | Effect | Likely fix |
|---|---|---|
| No push on the control socket | Fleet state lags by up to 2 s, and every client polls | A catalogue and activity change notice, which needs a protocol change |
| `sessions.activity` lacks approval records | A socket per waiting session | Include a summary in the row, which needs a protocol change |
| Substrate has no authentication on loopback | Any local process can answer as the operator | Existing property of Substrate; worth deciding before remote use |
| An installed `substrated` older than Command Center has no feed | The app shows Substrate as absent | Update `substrated` |
| Remote escalations (`remote-escalation/`) | Not decoded, so not shown as records | Add when distributed sessions matter here |
| Reconnecting a dropped session socket | The session shows no live updates until it is reselected | Add the reconnect procedure of section 6.7 |

Not built yet: notifications, a free-form canvas, subagent views beyond a strand
picker, goals, permissions, memory, member invites, and starting the daemon.

## Verifying a change

`swift test` covers the pure rules. `scripts/fake_provider.py` is a scripted model
endpoint, so a throwaway daemon runs real sessions with no credential or spend.
`loom-probe` drives the protocol headlessly. A debug build run with
`LOOM_DEBUG_DRIVER=<dir>` takes navigation and screenshot commands from a file;
see `App/Sources/DebugDriver.swift`. Never point these at a daemon you care about.
Use `--state-dir` and `LOOM_STATE_DIR`.
