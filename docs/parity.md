# Web UI and native client parity

This inventory lists what a person can do or see in Loom's web UI and says what the native SwiftUI client has today. It was derived from source at Loom commit `6575b5e38` and loom-desktop commit `0fd865c`. The architecture and protocol documents were used for orientation only.

**How to read the columns**

- **Web source** paths are relative to `packages/web_view/src/web_view/` in the Loom tree. Three prefixes name other directories: `wc:` is `packages/web_client/src/web_client/`, `sv:` is `packages/session_view/src/session_view/` and `cd:` is `packages/client/src/client/daemon/`.
- **Native** cites a file by its base name. Those files are in `App/Sources/`, `Sources/LoomKit/`, `Sources/MissionKit/` and `Sources/Markup/` of loom-desktop. A row is `yes` only where the native code was read. It may do the same job with a different control.
- **Wire command or event** names the v2 session or control command. The session page sends session commands on its lane. The web daemon runs most control-plane actions in process (`manager.*`, `server.*`), so for those rows the column names the control command that does the same job, and the web page does not send that frame itself. `local` means the state stays in the page or the browser. `in-process` means no control command was found for it.
- **†** marks a command the web path uses that `docs/client-protocol.md` does not specify. There are two: `advisor_pending` and `sessions.rename`. `server.gleam` also implements `sessions.archived`, which the doc does not specify, but no web path uses it.
- **Native** states mean: `yes`, a UI scenario in `tests/ui/scenarios.py` proves it and `make parity` enforces that; `code`, implemented with no scenario yet; `partial`, part of it exists; `no`, absent.
- **Tier** is a judgment made for this inventory: `1` a daily user notices within a session, `2` regular, `3` rare or admin.

## Home and session list

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| HM-01 | List sessions, grouped by project, newest first | view/sidebar.gleam:362 | `sessions.list` | code (RootView.swift:115, grouping by Project; ControlClient.swift:45) | 1 |
| HM-02 | Live activity word and dot for each running row (working, idle, needs you) | view/home_table.gleam:1092 | `sessions.activity` | code (RootView.swift:256) | 1 |
| HM-03 | Open a running session from a row | view/sidebar.gleam:839 | local; `ui.link` equivalent | code (RootView.swift:169) | 1 |
| HM-04 | Resume a saved session from a row | view/sidebar.gleam:859 | `sessions.open`, `operations.get` | code (SessionScreen.swift:66; AppModel.swift:253) | 1 |
| HM-05 | Saved sessions behind a remembered "N saved" toggle | view/sidebar.gleam:708 | local | code (RootView.swift:176; collapse state is not persisted) | 2 |
| HM-06 | Fold quiet rows behind "Show N more" | view/sidebar.gleam:667 | local | code (RootView.swift:158; native lists every row and needs no bound) | 3 |
| HM-07 | Machine pills that filter the list, with counts | view/sidebar.gleam:566 | local | partial (RootView.swift:123 groups by machine; no filter or counts) | 2 |
| HM-08 | Row tag `agent → code` | view/sidebar.gleam:893 | `sessions.list` | yes (RootView.swift:296) | 2 |
| HM-09 | Row subtitle, the first line of the first prompt | view/sidebar.gleam:893 | `sessions.list` | partial (RootView.swift:266 shows the subtitle only when there is no last message) | 2 |
| HM-10 | Worktree directory name on a row | sessions.gleam:430 | `sessions.list` | no | 3 |
| HM-11 | Sidebar "New session" | view/sidebar.gleam:528 | local | yes (RootView.swift:202) | 1 |
| HM-12 | Sidebar foot: Admin door | view/sidebar.gleam:757 | `ui.link` equivalent | no | 3 |
| HM-13 | Row menu with "Rename, move or delete" | view/sidebar.gleam:932 | local | yes (SessionActions.swift; context menu and Session menu) | 2 |
| HM-14 | Archive a saved row with a question | view/archiving.gleam:206 | `sessions.archive` | yes (SessionActions.swift) | 2 |
| HM-15 | Stop and archive a running row, asking when mid-turn | view/archiving.gleam:310 | `sessions.stop`, `sessions.archive` | yes (SessionActions.swift; stops, waits for saved, archives) | 2 |
| HM-16 | Stop a running row, asking when it is mid-turn | view/home_table.gleam:689 | `sessions.stop` | yes (SessionActions.swift, asks only when mid-turn) | 2 |
| HM-17 | Delete a saved or blocked row, with a question | view/home_table.gleam:746 | `sessions.delete` | yes (SessionActions.swift) | 2 |
| HM-18 | Rename a row in place | view/home_table.gleam:997 | `sessions.rename`† | yes (SessionActions.swift RenameSheet; `sessions.rename` read from server.gleam) | 2 |
| HM-19 | Row state words: saved, moving to, needs attention, failed to start | view/home_table.gleam:1094 | `sessions.list` | partial (RootView.swift:304 and SessionScreen.swift:51 say moving, failed and blocked; "saved" is a section title) | 2 |
| HM-20 | Row age, UTC minute in a title, and membership role | view/home_table.gleam:1111 | `sessions.list` | partial (RootView.swift:280 shows the age of the last observed change; no created age or role) | 3 |
| HM-21 | "Waiting" banner on the home with a Review button | view/new_session.gleam:299 | `sessions.activity` | yes (MissionViews.swift:23) | 1 |
| HM-22 | Count of waiting sessions on the sidebar menu button | component.gleam:7504 | `sessions.activity` | yes (RootView.swift:148, Inbox badge) | 2 |
| HM-23 | Show the full session list from the composer home | view/new_session.gleam:250 | local | code (MissionViews.swift:9, Mission Control) | 2 |
| HM-24 | Note drawn beside the row a press concerned | view/home_table.gleam:243 | local | partial (SessionScreen.swift:61 for resume; RootView.swift:241 discards a stop error) | 3 |

## New session

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| NS-01 | Prompt box that becomes the first message | view/new_session.gleam:394 | `sessions.create`, `sessions.open`, `subscribe`, `prompt` | yes (RootView.swift:414; AppModel.swift:276) | 1 |
| NS-02 | Session named from the message's first line | composer.gleam:490 | `sessions.create` | yes (RootView.swift:564) | 2 |
| NS-03 | Recent places, "Start again where you worked" | view/new_session.gleam:325 | `sessions.list` | yes (NewSessionSheet.swift lists used folders newest first) | 1 |
| NS-04 | Choose the agent machine | view/new_session.gleam:571 | `sessions.create` | partial (RootView.swift:426 picks among connected daemons; it does not list configured orchestrators) | 2 |
| NS-05 | Agent option state: checking, unavailable | view/new_session.gleam:629 | in-process | partial (RootView.swift:351 shows daemon state in the footer, not in the picker) | 3 |
| NS-06 | Searchable code picker: folders and workspaces | view/new_session.gleam:771 | `deployment.status` | yes (NewSessionSheet.swift; the folder field filters recent places or an executor's registered names) | 2 |
| NS-07 | Typed folder, judged before creation | creations.gleam:413 | `sessions.create` | yes (NewSessionSheet.swift and FolderCheck in Administration.swift judge the typed path before any request) | 1 |
| NS-08 | Run on an executor | view/create.gleam:511 | `sessions.create` `executor`; `deployment.status` | yes (RootView.swift:431; ControlClient.swift:97) | 2 |
| NS-09 | Run in a pool | view/create.gleam:511 | `sessions.create` `pool` | code (RootView.swift:433; ControlClient.swift:98) | 2 |
| NS-10 | Executor and pool cards: state, free scopes, contradiction, declaration | placements.gleam:71 | `deployment.status` | partial (RootView.swift:542 shows name, platform, free scopes and state; no contradiction text) | 3 |
| NS-11 | A down executor may still be chosen | view/create.gleam:511 | `sessions.create` | code (NewSessionSheet.swift allows a down executor with a warning; no scenario takes the executor down) | 3 |
| NS-12 | Workspace select for an executor's registered names | view/create.gleam:852 | `deployment.status` node read | yes (NewSessionSheet.swift; `executor.workspaces` read from the node report, which the old decoder missed) | 2 |
| NS-13 | Typed registered workspace when none is known | view/create.gleam:899 | `sessions.create` | yes (RootView.swift:530) | 3 |
| NS-14 | Choose a model profile | view/new_session.gleam:116 | `sessions.create` | yes (NewSessionSheet.swift; profiles read from the daemon's loom.toml, local daemons only) | 2 |
| NS-15 | Choose the main model | view/new_session.gleam:666 | `sessions.create` | yes (NewSessionSheet.swift; models read from the daemon's loom.toml, local daemons only) | 2 |
| NS-16 | Shareable box | view/create.gleam:956 | `sessions.create` `domain_scope` | yes (NewSessionSheet.swift, `domain_scope: session_only`) | 2 |
| NS-17 | Optional session name with its default stated | view/create.gleam:380 | `sessions.create` | yes (NewSessionSheet.swift) | 3 |
| NS-18 | New session under a project heading | view/create.gleam:278 | `sessions.create` | code (a project heading's plus in RootView.swift; the Session menu's New Session in This Folder is proven, but the sidebar list is not in the accessibility tree) | 2 |
| NS-19 | Remembered folders with "Forget this folder" | view/folders.gleam:136 | in-process (`manager.forget_folder`) | yes (NewSessionSheet.swift; a per-app list, since the daemon's forget is in-process) | 3 |
| NS-20 | Refusal words for each reason | creations.gleam:251 | `error` reply | partial (RootView.swift:451 draws the daemon's message) | 2 |
| NS-21 | Created but message unsent: "Open the session" | view/new_session.gleam:1141 | local | no | 3 |
| NS-22 | Start on another orchestrator | view/new_session.gleam:617 | in-process (`ui_top.found`) | partial (RootView.swift:426 only through a direct daemon connection) | 3 |

## Transcript

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| TR-01 | Live transcript from cuts and pushes | component.gleam:1673 | `subscribe`, `catch_up`, `snapshot_next`, `committed` | yes (SessionLane.swift:55; Conversation.swift:276) | 1 |
| TR-02 | Streaming answer in a live region | view/live.gleam:187 | `stream_delta` | yes (SessionScreen.swift:563) | 1 |
| TR-03 | Thinking row before anything streams, with elapsed time | view/live.gleam:174 | `op_transition`, `stream_delta` | partial (SessionScreen.swift:592 shows Working with a timer measured from when the client saw the run) | 1 |
| TR-04 | Live reasoning row with a preview and expandable text | view/fold_row.gleam:189 | `stream_delta` | partial (SessionScreen.swift:568 shows the last 500 characters until text starts; not expandable) | 1 |
| TR-05 | Generation rate, `tok/s` | view/heading.gleam:227 | `usage`, `op_transition` | no | 2 |
| TR-06 | Markdown answers | markdown_view.gleam:248 | `entry` | partial (Markdown.swift:5 and Theme.swift:225; no alert or footnote block) | 1 |
| TR-07 | Code fences with syntax highlighting | code_view.gleam:67 | `entry` | yes (Theme.swift:395; Syntax.swift:58) | 1 |
| TR-08 | Mermaid diagrams, source disclosure, Copy source, Expand | markdown_view.gleam:248; wc:mermaid.gleam:36 | `entry` | no | 2 |
| TR-09 | Tables that scroll in their own box | markdown_view.gleam:295 | `entry` | yes (Theme.swift:328) | 2 |
| TR-10 | Clickable links, validated before an anchor is drawn | wc:link.gleam:14 | `entry` | partial (Theme.swift:313 renders links; no `link_rule` equivalent) | 2 |
| TR-11 | A turn's work folded behind one divider with figures | view/lane.gleam:1031 | `history_lineage` for fold steps | partial (SessionScreen.swift:355 folds runs of consecutive tool calls; no per-turn divider or duration) | 1 |
| TR-12 | Failed count and "interrupted" on a divider | sv:turns.gleam:173 | `entry` | partial (Conversation.swift:195 counts failed calls; no interrupted word) | 2 |
| TR-13 | Step rows with verb, subject and `+n −m` | view/fold_row.gleam:57; sv:step_words.gleam:121 | `entry` | partial (SessionScreen.swift:443 shows a command, path or pattern; no counts on the row) | 1 |
| TR-14 | Open a step for its full program and result | view/fold_row.gleam:57 | `entry` | code (SessionScreen.swift:470) | 1 |
| TR-15 | Running step with elapsed time from its record | view/fold_row.gleam:57 | `entry`, `tool_output` | partial (SessionScreen.swift:449 shows a spinner and output tail; no elapsed time) | 2 |
| TR-16 | Failed step's plain sentence, then its remaining rows | view/lane.gleam:1638; sv:step_words.gleam:398 | `entry` | partial (SessionScreen.swift:487 shows raw result text in failure colour) | 2 |
| TR-17 | Program card for `code_mode`: outcome, chips, calls, result | view/program_card.gleam:89 | `entry` | no (SessionScreen.swift:497 draws a generic row) | 2 |
| TR-18 | Settled reasoning: preview, line count, time, body | view/lane.gleam:1400 | `entry` | partial (SessionScreen.swift:315 has a disclosure only) | 1 |
| TR-19 | Summarizer's label on long reasoning | view/lane.gleam:1467 | `block_summaries`, `block_summary` | no | 2 |
| TR-20 | A person's message with sender name and role | view/lane.gleam:713 | `entry`, `presence` | partial (SessionScreen.swift:301 names a non-Owner author; no role) | 2 |
| TR-21 | Long message shortened with a toggle | view/lane.gleam:1341 | local | code (SessionScreen.swift:294 draws the whole text, so no toggle is needed) | 3 |
| TR-22 | Memory context as a closed row in the fold | sv:turns.gleam:213 | `entry` | no | 2 |
| TR-23 | Spawned line for a sub-agent | view/lane.gleam:780 | `entry` | partial (SessionScreen.swift:498 uses a generic person icon) | 2 |
| TR-24 | Sub-agent result line, opening to the report | view/lane.gleam:1550 | `entry` | partial (SessionScreen.swift:486 shows it as generic tool output) | 2 |
| TR-25 | Peer message card with session, strand and receipt | view/lane.gleam:834 | `entry` | partial (SessionScreen.swift:301 draws a bubble with an author; framing is not removed) | 2 |
| TR-26 | Reply to a peer, which drafts the reply | view/lane.gleam:935 | local, then `prompt` | no | 2 |
| TR-27 | Open the peer's session | view/lane.gleam:956 | local; `ui.link` equivalent | no | 2 |
| TR-28 | Sibling strand's message card | view/lane.gleam:850 | `entry` | partial (SessionScreen.swift:301 draws a bubble with an author; framing is not removed) | 2 |
| TR-29 | Decided approval row in the lane | sv:decisions.gleam:89 | `escalations_decided` | no | 2 |
| TR-30 | Cache miss row | sv:turns.gleam:351 | `usage` | no | 3 |
| TR-31 | Delivered advisor nudge row | sv:turns.gleam:324 | `entry` | partial (Conversation.swift:602 draws a `[loom]` note as a one-line notice) | 3 |
| TR-32 | Compaction, branch and oversized notices | sv:transcript_lines.gleam:2672 | `entry` | code (Conversation.swift:571) | 2 |
| TR-33 | Provider failure and Stopped rows | sv:transcript_lines.gleam:35 | `entry` | partial (Conversation.swift:633 shows the raw error; no worded Stopped diagnostic) | 2 |
| TR-34 | Load older, by turns | view/lane.gleam:566 | `history_lineage` | partial (SessionScreen.swift:187 and SessionLane.swift:132 page with `history`) | 1 |
| TR-35 | Beginning-of-conversation and loading words | view/lane.gleam:556 | local | partial (SessionScreen.swift:187 says Loading; nothing at the beginning) | 3 |
| TR-36 | Frozen historical browsing, with return to latest | component.gleam:6717 | `history` | no | 2 |
| TR-37 | Follow the tail, keep place when scrolled, Jump to latest | view/lane.gleam:210; wc:follow.gleam:3 | local | yes (SessionScreen.swift:221 and :233) | 1 |
| TR-38 | Keep the reader's place per strand | wc:follow_rule.gleam:428 | local | no (SessionScreen.swift:171 keeps one scroll position; a strand change redraws it) | 2 |
| TR-39 | Images in user messages and tool results | view/lane.gleam:1606; image.gleam:77 | `/ui/.../image` route | no | 2 |
| TR-40 | Large result: View full result, page through, Download | tool_result.gleam:36 | `/ui/.../result` route | no | 3 |
| TR-41 | Queued and steered inputs under the live region | view/live.gleam:98 | `pending_inputs` in metadata | code (SessionScreen.swift:640) | 1 |
| TR-42 | Timeline dots and tags that focus a strand | view/lane.gleam:640; wc:shell_rule.gleam:1035 | local | no | 3 |
| TR-43 | Observer page is read-only | view/shell.gleam:71 | role in `snapshot_begin` | partial (Transfer.swift:84 reads the role; controls are not hidden) | 2 |

## Composer and slash commands

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| CO-01 | Send when idle | operator_page.gleam:1138 | `prompt` | yes (SessionScreen.swift:754) | 1 |
| CO-02 | Steer when busy | operator_page.gleam:1141 | `steer` | yes (AppModel.swift:681) | 1 |
| CO-03 | Queue when busy, runs after the turn | operator_page.gleam:1140 | `prompt` (held by the daemon) | no (AppModel.swift:684 always steers when busy) | 1 |
| CO-04 | Send key: Command or Control with Enter | wc:composer_rule.gleam:356 | local | code (SessionScreen.swift:686, with Return; Shift or Option adds a line) | 1 |
| CO-05 | Slash command list as the draft grows | wc:composer_rule.gleam:361; completion.gleam:39 | local | no | 1 |
| CO-06 | Argument rows for effort, goal, model and profile | sv:command.gleam:305; completion.gleam:106 | local | no | 2 |
| CO-07 | Addressed strand shown above the editor | operator_page.gleam:1066 | local | code (SessionScreen.swift:751, in the placeholder) | 2 |
| CO-08 | Busy mark and hint | operator_page.gleam:950 | local | yes (SessionScreen.swift:751 and :592) | 1 |
| CO-09 | Notice line after a command | operator_page.gleam:1164; sv:notice_words.gleam:35 | reply outcome | partial (SessionScreen.swift:654 shows errors only) | 2 |
| CO-10 | Who the page acts as, `Owner · operator` | operator_page.gleam:1093 | `snapshot_begin` | no | 3 |
| CO-11 | Cache outlook of the addressed strand | operator_page.gleam:1108 | `usage` | no | 2 |
| CO-12 | Sent draft as a pending line until taken | wc:pending_rule.gleam:126 | local | no | 2 |
| CO-13 | Refused draft restored to the editor | wc:pending_rule.gleam:148 | error reply | no (SessionScreen.swift:758 clears the text before the reply) | 2 |
| CO-14 | Returned prompt put back in the editor | operator_page.gleam:1050 | returned draft event | no | 2 |
| CO-15 | Attach images by button, paste or drop, with chips and limits | operator_page.gleam:975; wc:attach.gleam:96 | `prompt_content` | no | 2 |
| CO-16 | Submit disabled when empty | wc:composer_rule.gleam:384 | local | code (SessionScreen.swift:737) | 3 |
| CO-17 | `/compact` | sv:command.gleam:556 | `compact` | no | 2 |
| CO-18 | `/abort` | sv:command.gleam:557 | `abort` | yes (equivalent Stop button and key, SessionScreen.swift:693 and :723) | 1 |
| CO-19 | `/steer <text>` | sv:command.gleam:596 | `steer` | yes (equivalent, AppModel.swift:686) | 2 |
| CO-20 | `/queue <text>` | sv:command.gleam:598 | `follow_up` | no | 2 |
| CO-21 | `/model <name>` | sv:command.gleam:564 | `set_config` `model_name` | no | 1 |
| CO-22 | `/effort <level>` | sv:command.gleam:593 | `set_config` `thinking_level` | no | 2 |
| CO-23 | `/profile`, `/model-profile` show | sv:command.gleam:566 | `profile_get` | no | 2 |
| CO-24 | `/profile <name>`, `/profile default` | sv:command.gleam:567 | `profile_set` | no | 2 |
| CO-25 | `/fork <name>` | sv:command.gleam:591 | `fork` | no | 2 |
| CO-26 | `/goal <objective>`, `--budget` | sv:command.gleam:595 | `goal_set` | no | 2 |
| CO-27 | `/goal check [command]` | sv:command.gleam:692 | `goal_check` | no | 3 |
| CO-28 | `/goal clear` | sv:command.gleam:677 | `goal_clear` | no | 2 |
| CO-29 | `/goal pause` | sv:command.gleam:678 | `goal_pause` | no | 2 |
| CO-30 | `/goal resume` | sv:command.gleam:679 | `goal_resume` | no | 2 |
| CO-31 | `/schedules` | sv:command.gleam:522 | `schedules` | no | 2 |
| CO-32 | `/unschedule <name> [target]` | sv:command.gleam:600 | `schedule_cancel` | no | 3 |
| CO-33 | `/approvals [id]` | sv:command.gleam:532 | `escalations_get`, `escalations_decided` | no | 3 |
| CO-34 | `/approve <id>` | sv:command.gleam:585 | `approve` | partial (buttons only, SessionScreen.swift:857) | 3 |
| CO-35 | `/deny <id>` | sv:command.gleam:587 | `deny` | partial (buttons only, SessionScreen.swift:854) | 3 |
| CO-36 | `/btw <question>` | sv:command.gleam:550 | `btw` | no | 2 |
| CO-37 | `/btw`, `/btw refresh`, `/btw clear`, `/btw cancel`, `/btw close` | sv:command.gleam:541 | `btw`; close is local | no | 3 |
| CO-38 | `/peek <child>`, `/peek close` | sv:command.gleam:547 | `child_history` | code (equivalent row press, SessionScreen.swift:888 and :1134; no typed form) | 2 |
| CO-39 | `/clear`, clears this client's transcript | sv:command.gleam:560 | local | no | 3 |
| CO-40 | Skill slash command as a prompt | sv:command.gleam:897 | `prompt` | no (the page loads no skill list, so it refuses these as unknown; native sends the text as a plain prompt) | 3 |

## Approvals

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| AP-01 | Pending card in a region above the composer | operator_page.gleam:712 | escalation cells in metadata | yes (SessionScreen.swift:633) | 1 |
| AP-02 | Who asks and what for, in a sentence | operator_page.gleam:779 | metadata | partial (SessionScreen.swift:790 names tool and strand; no `approval.wants` sentence) | 1 |
| AP-03 | Literal action and authority lists | operator_page.gleam:803 | metadata | yes (SessionScreen.swift:781 and :821) | 1 |
| AP-04 | Deny, naming the tool | operator_page.gleam:775 | `deny` | yes (SessionScreen.swift:854; no tool in the label) | 1 |
| AP-05 | Allow once, naming the tool | operator_page.gleam:819 | `approve` | yes (SessionScreen.swift:857; no tool in the label) | 1 |
| AP-06 | Allow for this session, on the owner's page where eligible | operator_page.gleam:874 | `approve` `scope` | partial (SessionScreen.swift:864; it does not check that the reader is the owner, and Escalation.swift:59 omits the wall-seconds-zero form) | 2 |
| AP-07 | Grants outside the ceiling, listed with their reason | operator_page.gleam:844 | `remote-escalation` cells | code (SessionScreen.swift:802) | 3 |
| AP-08 | "Cannot be approved from the page" with its reason | operator_page.gleam:830 | metadata | partial (SessionScreen.swift:812 counts untranslatable grants and disables Allow) | 3 |
| AP-09 | 600 ms arming delay on a new card | operator_page.gleam:793 | local | no | 2 |
| AP-10 | Remote child's request | sv:approval.gleam:97 | `remote-escalation` cells | code (Conversation.swift:464) | 3 |
| AP-11 | No key acts inside the approval region | wc:shell_rule.gleam:922 | local | no (LoomApp.swift:111 deliberately has Allow and Deny keys) | 3 |
| AP-12 | Answer a stale record is refused locally, with words | component.gleam:4422 | local | partial (SessionLane.swift:99 echoes the sequence and the daemon refuses) | 2 |

## Strands and agents

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| ST-01 | Strand cards with name and one status line | view/strip.gleam:272; sv:strand_card.gleam:50 | metadata | partial (SessionScreen.swift:1107 shows a dot, name and model; no activity line) | 1 |
| ST-02 | Focus a strand from its card | view/strip.gleam:457 | local | code (SessionScreen.swift:1109 and toolbar :133) | 1 |
| ST-03 | Cache ring or avatar on a card | view/strip.gleam:491 | `usage` | no | 3 |
| ST-04 | Needs-approval badge on the Strands tab | wc:shell_rule.gleam:647 | metadata | partial (Inbox count, RootView.swift:148; none per strand) | 2 |
| ST-05 | Settled strands in a closed group, how each ended | view/strip.gleam:350 | metadata | no | 2 |
| ST-06 | Strand detail: task, model, context, cache, running, recent tools | view/strand_detail.gleam:86 | metadata | no | 2 |
| ST-07 | Breadcrumb "All strands", with Esc | view/crumb.gleam:61 | local | no | 2 |
| ST-08 | Remote child card with orchestrator and seen age | view/strip.gleam:400 | `remote_children` | code (SessionScreen.swift:902) | 3 |
| ST-09 | Peek at a remote child's transcript | view/peek.gleam:49 | `child_history` | code (SessionScreen.swift:922; only the first page is requested) | 3 |
| ST-10 | Model on a card when it differs from main | view/strip.gleam:410 | metadata | code (SessionScreen.swift:1116) | 3 |
| ST-11 | Todo board in the dock | view/todo_panel.gleam:153 | `notes` seed, `entry` | no | 1 |
| ST-12 | Reviewer band | view/todo_panel.gleam:82; sv:reviewer_status.gleam:225 | metadata | no | 3 |
| ST-13 | Advisor's pending nudges | view/nudges.gleam:66 | `advisor_pending`† | no | 2 |
| ST-14 | Advisor's settled commentary | view/commentary.gleam:87 | `entry` | no | 2 |
| ST-15 | Fork the strand from a form | view/controls.gleam:76 | `fork` | no | 2 |
| ST-16 | Compose to the focused strand | component.gleam:6549 | `prompt`, `steer` | code (AppModel.swift:682) | 1 |

## Goals

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| GO-01 | Goal row with status and spend | view/session_tab.gleam:173; sv:goal_view.gleam:563 | `goal_get`, `goal_changed` | no | 2 |
| GO-02 | Dock goal line while active or paused | view/controls.gleam:113 | `goal_get` | no | 2 |
| GO-03 | Pause button | operator_page.gleam:623 | `goal_pause` | no | 2 |
| GO-04 | Resume button | operator_page.gleam:624 | `goal_resume` | no | 2 |
| GO-05 | Clear button | operator_page.gleam:625 | `goal_clear` | no | 2 |
| GO-06 | "No goal is pinned" guidance | view/controls.gleam:142 | local | no | 3 |

## Proposals and evolution

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| PV-01 | Proposals review list, rule or config, with the change | view/proposals.gleam:78 | `proposals_get`, `proposals_changed` | no | 2 |
| PV-02 | Pending proposal card in the dock | view/proposals.gleam:363 | `proposals_get` | no | 2 |
| PV-03 | Approve a proposal, after a question | view/proposals.gleam:311 | `proposal_decide` | no | 2 |
| PV-04 | Reject a proposal | view/proposals.gleam:279 | `proposal_decide` | no | 2 |
| PV-05 | Count of proposals on the Session tab | wc:shell.gleam:263 | `proposals_changed` | no | 3 |
| PV-06 | Evolution tab, Read again | view/evolution.gleam:150 | `evolution` `board`; `evolution_changed` | no | 3 |
| PV-07 | Live generation per surface | view/evolution.gleam:230 | `evolution` `board` | no | 3 |
| PV-08 | Candidates with description, facts, evidence and approval | view/evolution.gleam:344 | `evolution` `board` | no | 3 |
| PV-09 | Approve or revoke, after a question | view/evolution.gleam:638 | `evolution` `approve`, `revoke` | no | 3 |
| PV-10 | Select a candidate, with a staging line | view/evolution.gleam:551 | `evolution` `select`, `status` | no | 3 |
| PV-11 | Roll back, with a reason | view/evolution.gleam:759 | `evolution` `rollback` | no | 3 |
| PV-12 | History section | view/evolution.gleam:844 | `evolution` `board` | no | 3 |
| PV-13 | Read core status | view/evolution.gleam:940 | `evolution` `core_status` | no | 3 |
| PV-14 | Evolution count on its tab | wc:shell_rule.gleam:472 | `evolution` `board` | no | 3 |

## Memory

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| ME-01 | Memory overview: tiles, what the session receives, notes, rules and queue, on the owner's page | view/memory.gleam:40 | `memory_get` | no | 3 |

## Notes

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| NO-01 | Notes tab for the focused strand | view/notes.gleam:45 | `notes` | no | 2 |
| NO-02 | Refresh | view/notes.gleam:60 | `notes` | no | 3 |
| NO-03 | Search keys and values | view/notes.gleam:78 | local | no | 2 |
| NO-04 | Open a note, go back | view/notes.gleam:157; view/notes.gleam:220 | local | no | 2 |
| NO-05 | Readable or Raw view of a note | view/notes.gleam:242 | local | no | 3 |

## Schedules

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| SC-01 | List schedules, as a command answer | sv:commands.gleam:627 | `schedules` | no | 2 |
| SC-02 | Retire a schedule | sv:commands.gleam:637 | `schedule_cancel` | no | 3 |

The web page has no schedule surface beyond these two commands.

## Jobs

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| JO-01 | Live jobs on the Session tab, refreshed on a timer | view/session_tab.gleam:174; sv:session_summary.gleam:107 | `live_jobs` | no | 2 |
| JO-02 | "not read yet" and "at last refresh" wording | view/session_tab.gleam:296 | local | no | 3 |

## Queue

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| QU-01 | Held input row with excerpt and words | view/queue_input.gleam:96 | `pending_inputs` | code (SessionScreen.swift:640) | 1 |
| QU-02 | Open a held input to edit it | view/queue_input.gleam:316 | `queued_input` | no | 2 |
| QU-03 | Save the edit at its revision | view/queue_input.gleam:348 | `edit_queued_input` | no | 2 |
| QU-04 | Remove a held input | view/queue_input.gleam:388 | `remove_queued_input` | no | 2 |

## Context

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| CX-01 | `ctx ~41%` figure in the top bar | view/heading.gleam:155 | `context` | no | 1 |
| CX-02 | Breakdown: stacked bar, basis words, tokens to auto-compact | view/context_breakdown.gleam:349 | `context` | no | 2 |
| CX-03 | What is in the context, an item list | view/context_breakdown.gleam:491 | `context` | no | 3 |
| CX-04 | Refresh | view/context_breakdown.gleam:194 | `context` | no | 3 |
| CX-05 | Compact now | view/context_breakdown.gleam:205 | `compact` | no | 2 |
| CX-06 | Children on other orchestrators, their spend | view/context_breakdown.gleam:153 | `remote_usage` in snapshot | no | 3 |
| CX-07 | Dismiss on an outside press or Escape | wc:dismiss_rule.gleam:100 | local | no | 3 |

## Worktree and diffs

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| WT-01 | Changes tab reads the workspace, refreshing after tool results | cd:ui_socket.gleam:3764 | `worktree_diff` | yes (SessionScreen.swift:1057) | 1 |
| WT-02 | Title, file count and per-file counts | view/worktree.gleam:82; view/worktree.gleam:150 | `worktree_diff` | yes (SessionScreen.swift:1018 and :1082) | 1 |
| WT-03 | One red and green diff per file | view/diff.gleam:38; view/worktree.gleam:127 | `worktree_diff` | yes (Theme.swift:438; Diff.swift) | 1 |
| WT-04 | File status words | view/worktree.gleam:180 | `worktree_diff` | no | 3 |
| WT-05 | Committed in this session | view/worktree.gleam:65 | `worktree_diff` | code (SessionScreen.swift:1049) | 2 |
| WT-06 | Omitted files and the diff-cut note | view/worktree.gleam:73; view/worktree.gleam:134 | `worktree_diff` | partial (SessionScreen.swift:1044 says omitted; no cut note) | 3 |
| WT-07 | Edit board from this session's edits, as a fallback | view/changes.gleam:178; sv:changes_view.gleam:217 | `entry` | no (SessionScreen.swift:1031 shows the failure and has no fallback) | 2 |
| WT-08 | Edit diffs in a step | view/diff.gleam:52 | `entry` | yes (SessionScreen.swift:472) | 1 |
| WT-09 | Read refused or failed, one sentence | view/changes.gleam:240 | `worktree_diff` | code (SessionScreen.swift:1032) | 3 |
| WT-10 | Trace tab: programs, state, result, calls, budget | view/trace.gleam:62; view/trace.gleam:96 | `entry` | no | 2 |

## Permissions

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| PE-01 | List what the session remembers | view/remembered.gleam:65 | `permissions` | no | 2 |
| PE-02 | Forget, with a question | view/remembered.gleam:184; view/remembered.gleam:242 | `permission_forget` | no | 2 |
| PE-03 | Which ended sign-in each permission came from | component.gleam:1340 | in-process | no | 3 |

## Members and sharing

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| SH-01 | Viewers of the session, with roles | view/session_tab.gleam:171; sv:session_summary.gleam:132 | `presence` | code (SessionScreen.swift:1174 and :710) | 2 |
| SH-02 | Invite as observer or operator | view/share.gleam:289 | `sessions.invite` | yes (SharingSheet.swift; the owner invites by name and role) | 2 |
| SH-03 | Invitation handover: address, token, command, with copy | view/share.gleam:326; view/share.gleam:384 | `sessions.invite` | yes (SharingSheet.swift HandoverView: address, command, token, copy buttons; the command never carries the token) | 2 |
| SH-04 | Hide the token | view/share.gleam:360 | local | yes (SharingSheet.swift HandoverView) | 3 |
| SH-05 | Make a private session shareable, with a question | view/share.gleam:164; view/share.gleam:179 | `sessions.isolate` | yes (SharingSheet.swift; stops, isolates and reopens a running session, because the daemon refuses to isolate a live runtime) | 3 |
| SH-06 | Rename the session from its page | view/rename.gleam:147 | `sessions.rename`† | yes (SessionActions.swift RenameSheet, Session menu) | 2 |
| SH-07 | Accept an invitation with a claim form | page.gleam:761 | `credentials.claim` | no (Discovery.swift:31 refuses a claim token) | 3 |

## Credentials and sign-ins

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| CR-01 | Your name, and change it | view/your_name.gleam:72; view/your_name.gleam:107 | `principals.rename` | yes (PeopleSheet.swift, Go menu People…) | 3 |
| CR-02 | People list on the admin page | view/admin_people.gleam:135 | `principals.list` | yes (PeopleSheet.swift) | 3 |
| CR-03 | Rotate a person's credential | view/admin_people.gleam:277 | `credentials.rotate` | yes (PeopleSheet.swift, after a question) | 3 |
| CR-04 | Revoke a person's access, two steps | view/admin_people.gleam:289 | `credentials.revoke` | yes (PeopleSheet.swift, after a question) | 3 |
| CR-05 | Rename a person | view/admin_people.gleam:214 | `principals.rename` | yes (PeopleSheet.swift) | 3 |
| CR-06 | A person's sign-ins, and revoke one | view/admin_people.gleam:330 | `credentials.signins`, `credentials.revoke_login` | code (PeopleSheet.swift lists a person's browser sign-ins and revokes one; the fixture has no browser logins) | 3 |
| CR-07 | Claim shown once beside the action | view/admin_claim.gleam:108 | `sessions.invite`, `credentials.rotate` | yes (SharingSheet.swift HandoverView, shared by invite and rotate) | 3 |
| CR-08 | Session members, set role and revoke membership | view/admin_sessions.gleam:222; grants.gleam:219 | `sessions.members`, `sessions.set_role`, `sessions.revoke` | yes (SharingSheet.swift sets a role and removes a member, after a question) | 3 |
| CR-09 | Invitation form with name and role | view/admin_sessions.gleam:491 | `sessions.invite` | yes (SharingSheet.swift) | 3 |
| CR-10 | Make shareable from the admin page | view/admin_sessions.gleam:301 | `sessions.isolate` | yes (SharingSheet.swift) | 3 |
| CR-11 | Grant allowance spent, with the time a place frees | admin.gleam:888; wc:time_rule.gleam:49 | `error` details | no | 3 |

## Machines and deployment

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| MA-01 | Deployment section, summary line | view/admin_machines.gleam:155 | `deployment.status` | yes (MachinesView.swift:44) | 3 |
| MA-02 | Machines grouped by role | view/admin_machines.gleam:127 | `deployment.status` | partial (MachinesView.swift:79 grids by node and shows roles; not grouped) | 3 |
| MA-03 | Row facts and "not linked from here" | view/admin_machines.gleam:391 | `deployment.status` | partial (MachinesView.swift:133 shows platform, enforcement and build; no link standing) | 3 |
| MA-04 | Pools | view/admin_machines.gleam:554 | `deployment.status` | no (only in the dispatch picker) | 3 |
| MA-05 | Machine page tab: Overview | view/admin_machine.gleam:191; machines.gleam:551 | `deployment.status` `node` | partial (MachinesView.swift:94 shows state, reasons and meters) | 3 |
| MA-06 | Machine page tab: Sessions | view/admin_machine.gleam:428; view/admin_machine.gleam:539 | `deployment.status`, `sessions.elsewhere` | partial (MachinesView.swift:100 lists this daemon's dependents) | 3 |
| MA-07 | Machine page tab: Access, ledger standing | view/admin_machine.gleam:663 | `ledger.status`, `ledger.entries` | no | 3 |
| MA-08 | Copy enroll, renew and revoke commands | view/admin_machine.gleam:681; view/admin_machine.gleam:689; view/admin_machine.gleam:749 | none, the operator runs them | no | 3 |
| MA-09 | Scopes tab: counts and scopes that block a reopen | view/admin_machine.gleam:901 | `deployment.status` | partial (MachinesView.swift:141 shows the scope meter only) | 3 |
| MA-10 | Copy the release-scope command | view/admin_machine.gleam:777 | none, the operator runs it | no | 3 |
| MA-11 | Show a machine's sessions in the sidebar | admin.gleam:1399 | local | no | 3 |
| MA-12 | Admin page Machines and People parts | admin.gleam:1305 | local | yes (Machines only: MachinesView.swift:9; people are in CR rows) | 3 |
| MA-13 | Placement strip: "Agent on", "Commands on" | view/placement.gleam:42 | `sessions.list` | yes (SessionScreen.swift:102 and :1155) | 2 |
| MA-14 | "Runs on" in the Session tab | view/session_tab.gleam:170 | `sessions.list` | yes (SessionScreen.swift:1158) | 3 |
| MA-15 | Daemon's name in the sidebar | view/sidebar.gleam:541 | `sessions.list` | yes (RootView.swift:341) | 3 |

## Moves

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| MV-01 | Move: list eligible and ineligible destinations | view/home_table.gleam:958; sv:move_candidates.gleam:121 | in-process (`deployment.candidates`) | code (MoveSheet.swift lists `orchestrators` from deployment.status with the first reason each cannot take the session; the fixture has one orchestrator) | 3 |
| MV-02 | Move: confirm in the row | view/home_table.gleam:888 | `sessions.move` | code (MoveSheet.swift sends sessions.move; the fixture has no second orchestrator) | 3 |
| MV-03 | Move disabled with a reason for a session with no executor | view/home_table.gleam:774 | local | yes (MoveSheet.swift) | 3 |
| MV-04 | "Moving to" shown on a row | view/home_table.gleam:1094 | `sessions.list` | code (RootView.swift) | 3 |
| MV-05 | Moves on a machine page, and Abandon with a question | view/admin_machine.gleam:942; view/admin_machine.gleam:1021 | in-process (`server.abandon_move`) | code (MoveSheet.swift abandons from the session's move sheet; the web page does it on the machine page) | 3 |

## Peers

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| PL-01 | Peer links of the strand | view/peer_links.gleam:74 | `peers.inspect` | no | 3 |
| PL-02 | Link: pick session, strand, wake and both directions | view/peer_links.gleam:318; view/peer_links.gleam:354 | `peers.link` | no | 3 |
| PL-03 | Unlink, naming which directions | view/peer_links.gleam:167; view/peer_links.gleam:406 | `peers.unlink` | no | 3 |

## Other orchestrators

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| EL-01 | Sessions grouped by other orchestrators | view/elsewhere.gleam:154 | `sessions.elsewhere` | code (MachinesView.swift:196) | 3 |
| EL-02 | "No answer in time", distinct from no sessions | view/elsewhere.gleam:186 | `sessions.elsewhere` | code (MachinesView.swift:217) | 3 |
| EL-03 | Where: launch command with a copy box | view/elsewhere.gleam:232; sv:launch_words.gleam:36 | local | no (MachinesView.swift:209 offers Connect instead) | 3 |
| EL-04 | Show more | view/elsewhere.gleam:296 | `sessions.elsewhere` `after` | partial (MachinesView.swift:234 says more exist) | 3 |
| EL-05 | Strip on the owner's home | view/elsewhere.gleam:111 | `sessions.elsewhere` | no | 3 |
| EL-06 | Sidebar section "On <orchestrator>", opening a relayed page | view/sidebar.gleam:424; view/sidebar.gleam:472 | in-process (`ui_top`) | partial (AppModel.swift:323 merges sessions from daemons connected directly) | 3 |
| EL-07 | Relayed page: read a session on another orchestrator | view/relayed_session.gleam:140; cd:ui_top.gleam:109 | in-process (`ui_top.read`) | partial (only by a direct daemon connection, AppModel.swift:495) | 3 |
| EL-08 | Relayed page: reply | view/relayed_session.gleam:530; cd:ui_top.gleam:334 | in-process (`ui_top.send`) | partial (only by a direct daemon connection) | 3 |
| EL-09 | Relayed page: stop | view/relayed_session.gleam:234; cd:ui_top.gleam:355 | in-process (`ui_top.stop`) | partial (only by a direct daemon connection) | 3 |
| EL-10 | Relayed page: archive | view/relayed_session.gleam:253; cd:ui_top.gleam:374 | in-process (`ui_top.archive`) | no | 3 |
| EL-11 | Relayed page: decide an approval | view/relayed_session.gleam:414; cd:ui_top.gleam:403 | in-process (`ui_top.decide`) | partial (only by a direct daemon connection) | 3 |

## Files and images

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| FI-01 | Image limits from the daemon: four images, 8 MiB | image.gleam:160; image.gleam:168 | local | no | 3 |
| FI-02 | Image types checked from their bytes | image.gleam:128 | `prompt_content` | no | 3 |
| FI-03 | Rich image row: type, pixel size, bytes | sv:image_header.gleam:242 | `entry` | no | 3 |
| FI-04 | Paged view of a full tool result | tool_result.gleam:62 | `/ui/.../result` route | no | 3 |
| FI-05 | Download a full tool result as JSON | tool_result.gleam:49; cd:ui_http.gleam:253 | `/ui/.../result/.../download` route | no | 3 |

## Settings and profiles

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| SE-01 | Theme: system, light or dark | wc:layout_rule.gleam:348 | local | partial (LoomApp.swift:213 has no theme setting, so it follows the system) | 3 |
| SE-02 | Saved layout: columns and tab | wc:shell.gleam:539 | local | partial (SessionScreen.swift:974 keeps the inspector tab; column state is not saved by the app) | 3 |
| SE-03 | Show the session's profile, and switch it | sv:commands.gleam:620; sv:commands.gleam:624 | `profile_get`, `profile_set` | no | 2 |
| SE-04 | Reasoning effort | sv:command.gleam:344 | `set_config` | no | 2 |

## Session panel and top bar

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| PA-01 | Panel tabs: Strands, Changes, Session, Trace, Notes, Evolution | wc:shell_rule.gleam:467 | local | partial (SessionScreen.swift:967 has Changes, Agents and Details) | 1 |
| PA-02 | Hide and show the panel | wc:shell_rule.gleam:949 | local | yes (LoomApp.swift:75, ⌥⌘I) | 1 |
| PA-03 | Hide and show the sidebar | wc:shell_rule.gleam:946 | local | code (RootView.swift:13; system split view control) | 2 |
| PA-04 | Resize the panel by drag or keys | wc:grip_rule.gleam:208 | local | partial (SessionScreen.swift:122 by drag; no keys) | 3 |
| PA-05 | Top bar location: workspace and name | view/heading.gleam:75 | `sessions.list` | yes (SessionScreen.swift:114) | 1 |
| PA-06 | Main strand's model in the bar | view/heading.gleam:254 | metadata | yes (SessionScreen.swift:700, in the composer) | 1 |
| PA-07 | Connection pill: connected or disconnected | view/heading.gleam:139 | local | partial (SessionScreen.swift:620 shows only a Reconnecting line) | 2 |
| PA-08 | Estimated cost in the bar and Session tab | view/heading.gleam:182; view/session_tab.gleam:175 | `usage` | partial (SessionScreen.swift:706 and :1168 show the figure; no `est` or coverage words) | 1 |
| PA-09 | Home button | view/heading.gleam:286 | local | code (RootView.swift:150; Mission Control) | 2 |
| PA-10 | Session tab: workspace and session name | view/session_tab.gleam:170 | `sessions.list` | yes (SessionScreen.swift:1160) | 2 |
| PA-11 | Page ended notice with fixed advice | view/ended.gleam:27; ending.gleam:170 | close frame | partial (SessionScreen.swift:620 shows Reconnecting; reasons are not worded) | 2 |
| PA-12 | Tab title with the waiting count | wc:title_rule.gleam:41 | local | yes (LoomApp.swift:190, Dock badge; SessionScreen.swift:114 for the title) | 2 |
| PA-13 | Side question panel: refresh, cancel, clear, close | operator_page.gleam:1265 | `btw` | no | 2 |

## Keyboard shortcuts

| ID | Capability | Web source (file:line) | Wire command or event | Native | Tier |
|---|---|---|---|---|---|
| KB-01 | Command or Control K opens the switcher | wc:switcher_rule.gleam:106 | local | yes (LoomApp.swift:82; MissionViews.swift:392) | 1 |
| KB-02 | Switcher: Up, Down, Enter, Escape, typed filter | wc:switcher_rule.gleam:126 | local | yes (MissionViews.swift:516, :480, :524) | 1 |
| KB-03 | Command or Control B toggles the sidebar | wc:shell_rule.gleam:946 | local | partial (system control, no ⌘B binding in LoomApp.swift) | 2 |
| KB-04 | Command or Control Alt B toggles the panel | wc:shell_rule.gleam:949 | local | yes (⌥⌘I, LoomApp.swift:78) | 2 |
| KB-05 | Escape returns to main | wc:shell_rule.gleam:940 | local | no (SessionScreen.swift:691 uses Escape to stop a run) | 2 |
| KB-06 | Composer list: Up, Down, Tab, Enter, Escape | wc:composer_rule.gleam:361 | local | no | 2 |
| KB-07 | Escape in a note goes back | wc:notes.gleam:114 | local | no | 3 |

## Not applicable natively

| Web item | Source | Why |
|---|---|---|
| Tickets and `ui.link` exchange | cd:ui_sessions.gleam:546; cd:ui_http.gleam:605 | A page gets authority from a one-use ticket. The native client uses a bearer token over its own sockets. |
| Session and login cookies | cd:ui_http.gleam:805; cd:ui_http.gleam:839 | Browser credential storage. Native uses the keychain and the owner token file (AppModel.swift:31, Discovery.swift:84). |
| Page keys and nonces | cd:ui_sessions.gleam:898; cd:ui_sessions.gleam:910 | They bind a tab's socket to its page. |
| Origin checks and content security policy | cd:ui_origin.gleam:68; cd:ui_http.gleam:951; page.gleam:1083 | Browser security model. |
| Lustre transport and event path admission | cd:ui_socket.gleam:358; cd:ui_relay.gleam:173 | Server component machinery. |
| Page lifetime, oldest-page eviction and reconnect | ending.gleam:170 | Lifetime of a keyed page. Native reconnects its sockets (AppModel.swift:164). |
| Resume page, bookmark and exchange confirmation | page.gleam:596; view/signins.gleam:163 | They restore a browser login. |
| Sign out, sign out everywhere, and "Sign in another device" | view/signins.gleam:222; view/signins.gleam:313; view/signins.gleam:336 | They end or mint browser logins. Native has Disconnect for a saved daemon (MachinesView.swift:57). |
| Account popover and its Escape | wc:popover_rule.gleam:102; view/home_bar.gleam:119 | It holds the sign-in panel above. |
| Admin page's ending pill and Back control | view/home_bar.gleam:77; wc:back.gleam:2 | The page has a fifteen-minute deadline and history entries. |
| `<loom-switch>` navigation | view/switch.gleam:29 | A native window changes destination without a browser navigation. |
| `<loom-waiting>` page | wc:waiting.gleam:65 | Native has its own daemon-missing screen (RootView.swift:57). |
| File drop guard | wc:drop_guard.gleam:32 | Prevents a browser navigating to a dropped file. |
| `/help`, `/models`, `/model` alone, `/strands`, `/strand`, `/agents`, `/peers`, `/access`, `/evolution`, `/sessions`, `/rename`, `/notes`, `/diff`, `/summary`, `/trace`, `/context`, `/contextall`, `/details`, `/goal` alone, `/queue` alone, `/quit` | sv:command.gleam:518; component.gleam:4392 | The composer parses them, then `page_command` refuses each one as a terminal surface. They are terminal commands and not web capabilities. |
| `/add-dir`, `/add-write-dir` | sv:command.gleam:572; component.gleam:4403 | Parsed and refused by the page, with a pointer to the daemon's host. |

## Summary

| Native | Tier 1 | Tier 2 | Tier 3 | Total |
|---|---|---|---|---|
| yes | 34 | 21 | 17 | 72 |
| partial | 13 | 25 | 25 | 63 |
| no | 5 | 76 | 76 | 157 |
| Total | 52 | 122 | 118 | 292 |

### Native capabilities the web UI does not have

- Connect several daemons at once, with one merged list, and keep their credentials in the keychain (AppModel.swift:31, :495; MachinesView.swift:247).
- Inbox of attention items grouped by what each needs, and answering approvals from it (MissionViews.swift:287).
- Mission Control strips, with answers in place (MissionViews.swift:128) and a message to any agent from a popover (MissionViews.swift:249).
- Failed runs and unhealthy machines as inbox items, with the sessions that depend on each machine (Attention.swift:138, :210).
- Menu bar item with the waiting count (LoomApp.swift:46), Dock badge and background notifications (LoomApp.swift:190, :200), and a Settings toggle for them (LoomApp.swift:221).
- Keys to answer an approval: ⇧⌘A and ⇧⌘D (LoomApp.swift:114, :118).
- Stop button and keys on the session: ⌘. and Escape (LoomApp.swift:123; SessionScreen.swift:691, :723). The web page removed its Stop button.
- Next session needing you: ⌘J (LoomApp.swift:92). Direct keys for the views: ⌘1, ⌘2, ⌘3 (LoomApp.swift:85).
- Find in transcript: ⌘F (SessionScreen.swift:119; LoomApp.swift:125). Refresh changes key: ⇧⌘R (LoomApp.swift:127).
- Fuzzy palette including commands, ordered by attention with no query (MissionViews.swift:440).
- Open a session in its own window (RootView.swift:226; LoomApp.swift:28), reveal its workspace in Finder (RootView.swift:230), and copy a session ID (RootView.swift:234; SessionScreen.swift:1184).
- Copy buttons on messages and replies (SessionScreen.swift:291, :311).
- Bold marking of a reply not yet seen, kept across launches (AppModel.swift:389).
- Grouping the sidebar by status (RootView.swift:117), and the heartbeat trace on a working strip (MissionViews.swift:216).
- Daemon capacity meter (RootView.swift:361) and a per-machine scope meter (MachinesView.swift:176).
- Start `loomd` when it is missing (RootView.swift:76; AppModel.swift:445).
- Workspace chooser using the system folder panel (RootView.swift:551).
- Usage totals: input, output, cache read (SessionScreen.swift:1163).
