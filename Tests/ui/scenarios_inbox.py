"""Scenarios for the attention inbox: its groups, folders and reading panes, and the
session page's lifted rail.

Each scenario works in a repository of its own that holds one commit, so the review a
`demo` run leaves is the same size whatever earlier scenarios wrote to the shared
workspace. The inbox lists the sessions that are running, and every scenario starts with
the daemon's slots free, so only the sessions made here are listed.

The daemon's attention feed (asks, finds and stuck strands) is read about every fifteen
seconds, so a scenario waits for a row of the kind it needs before it acts. The list is
not in the accessibility tree, so its rows, bands and folders are read from the app's
`inbox` snapshot, which is encoded by the same rule the view draws from, and
`inboxpick` opens a thread as a click on its row does.
"""
import re
import subprocess
import time

from loomui import BASE, wait_for
from scenarios import check, run_command, scenario, settle

FEED_WAIT = 120

_made = {}


def fresh_repo(name):
    """A repository with one committed file, so a session's changes are its own."""
    path = BASE / name
    if name not in _made:
        path.mkdir(parents=True, exist_ok=True)
        git = ["git", "-C", str(path), "-c", "user.name=loom", "-c", "user.email=loom@example.com"]
        subprocess.run(["git", "-C", str(path), "init", "-q"], check=True)
        (path / "README.md").write_text("a repository for the inbox\n")
        subprocess.run(git + ["add", "README.md"], check=True)
        subprocess.run(git + ["commit", "-q", "-m", "start"], check=True)
        _made[name] = True
    return str(path)


def rows(c):
    """Every row of every band, each with the band's title."""
    return [dict(r, group=g["title"]) for g in c.app.snap()["inbox"]["groups"] for r in g["rows"]]


def find_row(c, kind, name=None):
    for r in rows(c):
        if r["kind"] == kind and (name is None or r["name"] == name):
            return r
    return None


def wait_row(c, kind, name=None, timeout=FEED_WAIT):
    """Waits for a row of this kind. An ask, a find and a stuck strand come from the feed."""
    return wait_for(lambda: find_row(c, kind, name), timeout, f"a {kind} row for {name!r}")


def open_thread(c, row):
    """Opens a thread as a click on its row does, and waits for the pane to read it."""
    c.app.cmd("inboxpick " + row["id"])
    wait_for(lambda: c.app.snap()["inbox"]["open"] == row["id"], 5, f"the pane to open {row['id']}")


def stuck_session(c, title, workspace):
    """Starts a session, forks a strand and runs a failing turn on it, so it is stuck."""
    sid = c.app.dispatch(title, workspace)
    c.app.open_session(title)
    settle(c)
    run_command(c, "/fork branch-two")
    name = wait_for(lambda: next((x for x in c.app.session()["strands"] if "branch-two" in x), None), 10, "the forked strand")
    c.app.cmd(f"strand {name}")
    wait_for(lambda: c.app.session()["focusedStrand"] == name, 5, "focus on the fork")
    c.app.prompt(sid, "run it and explode now")
    return sid


def tree_texts(c):
    """The accessibility tree's texts in the order a reader meets them."""
    return [t for t in c.app.texts() if t]


def position(texts, wanted, after=0):
    """The index of the first text equal to `wanted` at or after `after`."""
    for index in range(after, len(texts)):
        if texts[index].strip() == wanted:
            return index
    raise AssertionError(f"{wanted!r} is not in the pane")


# Groups and folders.


@scenario("AI-01", needs_display=True)
def the_inbox_keeps_a_readable_pane_at_the_smallest_window(c):
    """At every width the folder is a toolbar picker, the list and the pane are a split view, and the pane keeps its floor."""
    repo = fresh_repo("inbox-width")
    c.app.dispatch("Width approval escalate", repo)
    c.app.go("inbox")
    wait_row(c, "Approval", "Width approval escalate")
    try:
        for width, floor in ((880, 340), (1400, 420)):
            c.app.resize(width, 560 if width == 880 else 900)
            wait_for(lambda: c.app.snap()["inbox"]["paneWidth"] >= floor, 5, f"the pane to keep {floor} pt at {width} pt")
            check(c.app.fully_on_screen("Folder"), f"the folder picker should be on screen at {width} pt")
            check(not c.app.fully_on_screen("Folder Everything, by need"), "there is no folder rail any more")
    finally:
        c.app.resize(1400, 900)


@scenario("AI-01", "AI-03")
def the_open_pane_and_the_highlighted_row_agree_and_a_refresh_keeps_them(c):
    """The row highlighted is the thread in the pane, a new row never moves it, a resolved thread stays open, and a folder click moves it only when the folder does not draw it."""
    repo = fresh_repo("inbox-select")
    c.app.dispatch("Select approval escalate", repo)
    c.app.dispatch("Select ask askowner", repo)
    c.app.go("inbox")
    approval = wait_row(c, "Approval", "Select approval escalate")
    ask = wait_row(c, "Ask", "Select ask askowner")

    # The fallback opens the first thread only while the Inbox is on screen, so it cannot
    # have frozen a row listed before the owner looked, and what opens is a listed thread,
    # lit in the list and not marked resolved.
    wait_for(lambda: c.app.snap()["inbox"]["open"] != "", 5, "a thread to be open")
    wait_for(
        lambda: (lambda i: i["highlighted"] == i["open"] and not i["resolved"])(c.app.snap()["inbox"]),
        5, "the open row to be highlighted and unresolved",
    )

    # A chosen row is both highlighted and open.
    open_thread(c, approval)
    wait_for(lambda: c.app.snap()["inbox"]["highlighted"] == approval["id"], 5, "the chosen row to be highlighted")

    # A row that arrives, and sorts ahead of it, leaves the choice where it was.
    c.app.dispatch("Select second approval escalate", repo)
    c.app.go("inbox")
    wait_row(c, "Approval", "Select second approval escalate")
    time.sleep(2)
    inbox = c.app.snap()["inbox"]
    check(inbox["open"] == approval["id"] and inbox["highlighted"] == approval["id"], f"a new row moved the open thread: {inbox['open']}")

    # A folder that draws the open thread keeps it, and one that does not draws the folder's first.
    open_thread(c, ask)
    c.app.cmd("inboxfolder Needs you")
    wait_for(lambda: c.app.snap()["inbox"]["drawn"][0] == "Needs you", 5, "the Needs you folder")
    inbox = c.app.snap()["inbox"]
    check(inbox["open"] == ask["id"] and inbox["highlighted"] == ask["id"], "a folder that draws the thread keeps it open")
    c.app.cmd("inboxfolder Everything, by need")
    wait_for(lambda: c.app.snap()["inbox"]["drawn"][0] == "Everything, by need", 5, "Everything again")
    check(c.app.snap()["inbox"]["open"] == ask["id"], "choosing Everything moved the open thread")

    # A thread that resolves stays open, marked resolved, with no row highlighted, until another is picked.
    c.app.dispatch("Select note noticefind", repo)
    c.app.go("inbox")
    find = wait_row(c, "Risk", "Select note noticefind")
    open_thread(c, find)
    c.app.press("Dismiss")
    wait_for(lambda: not find_row(c, "Risk", "Select note noticefind"), 30, "the dismissed find to leave the list")
    wait_for(lambda: c.app.snap()["inbox"]["resolved"], 5, "the open thread to be marked resolved")
    time.sleep(2)
    inbox = c.app.snap()["inbox"]
    check(inbox["open"] == find["id"] and inbox["highlighted"] == "", f"the resolved thread moved or stayed highlighted: {inbox['open']}")
    c.app.see(r"Resolved\. This thread no longer needs you")
    open_thread(c, ask)
    wait_for(lambda: not c.app.snap()["inbox"]["resolved"], 5, "a picked row to be open and unresolved")


@scenario("AI-01", "AI-03", "AI-04", "AI-05")
def the_inbox_groups_threads_by_need_and_the_rail_narrows_them(c):
    """Asks, finds and stuck strands reach the inbox, grouped in the design's order, and each folder counts its band."""
    repo = fresh_repo("inbox-groups")
    c.app.dispatch("Groups approval escalate", repo)
    c.app.dispatch("Groups ask askowner", repo)
    c.app.dispatch("Groups note noticefind", repo)
    c.app.dispatch("Groups review demo", repo)
    stuck_session(c, "Groups stuck host", repo)
    c.app.go("inbox")
    ask = wait_row(c, "Ask", "Groups ask askowner")
    wait_row(c, "Stuck", "Groups stuck host")
    find = wait_row(c, "Risk", "Groups note noticefind")
    wait_row(c, "Approval", "Groups approval escalate")
    wait_row(c, "Review", "Groups review demo")

    # The bands come in the design's order, and the feed's items lead the first one.
    titles = [g["title"] for g in c.app.snap()["inbox"]["groups"]]
    order = ["Needs you", "To review", "Waiting", "Finds", "Updates", "Folded"]
    check(titles == sorted(titles, key=order.index), f"the bands are out of order: {titles}")
    needing = [r for r in rows(c) if r["group"] == "Needs you"]
    check({r["kind"] for r in needing} >= {"Ask", "Stuck", "Approval"}, f"Needs you holds {needing}")
    check(needing[-1]["kind"] == "Approval", f"a feed item should come before a session's approval: {needing}")

    # A row names its session, says its kind, and gives one line of what it holds.
    check(ask["head"] == "Which cache layout should the fetcher use?", ask)
    check(ask["age"] == "now", f"an ask raised moments ago is aged from its own time: {ask}")
    check(find["head"] == "The retry loop in fetch.py has no jitter.", find)
    review = find_row(c, "Review", "Groups review demo")
    check(review["head"].startswith("## Retry budget is now per host"), review)

    # The headline counts what needs the owner and what the read covered. The
    # running sessions are this scenario's own and are counted exactly; saved
    # sessions that earlier scenarios left in the catalogue add to the total,
    # which the headline must then name as read from the catalogue.
    inbox = c.app.snap()["inbox"]
    headline = inbox["headline"]
    check(inbox["liveNeeding"] == 3 and inbox["liveFinds"] == 1, inbox)
    check(headline.startswith(f"{inbox['needing']} need you"), headline)
    check(inbox["needing"] >= inbox["liveNeeding"], inbox)
    check("5 running sessions read live" in headline, headline)
    if inbox["fromCatalogue"] > 0:
        check(f"{inbox['fromCatalogue']} saved from the catalogue" in headline, headline)
    else:
        check(inbox["needing"] == inbox["liveNeeding"], inbox)

    # Each folder's count is the number of rows its band draws.
    snapshot = c.app.snap()["inbox"]
    counts = {g["title"]: g["count"] for g in snapshot["groups"]}
    check(snapshot["folders"][0] == {"title": "Everything, by need", "count": -1}, snapshot["folders"])
    for folder in snapshot["folders"][1:]:
        check(counts[folder["title"]] == folder["count"], f"{folder} against {counts}")
    check([f["title"] for f in snapshot["folders"][1:]] == ["Needs you", "To review", "Finds"], snapshot["folders"])

    # A folder narrows the list to its band, and Everything draws every band again.
    c.app.cmd("inboxfolder Needs you")
    wait_for(lambda: c.app.snap()["inbox"]["drawn"] == ["Needs you", f"Needs you \u00b7 {counts['Needs you']}"], 5, "the list narrowed to Needs you")
    c.app.cmd("inboxfolder Finds")
    wait_for(lambda: c.app.snap()["inbox"]["drawn"] == ["Finds", "Finds \u00b7 1"], 5, "the list narrowed to Finds")
    c.app.cmd("inboxfolder Everything, by need")
    wait_for(lambda: c.app.snap()["inbox"]["drawn"][0] == "Everything, by need" and len(c.app.snap()["inbox"]["drawn"]) > 3, 5, "every band to draw again")

    # A folder whose band empties is no longer offered, and the list falls back to Everything.
    c.app.cmd("inboxfolder Finds")
    wait_for(lambda: c.app.snap()["inbox"]["drawn"][0] == "Finds", 5, "the Finds folder")
    wait_for(lambda: c.app.snap()["inbox"]["open"] == find["id"], 5, "the find to open as the folder's first thread")
    c.app.press("Dismiss")
    wait_for(lambda: not find_row(c, "Risk"), 30, "the dismissed find to leave the list")
    wait_for(lambda: c.app.snap()["inbox"]["drawn"][0] == "Everything, by need", 10, "the list to fall back to Everything")
    check("Finds" not in [f["title"] for f in c.app.snap()["inbox"]["folders"]], "an empty band should not be offered as a folder")


# One thread of each kind.


@scenario("AI-11", "AI-27")
def an_approval_thread_lays_out_its_evidence(c):
    """The pane for an approval names the tool, the command, what held it, the network and the policy, over the live card."""
    repo = fresh_repo("inbox-approval")
    c.app.dispatch("Evidence escalate", repo)
    c.app.go("inbox")
    row = wait_row(c, "Approval", "Evidence escalate", 60)
    open_thread(c, row)
    c.app.see(r"^May this program run .* with write access to /Users/Shared/loom-desktop-escalation-test\?$", 20)
    texts = tree_texts(c)
    start = position(texts, "Tool")
    expected = [
        ("Tool", "fs_write"),
        ("Held by", "policy: This invocation requests additional sandbox authority."),
        ("Network", "on"),
        ("Wants", "writable_root /Users/Shared/loom-desktop-escalation-test"),
        ("Policy today", "workspace-write \u00b7 network on"),
    ]
    for label, value in expected:
        at = position(texts, label, start)
        check(texts[at + 1].strip() == value, f"{label} should read {value!r}, found {texts[at + 1]!r}")
        start = at
    check(any(t.strip().startswith('{"content":"hello"') for t in texts), "the command row is missing")
    check(any(t.startswith("Evidence escalate") and "waiting since" in t for t in texts), "the eyebrow should date the wait")

    # The card that decides is under the evidence, and the answers read Deny, then Allow.
    check(position(texts, "DECIDE") > position(texts, "Policy today"), "the card should come after the evidence")
    check(position(texts, "Deny") < position(texts, "Allow"), "Deny should come first")

    # The session's own page words the same card from the same read.
    c.app.open_session("Evidence")
    c.app.see(r"^waiting since \d\d:\d\d", 20)
    c.app.see(r"^Network on$")
    c.app.see(r"^Policy today: workspace-write \u00b7 network on$")
    wait_for(lambda: c.app.enabled("Allow"), 5, "Allow to arm")
    c.app.press("Allow")
    wait_for(lambda: not c.app.session()["escalations"], 15, "the approval to clear")


@scenario("AI-10", "AI-13")
def a_stuck_strand_is_read_and_retried_from_its_pane(c):
    """A strand stopped on a failed run reads in its own pane, and Retry runs it again so it leaves the list."""
    repo = fresh_repo("inbox-stuck")
    stuck_session(c, "Stuck host", repo)
    c.app.go("inbox")
    row = wait_row(c, "Stuck", "Stuck host")
    check(row["head"] == "Stopped on a failed run", row)
    open_thread(c, row)
    c.app.see(r"^The last turn failed, and nothing has retried\.$", 10)
    c.app.see(r"^The last turn failed at \d\d:\d\d; nothing has retried\.$", 10)
    c.app.see(r"^Stuck host .* branch-two \u00b7 failed \d\d:\d\d$", 5)
    wait_for(lambda: c.app.enabled("Retry"), 10, "Retry to be offered")
    c.app.press("Retry")
    wait_for(lambda: not find_row(c, "Stuck"), 60, "the retried strand to leave the list")


@scenario("AI-10", "AI-14")
def a_find_is_read_and_closed_from_its_pane(c):
    """A find reads with its full text and its place, and Filed closes it so it leaves the list."""
    repo = fresh_repo("inbox-find")
    c.app.dispatch("Noted noticefind", repo)
    c.app.go("inbox")
    row = wait_row(c, "Risk", "Noted noticefind")
    open_thread(c, row)
    c.app.see(r"^The agent noticed \(risk\), untrusted text$", 10)
    c.app.see(r"^The retry loop in fetch\.py has no jitter\.$", 5)
    c.app.see(r"^fetch\.py:7$", 5)
    for label in ("Fixed", "Filed", "Dismiss"):
        wait_for(lambda: c.app.enabled(label), 10, f"{label} to be offered")
    c.app.press("Filed")
    wait_for(lambda: not find_row(c, "Risk"), 30, "the closed find to leave the list")


@scenario("AI-10", "AI-12", "AI-40")
def an_ask_is_read_and_answered_in_its_pane(c):
    """An ask reads with its questions and options, and Send answers names the first question left open and sends nothing, then the owner's answers end the ask."""
    repo = fresh_repo("inbox-ask")
    c.app.dispatch("Asking askowner", repo)
    c.app.go("inbox")
    row = wait_row(c, "Ask", "Asking askowner")
    open_thread(c, row)
    c.app.see(r"^The agent asks, untrusted text$", 10)
    c.app.see(r"^the cache layout is the owner's call$", 5)
    for words in ("Which cache layout should the fetcher use?", "Per host, recommended", "Shared", "May the fetcher drop expired entries early?"):
        c.app.see("^" + re.escape(words) + "$", 5)
    c.app.not_see(r"^Allow$")

    # The owner has controls, and Send waits until every question has an entry.
    c.app.see(r"^Other\u2026$", 10)
    c.app.press("Send answers")
    c.app.see(r"^Answer this question\.$", 5)
    check(find_row(c, "Ask", "Asking askowner") is not None, "an unanswered form must send nothing")
    c.app.press("Shared")
    c.app.press("Yes")
    c.app.not_see(r"^Answer this question\.$")
    c.app.press("Send answers")
    wait_for(lambda: find_row(c, "Ask", "Asking askowner") is None, 60, "the answered ask to leave the inbox")


# The review thread.


@scenario("AI-10", "AI-28", "AI-29", "AI-30", "AI-32", needs_display=True)
def a_review_thread_opens_on_the_first_file_and_sends_through_the_outbox(c):
    """A finished session's pane opens its first file with the find pinned to its line, and Send closes the find and delivers one prompt."""
    repo = fresh_repo("inbox-review")
    sid = c.app.dispatch("Reviewing demo", repo)
    c.app.open_session("Reviewing")
    settle(c)
    c.app.prompt(sid, "now noticefind")
    wait_for(lambda: not c.app.session()["isBusy"] and any("noted the risk" in t for t in c.app.session()["transcript"]), 40, "the second turn to end")
    c.app.go("inbox")
    review = wait_row(c, "Review", "Reviewing demo", 90)
    wait_row(c, "Risk", "Reviewing demo")
    check(review["group"] == "To review", review)
    open_thread(c, review)

    # The title and the pills carry the size, and the first file is open with numbered hunks.
    c.app.see(r"^Ready to review: \+12 \u22120 across 1 file$", 30)
    texts = tree_texts(c)
    check("+12" in texts and "\u22120" in texts and "1 file" in texts, "the count pills are missing")
    check(any(t.startswith("last command: python3") and t.endswith("exit 0") for t in texts), "the last command should be named")
    check(any(t.startswith("fetch.py, added, +12") for t in texts), "the file's line should name how it changed")
    check("@@ -0,0 +1,12 @@" in texts, "the first file should be open on its hunk")

    # The find sits under the line it names, so the pane has no separate list for it.
    at7 = position(texts, "for attempt in range(budget):")
    pinned = position(texts, "fetch.py:7")
    after = position(texts, "try:")
    check(at7 < pinned < after, f"the find should sit between lines 7 and 8: {at7} {pinned} {after}")
    check("The agent noticed (risk), untrusted text" in texts, "the find should be labelled as the agent's")
    check(not any(t.startswith("NOTICED ALONG THE WAY") for t in texts), "a pinned find should not be listed apart")

    # Nothing is staged until a person stages it.
    c.app.see(r"^Not sent\.$", 5)
    check(not c.app.enabled("Send"), "Send should wait for something staged")
    c.app.press("Approve")
    c.app.see(r"^To Reviewing demo \u00b7 1 staged\.$", 5)
    wait_for(lambda: c.app.enabled("Send"), 5, "Send to arm")

    # Pressing the verdict again takes it back.
    c.app.press("Approve")
    c.app.see(r"^Not sent\.$", 5)
    c.app.press("Request changes")
    c.app.see(r"^Verdict: changes requested$", 5)
    c.app.press("Dismiss")
    c.app.see(r"^Close find-\w+ as dismissed$", 5)
    c.app.see(r"^To Reviewing demo \u00b7 2 staged\.$", 5)

    # Clear takes back everything staged.
    c.app.press("Clear")
    c.app.see(r"^Not sent\.$", 5)
    c.app.not_see(r"^Verdict: ")
    c.app.press("Approve")
    c.app.press("Dismiss")
    c.app.see(r"^To Reviewing demo \u00b7 2 staged\.$", 5)
    c.app.shot(c.out / "inbox" / "review-thread-open.png")

    # Send closes the find at the revision read, then delivers one prompt.
    c.app.press("Send")
    c.app.see(r"^Sent\.$", 30)
    wait_for(lambda: not find_row(c, "Risk"), 30, "the closed find to leave the list")
    c.app.open_session("Reviewing")
    c.app.transcript_has(r"I reviewed your changes\. Verdict: approved\.", 30)
    c.app.transcript_has(r"Finds I closed:", 5)


# The session page.


@scenario("AI-21", "AI-22", "AI-25", needs_display=True)
def the_session_page_lifts_what_waits_and_dates_its_rows(c):
    """The page lifts a stuck strand and a find into a rail whose buttons act, an observer is not offered them, and rows carry clock times."""
    repo = fresh_repo("inbox-rail")
    sid = c.app.dispatch("Rail noticefind", repo)
    c.app.open_session("Rail")
    settle(c)
    run_command(c, "/fork branch-two")
    name = wait_for(lambda: next((x for x in c.app.session()["strands"] if "branch-two" in x), None), 10, "the forked strand")
    c.app.cmd(f"strand {name}")
    wait_for(lambda: c.app.session()["focusedStrand"] == name, 5, "focus on the fork")
    c.app.prompt(sid, "run it and explode now")
    c.app.press("Inspector")
    c.app.see(r"^Lifted from this session$", 60)
    c.app.see(r"^Needs you \u00b7 1$", 60)
    c.app.see(r"^Insights \u00b7 1$", 60)
    c.app.see(r"^1 needs you", 5)
    c.app.see(r"^\d\d:\d\d \u00b7 branch-two$", 5)
    c.app.see(r"^The retry loop in fetch\.py has no jitter\.$", 5)
    c.app.see(r"^Stopped on a failed run$", 5)

    # The transcript's rows carry the time the daemon recorded for them.
    texts = c.app.texts()
    check(sum(1 for t in texts if len(t.strip()) == 5 and t.strip()[2] == ":" and t.strip().replace(":", "").isdigit()) >= 2, "rows should carry clock times in the gutter")

    # An observer reads the rail and is offered no button.
    c.app.cmd("asrole observer")
    c.app.see(r"^You are watching, so the buttons are not offered\.$", 10)
    check(not any(t == "Retry the last step" for t in c.app.texts()) and not c.app.enabled("Retry the last step") and not c.app.enabled("Dismiss"), "an observer should have no buttons")
    c.app.cmd("asrole none")
    c.app.not_see(r"^You are watching")

    # The owner's buttons act: Dismiss closes the find, and Retry runs the strand again.
    wait_for(lambda: c.app.enabled("Dismiss"), 10, "Dismiss to be offered")
    c.app.press("Dismiss")
    c.app.see(r"^Dismissed the find\.$", 20)
    c.app.not_see(r"^Insights \u00b7 1$")
    wait_for(lambda: c.app.enabled("Retry the last step"), 10, "Retry to be offered")
    c.app.press("Retry the last step")
    wait_for(lambda: not any(t == "Needs you \u00b7 1" for t in c.app.texts()), 60, "the stuck strand to leave the rail")


@scenario("AI-23", "AI-40", "AI-42", needs_display=True)
def an_ask_is_answered_from_the_session_pages_rail(c):
    """The page lifts an ask into its rail, Answer opens the same questions in the row, and sending them ends the ask."""
    repo = fresh_repo("inbox-rail-ask")
    c.app.dispatch("Rail askowner", repo)
    c.app.open_session("Rail")
    settle(c)
    c.app.press("Inspector")
    c.app.see(r"^Lifted from this session$", 60)
    c.app.see(r"^Needs you \u00b7 1$", 60)
    wait_for(lambda: c.app.enabled("Answer\u2026"), 20, "Answer to be offered")

    # An observer reads the row and is offered no way to answer.
    c.app.cmd("asrole observer")
    wait_for(lambda: "Answer\u2026" not in tree_texts(c), 10, "the Answer control to go")
    c.app.cmd("asrole none")
    wait_for(lambda: c.app.enabled("Answer\u2026"), 10, "Answer to return for the owner")
    c.app.press("Answer\u2026")
    c.app.see(r"^Which cache layout should the fetcher use\?$", 20)
    c.app.press("Per host, recommended")
    c.app.press("No")
    c.app.press("Send answers")
    wait_for(lambda: not any(t == "Needs you \u00b7 1" for t in c.app.texts()), 60, "the answered ask to leave the rail")


@scenario("AI-23", "AI-40", needs_display=True)
def an_ask_is_answered_from_the_card_above_the_composer(c):
    """An open ask has a card above the composer with the Inspector closed, an observer reads it without a form, sending the answer removes the card, and the transcript shows the answer as numbered, indented lines."""
    repo = fresh_repo("inbox-card-ask")
    c.app.dispatch("Card askowner", repo)
    c.app.open_session("Card")
    settle(c)
    check(not c.app.snap()["showsInspector"], "the Inspector should start closed")

    # The card says when the ask was raised and by whom, and the turn that raised it is marked.
    c.app.see(r"^Ask \u00b7 waiting since \d\d:\d\d \u00b7 main$", 60)
    c.app.see(r"^Which cache layout should the fetcher use\?$", 20)
    c.app.see(r"asked a question", 5)

    # An observer reads the questions and is offered no form.
    c.app.cmd("asrole observer")
    wait_for(lambda: "Send answers" not in tree_texts(c), 10, "the form to go for an observer")
    c.app.see(r"^Only the owner or an operator can answer an ask\.$", 5)
    c.app.see(r"^Which cache layout should the fetcher use\?$", 5)
    c.app.cmd("asrole none")
    wait_for(lambda: c.app.enabled("Send answers"), 10, "the form to return for the owner")

    # Sending settles the ask, and the card leaves with the Inspector still closed.
    c.app.press("Shared")
    c.app.press("No")
    c.app.press("Send answers")
    wait_for(lambda: not any(t.startswith("Ask \u00b7 waiting since") for t in c.app.texts()), 60, "the answered ask's card to leave")
    check(not c.app.snap()["showsInspector"], "answering must not open the Inspector")

    # The daemon words the answer as text, each question numbered with its answer indented under it.
    def answer_row():
        return next((t for t in c.app.session()["transcript"] if t.startswith("Answer to your ask")), None)

    text = wait_for(answer_row, 40, "the answer in the transcript")
    check('1. Which cache layout should the fetcher use?\n   "Shared"' in text, repr(text))
    check("2. May the fetcher drop expired entries early?\n   No" in text, repr(text))
    check("```" not in text and '"answers"' not in text, "the answer should not be a JSON record: " + repr(text))
    shown = [t for t in c.app.texts() if t.startswith("Answer to your ask")]
    check(shown and "\n   " in shown[0], f"the drawn message should keep its lines and indent: {shown!r}")


@scenario("AI-08")
def saved_sessions_are_counted_from_the_catalogue(c):
    """With a saved session in the list, the headline and the rail's note say the counts came from the catalogue's summary."""
    repo = fresh_repo("inbox-saved")
    c.app.dispatch("Saved first", repo)
    c.app.cmd("stopall")
    c.app.dispatch("Saved second hang", repo)
    c.app.go("inbox")
    wait_for(lambda: "catalogue" in c.app.snap()["inbox"]["note"], 90, "the note to name the catalogue")
    check("not checked" not in c.app.snap()["inbox"]["note"], c.app.snap()["inbox"]["note"])


@scenario("AI-10")
def a_working_session_reads_as_an_update_and_offers_queue_and_steer(c):
    """A session that is working reads in its pane as an update, and the message bar offers Queue and Steer in place of Send."""
    repo = fresh_repo("inbox-update")
    c.app.dispatch("Working hang", repo)
    c.app.go("inbox")
    row = wait_row(c, "Update", "Working hang", 60)
    check(row["group"] == "Updates", row)
    open_thread(c, row)
    c.app.see(r"^Update$", 10)
    c.app.see(r"^Working hang \u00b7 .*", 5)
    texts = tree_texts(c)
    check("Queue" in texts and "Steer" in texts, f"a working session takes a queue and a steer: {texts[-8:]}")
    check("Send" not in texts, "a working session has no plain Send")
    check("Open Session" in texts, "the pane should lead to the session")


# One count.


@scenario("HM-22", "AI-01")
def an_ask_only_session_is_counted_by_every_surface(c):
    """A session whose only open item is an ask raises the sidebar badge, the subtitle, the Dock tile and the headline together, and leads the sidebar."""
    # Saved sessions that earlier scenarios left in the catalogue move the whole count
    # as the catalogue is read, so the running sessions' part is what this one adds to.
    before = c.app.snap()["inbox"]["liveNeeding"]
    repo = fresh_repo("inbox-count")
    sid = c.app.dispatch("Count ask askowner", repo)
    c.app.go("inbox")
    wait_row(c, "Ask", "Count ask askowner")
    wait_for(lambda: c.app.snap()["inbox"]["liveNeeding"] == before + 1, 10, "the board to count the ask")

    def agree():
        inbox = c.app.snap()["inbox"]
        s = inbox["surfaces"]
        n = inbox["needing"]
        return (
            s["sidebarBadge"] == n and s["menuBar"] == n and s["dockBadge"] == str(n)
            and s["windowSubtitle"] == f"{n} waiting" == s["boardSubtitle"]
            and inbox["headline"].startswith(f"{n} need") and sid in s["needingSessions"] and sid in s["sidebarNeedsYou"]
        ) or None

    wait_for(agree, 10, "every surface to show the same count")

    # The ask-only session is listed once, under Needs you, and not again under Folded.
    snapshot = c.app.snap()["inbox"]
    named = [g["title"] for g in snapshot["groups"] for r in g["rows"] if r["name"] == "Count ask askowner"]
    check(named == ["Needs you"], f"the session should be listed only under Needs you: {named}")


@scenario(needs_display=True, foreground=True)
def the_session_menu_decides_only_the_armed_card_in_view(c):
    """Allow in the Session menu names the tool, works from the inbox's approval pane once armed, and does nothing away from the card."""
    repo = fresh_repo("inbox-menu")
    c.app.dispatch("Menu pane escalate", repo)
    c.app.go("inbox")
    row = wait_row(c, "Approval", "Menu pane escalate", 60)

    # A focused value reaches the menu only in an active app's key window.
    c.app.take_focus()

    # Away from any card the three items are disabled and the command acts on nothing.
    c.app.go("mission")
    wait_for(lambda: c.app.menu_state("Allow Request") == "disabled", 5, "Allow to be disabled on Mission Control")
    check(c.app.menu_state("Deny Request") == "disabled", "Deny should be disabled with no card in view")
    c.app.cmd("menu Allow Request")
    time.sleep(1)
    check(find_row(c, "Approval", "Menu pane escalate"), "the request must stay pending")

    # In the inbox's pane the card publishes itself once armed, and the titles name the tool.
    c.app.go("inbox")
    open_thread(c, row)
    try:
        wait_for(lambda: c.app.menu_state("Allow fs_write") == "enabled", 10, "Allow fs_write to follow the armed card")
    except Exception:
        c.app.cmd("state")
        print((c.app.dir / "state.txt").read_text(), flush=True)
        raise
    check(c.app.menu_state("Deny fs_write") == "enabled", "Deny should name the tool and be enabled")
    c.app.menu("Allow fs_write")
    wait_for(lambda: not find_row(c, "Approval", "Menu pane escalate"), 20, "the approval to clear")
    wait_for(lambda: c.app.menu_state("Allow Request") == "disabled", 10, "the item to be disabled once the card is gone")


# Commands and the keyboard.


def drawn_ids(c):
    """The ids of the selectable rows, in the order the list draws them."""
    return [r["id"] for r in rows(c) if r["group"] != "Folded"]


@scenario()
def next_and_previous_step_through_the_list_as_drawn_and_stop_at_the_ends(c):
    """Next and previous move the open thread through the drawn rows, never wrap, and a row's context menu offers only what applies and never a decision."""
    repo = fresh_repo("inbox-commands")
    c.app.dispatch("Cmd approval escalate", repo)
    c.app.dispatch("Cmd ask askowner", repo)
    c.app.dispatch("Cmd note noticefind", repo)
    c.app.go("inbox")
    approval = wait_row(c, "Approval", "Cmd approval escalate")
    ask = wait_row(c, "Ask", "Cmd ask askowner")
    find = wait_row(c, "Risk", "Cmd note noticefind")

    ids = drawn_ids(c)
    check(len(ids) >= 3, f"three threads should be listed: {ids}")
    open_thread(c, {"id": ids[0]})

    # Stepping forward visits each row in order, and past the last it stays.
    for expected in ids[1:]:
        c.app.cmd("inboxstep next")
        wait_for(lambda: c.app.snap()["inbox"]["open"] == expected, 5, f"next to open {expected}")
    c.app.cmd("inboxstep next")
    time.sleep(0.5)
    check(c.app.snap()["inbox"]["open"] == ids[-1], "next wrapped past the last row")

    # And back again, stopping at the first.
    for expected in reversed(ids[:-1]):
        c.app.cmd("inboxstep previous")
        wait_for(lambda: c.app.snap()["inbox"]["open"] == expected, 5, f"previous to open {expected}")
    c.app.cmd("inboxstep previous")
    time.sleep(0.5)
    check(c.app.snap()["inbox"]["open"] == ids[0], "previous wrapped past the first row")

    # Every row's context menu draws the same actions the menu does, minus navigation and decisions.
    menus = c.app.snap()["inbox"]["contextMenus"]
    for row in (approval, ask, find):
        check("Open Session" in menus[row["id"]] and "Open in New Window" in menus[row["id"]], f"{row['id']}: {menus[row['id']]}")
        check(not any(t.startswith(("Allow", "Deny", "Next", "Previous")) for t in menus[row["id"]]), f"{row['id']}: {menus[row['id']]}")
    for row in (approval, ask, find):
        check(not any(t.startswith(("Close Find", "Retry", "Dismiss")) for t in menus[row["id"]]), f"{row['id']}: a row's menu acts on no unopened thread")


@scenario("AI-10", needs_display=True, foreground=True)
def the_inbox_menu_follows_the_open_thread_and_a_thread_opens_in_its_own_window(c):
    """The Inbox menu's Next and Previous are disabled at the ends, Close Find is offered for a find only, and Open in New Window gives the thread a window of its own."""
    repo = fresh_repo("inbox-menu-commands")
    c.app.dispatch("Menu ask askowner", repo)
    c.app.dispatch("Menu note noticefind", repo)
    c.app.go("inbox")
    ask = wait_row(c, "Ask", "Menu ask askowner")
    find = wait_row(c, "Risk", "Menu note noticefind")
    c.app.take_focus()

    ids = drawn_ids(c)
    open_thread(c, {"id": ids[0]})
    wait_for(lambda: c.app.menu_state("Previous Thread") == "disabled", 10, "Previous to be disabled on the first row")
    check(c.app.menu_state("Next Thread") == "enabled", "Next should be enabled on the first row")
    c.app.menu("Next Thread")
    wait_for(lambda: c.app.snap()["inbox"]["open"] == ids[1], 5, "the menu's Next to open the second row")
    wait_for(lambda: c.app.menu_state("Previous Thread") == "enabled", 10, "Previous to be enabled on the second row")

    # Close Find follows the kind: a find offers it and an ask does not.
    open_thread(c, find)
    wait_for(lambda: c.app.menu_state("Dismiss Find") == "enabled", 10, "Dismiss Find to be offered on a find")
    open_thread(c, ask)
    wait_for(lambda: c.app.menu_state("Dismiss Find") == "disabled", 10, "Dismiss Find to be off on an ask")
    check(c.app.menu_state("Message Session") == "enabled", "Message Session should be offered on an ask")
    check(c.app.menu_state("Deny Request") == "disabled", "Deny should stay disabled with no approval card")

    # Open in New Window puts the thread in a window of its own, named for its session.
    c.app.menu("Open in New Window")

    def windows():
        c.app.cmd("state")
        return (c.app.dir / "state.txt").read_text()

    wait_for(lambda: "Menu ask askowner|" in windows(), 10, "a window of its own for the thread")


# Notifications.


@scenario("AI-45")
def a_notification_plans_for_an_ask_and_a_click_opens_its_thread(c):
    """A new ask is planned as a notice, a click on it opens its thread in the inbox, and answering the ask plans its removal."""
    repo = fresh_repo("inbox-notice")

    # An ask raised before the session's first feed read is taken as backlog, so the
    # session is made first and asked only once the feed has answered for it.
    sid = c.app.dispatch("Noticed session", repo)
    wait_for(lambda: sid in c.app.snap()["notices"]["checked"], FEED_WAIT, "the feed to answer for the session")
    c.app.prompt(sid, "askowner")
    row = wait_row(c, "Ask", "Noticed session")
    notice = "ask/" + row["id"]
    wait_for(lambda: notice in c.app.snap()["notices"]["posted"], 30, "the ask to be planned as a notice")

    # A click on the notification opens the thread, from any other page.
    c.app.go("mission")
    c.app.cmd("noticeclick " + row["id"])
    wait_for(lambda: c.app.snap()["inbox"]["open"] == row["id"], 10, "the click to open the ask's thread")
    c.app.see(r"^The agent asks, untrusted text$", 10)

    # Nothing in the notification decides: the thread's own controls do.
    c.app.press("Shared")
    c.app.press("Yes")
    c.app.press("Send answers")
    wait_for(lambda: find_row(c, "Ask", "Noticed session") is None, 60, "the answered ask to leave the inbox")
    wait_for(lambda: notice in c.app.snap()["notices"]["removed"], 30, "the notice to be removed")
