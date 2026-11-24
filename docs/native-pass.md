# The Mac-native pass

Status: in progress, started 2026-11-21.

The inbox port reached parity with the web view in #1 and #2. The owner asked
for a pass after it so the app does not read as the web page in a window, but
uses what SwiftUI and the Mac give, while keeping what the web design is for.
This note is the plan for that pass: what three critics found, where they
disagreed and how that was settled, and the slices in the order they land.

## How it was reviewed

Three Sonnet 5.5 critics read the code and the current screenshots, each with
one lens, and did not see each other's reports:

- **Mac conventions:** what a Mac user expects and does not find.
- **SwiftUI structure:** where the code builds by hand what the framework gives.
- **The web design's intent:** what the web inbox is for, and which "more native"
  changes would break it.

All three found the same correctness bug first, so it leads the pass.

## What the web design is for

These hold through every slice. They come from the attention-inbox design notes
in Loom (`docs/design-notes/attention-inbox/`) and `inbox_rule.gleam`.

1. The inbox surfaces what needs the owner so they do not read transcripts.
2. Rows are grouped by whose move it is, in a fixed order, by one classifier
   that every surface uses.
3. Reading a thread never clears it.
4. An approval is decided only next to its evidence: Deny first, a 600 ms delay
   before the buttons act, no "Allow for this session" away from the evidence,
   and no command text as a title.
5. Agent-written text is labelled untrusted everywhere it is drawn.
6. Counts say what they read; there is no bare "Nothing needs you".
7. A review has one outbox, "Not sent." until Send.
8. Only the owner's clicks move what is open.

## Where the critics disagreed

**Deciding from a notification, a row or the toolbar.** The Mac critic proposed
Allow and Deny as notification actions and on inbox and Mission Control rows.
The intent critic's rule 4 forbids it: the decision is made only with the
evidence in view and after the arming delay. **Ruling:** rule 4 wins. A
notification opens the thread and never decides. Rows carry no deciding
controls. Menu commands for Allow and Deny exist, but are enabled only while an
armed approval card is on screen, and their titles name the tool.

**Unread and archive.** The Mac critic proposed swipe actions and mark-as-read.
Rule 3 says reading never clears a thread. **Ruling:** no unread state, no
archive and no swipe on Needs-you rows. A context menu carries only actions that
decide nothing (open the session, open in a new window, copy).

**Three columns.** The SwiftUI critic measured that a three-column
`NavigationSplitView` costs more than it gives, because Mission Control,
Machines and the session page have no content column. **Ruling:** the inbox
becomes an `HSplitView` of list and pane inside the detail column, and the
folder choice is a toolbar picker at every width. This removes the hand-sized
folder rail and its 920 pt breakpoint.

## Findings that are bugs

- **Three definitions of "needs you".** The sidebar groups by activity state,
  `Mission.attention` counts approvals, failed runs and unhealthy machines, and
  the inbox counts approvals, asks and stuck strands. The Dock badge, menu bar,
  notifications, ⌘J and the Inbox badge use `Mission.attention`, so an ask or a
  stuck strand never reaches them, and the screen can say "1 waiting" over
  "2 need you".
- **Deciding without evidence.** Mission Control's Needs You row has Allow, Deny
  and Allow for This Session with no evidence and no arming delay. The Session
  menu's ⇧⌘A, ⌥⇧⌘A and ⇧⌘D decide the first pending approval from a key chord.
  On the inbox they do nothing, because they act on `currentSession`, which is
  nil there.
- **A session folded while it waits.** A quiet session with an open ask draws
  under Needs you and again under Folded, whose gloss says no one is waiting.
  The web has the same structure; the fix belongs in both, and the Loom side is
  a separate PR.
- **A pane with no highlighted row.** The pane falls back to the first thread
  while the list's selection stays nil, and a refresh can change which thread is
  open.
- **A release-build check.** `InboxView` writes debug-only model properties; a
  release build must be confirmed to compile.

## The slices

Each slice is its own PR on `main`, with before and after captures and its UI
scenarios, merged when its gates pass. The order puts correctness first.

### 1. One count, and decisions only beside the evidence

- One pure `InboxRule.board` in MissionKit, computed once on the model, read by
  the Inbox badge, the window subtitle, the Dock badge, the menu bar, the
  notifier, ⌘J, Mission Control's Needs You block, the sidebar's Needs You
  group and the inbox. It counts approvals, asks, stuck strands and failed runs,
  the kinds the web's classifier counts.
- Mission Control's Needs You rows lose their deciding buttons and open the
  thread in the inbox instead.
- The Session menu's Allow, Allow for Session and Deny are enabled only while an
  armed approval card is visible in the focused window, through
  `focusedSceneValue`; their titles name the tool. They work from the inbox.
- A quiet session with feed rows is not folded.
- The release build is checked.

### 2. The inbox as a split view

- `HSplitView` of list and pane, with minimum widths, replacing `InboxLayout`.
- The folder choice is a toolbar `Picker` at every width.
- The selection lives on the model and is bound to the list, so the open thread
  is always the highlighted row, and a refresh never moves it.
- Done on `native/split-inbox`. A refresh settles the selection with
  `InboxRule.settle` and never moves it. A thread that resolves stays open,
  marked resolved, until the owner picks another row. The web inbox has no
  reading pane to follow (its `landing` only places a note), so rule 8 decided
  it. A folder click moves the open thread only when the folder does not draw it.
  Because a refresh never moves the selection, a session that first lists only a
  review opens that review, and an approval that arrives later does not take
  the pane. The fallback that opens the first thread runs only while the Inbox
  is on screen, so a row listed at launch is not frozen as if the owner had
  picked it, and a resolved opening is dropped when the owner leaves the Inbox,
  so a first visit never reads "resolved" about a thread the owner did not open.
  A pick that is no longer listed leaves the opening alone. A folder that has
  emptied is forgotten, so a later item in it does not narrow the list again.

### 3. Commands and the keyboard

- An Inbox menu through `FocusedValue`: next and previous thread (⌘] and ⌘[),
  open session, open in a new window, retry a stuck strand, close a find,
  message the session. Allow and Deny follow slice 1's rule.
- The same action list feeds a context menu on inbox rows and Mission Control
  rows, minus anything that decides.
- A thread can open in its own window.
- Done on `native/inbox-commands`. `InboxAction` and `InboxCommands`
  (`MissionKit/InboxCommands.swift`) are the one action list: the Inbox menu, the
  context menu on an inbox row and the context menu on a Mission Control row all
  draw from it, and `InboxCommands.state` says which actions a thread offers. A
  context menu draws only what can run for its row, minus navigation, anything
  that decides, and Retry and Close Find, which act on a thread the owner has not
  opened; those stay in the Inbox menu and the pane. A retry in flight is held
  on the model (`AppModel.retrying`), so the menu and the pane cannot queue two. Allow, Allow for This Session and Deny moved from the
  Session menu into the Inbox menu with the same shortcuts and titles, so there
  is one list; they follow the armed approval card in the focused window as
  before and work from a session's page too. Next Thread (⌘]) and Previous
  Thread (⌘[) step through `AppModel.inboxDrawn`, the folder's rows and then the
  machines, as the list draws them, and stop at the ends without wrapping. A
  selection the list does not draw (a resolved thread, or one outside the
  folder) enters the list at the end the step moves toward. Retry Stuck Strand
  and Close Find send what the pane's buttons send, and a refusal is said in the
  main window's existing alert. Message Session opens the thread and focuses its
  message field; it is off for a review, whose reply goes through the outbox.
  Open in New Window opens a `ThreadWindow` for the thread (`InboxSubject` is now
  `Codable`, since it is the window's value); a thread that resolves stays on
  screen marked resolved. Mission Control's agent strips carry the same context
  menu, on the session's own thread when it has one.
  `last_message` can hold newlines (loom #1364). The strip's digest and the
  sidebar's preview now read `InboxRule.oneLine` over the markdown preview, which
  also folds carriage returns and Unicode line separators that the preview kept; a
  row's head is the first line, folded the same way. The failed run's detail is
  read as markdown and keeps the message's own lines.

### 4. Native controls in the reading pane

- Sentence-case section headers instead of tracked capitals; one section style.
- Facts as `LabeledContent`; review files as `DisclosureGroup`.
- The verdict as a segmented control, neutral until staged.
- Answer options as a radio group and toggles, if accessibility presses still
  reach them; otherwise kept as they are.
- No dashed borders. The approval title names the tool and is capped at three
  lines; the full command stays in the facts.

### 5. Notifications

- Only for approvals, asks, stuck strands and failed runs, in the daemon's
  words with untrusted text labelled.
- Clicking one opens the thread. One thread identifier per session. A delivered
  notification is removed once its item resolves.
- Done on `native/notifications`. `Notices.plan` in MissionKit diffs the previous
  `InboxRule.board` against the new one: a new approval, ask, stuck strand or
  failed run is posted, an identifier that left the board is removed, and an
  unchanged board or any other kind does nothing. `Announcer` keeps the previous
  board and hands the plan to the notification center, and `NoticeClicks` is the
  center's delegate. The title is the app's words ("Approval waiting", "Asks you a
  question", "Strand stuck", "Run failed"), the session's name is the subtitle, and
  session text (an ask's question, the authority line an approval requests) is
  quoted on one line, cut at 140 characters and prefixed "untrusted text from the
  agent". A failed run's notice carries none. A click opens the row's thread, or
  the session's own thread when the row has since gone, and raises the main window
  if it was closed. The notification has no actions. The thread identifier is the
  session id, and the notice's identifier carries the kind, so an approval that is
  decided and then fails the run swaps one notice for another. The notice is
  removed when its row leaves the four kinds, whether the app is in front or not.
  The notifier waits for a first report before taking its baseline, so sessions
  already waiting at launch are a backlog, not news; a feed read that arrives after
  the sessions can still post a backlog ask. An approval is one row per session, so
  a second approval on a session already waiting posts no second notice; the
  inbox row stays the one place that shows how many. The scenario drives the plan
  and the click through the debug driver, since a test run posts nothing to the
  center.

### Later, not in this pass

Mission Control as a `Table`, `.searchable` on the inbox, semantic text styles
for the 72 fixed font sizes, Quick Look on changed files, and Settings tabs.
