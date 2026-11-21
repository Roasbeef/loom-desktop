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
    """At the narrowest window the folder rail gives way to a toolbar menu and the reading pane keeps its floor, and a wide window has the rail and a wider pane."""
    repo = fresh_repo("inbox-width")
    c.app.dispatch("Width approval escalate", repo)
    c.app.go("inbox")
    wait_row(c, "Approval", "Width approval escalate")
    try:
        c.app.resize(880, 560)
        wait_for(lambda: c.app.snap()["inbox"]["folderControl"] == "menu", 5, "the rail to give way to the menu")
        narrow = c.app.snap()["inbox"]["paneWidth"]
        check(narrow >= 340, f"the reading pane is {narrow} pt wide at 880 pt, under the 340 pt floor")
        check(not c.app.fully_on_screen("Folder Everything, by need"), "the rail should not be drawn at the narrowest window")
        c.app.resize(1400, 900)
        wait_for(lambda: c.app.snap()["inbox"]["folderControl"] == "rail", 5, "the rail to return")
        wide = c.app.snap()["inbox"]["paneWidth"]
        check(wide >= 420, f"the reading pane is {wide} pt wide at 1400 pt, under the 420 pt readable width")
        wait_for(lambda: c.app.fully_on_screen("Folder Everything, by need"), 5, "the rail's folders on screen")
    finally:
        c.app.resize(1400, 900)


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
    c.app.press("Folder Needs you")
    wait_for(lambda: c.app.snap()["inbox"]["drawn"] == ["Needs you", f"Needs you \u00b7 {counts['Needs you']}"], 5, "the list narrowed to Needs you")
    c.app.press("Folder Finds")
    wait_for(lambda: c.app.snap()["inbox"]["drawn"] == ["Finds", "Finds \u00b7 1"], 5, "the list narrowed to Finds")
    c.app.press("Folder Everything, by need")
    wait_for(lambda: c.app.snap()["inbox"]["drawn"][0] == "Everything, by need" and len(c.app.snap()["inbox"]["drawn"]) > 3, 5, "every band to draw again")

    # A folder whose band empties is no longer offered, and the list falls back to Everything.
    c.app.press("Folder Finds")
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
    wait_for(lambda: c.app.menu_state("Allow fs_write") == "enabled", 10, "Allow fs_write to follow the armed card")
    check(c.app.menu_state("Deny fs_write") == "enabled", "Deny should name the tool and be enabled")
    c.app.menu("Allow fs_write")
    wait_for(lambda: not find_row(c, "Approval", "Menu pane escalate"), 20, "the approval to clear")
    wait_for(lambda: c.app.menu_state("Allow Request") == "disabled", 10, "the item to be disabled once the card is gone")
