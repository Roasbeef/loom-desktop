"""Scenarios for typed commands, the composer's lines, and the transcript's rarer rows.

They run in the same cluster as the others and follow the same rules: assert what a
person would see, and wait on a condition and never on a bare sleep. Scenarios that
need the inspector's tabs carry `needs_display`, since a locked screen never lays those
tabs out.
"""
import re
import time

from loomui import wait_for
from scenarios import WORKSPACE, check, fold_titles, name_starting, pending_approval, run_command, scenario, settle


def say(c, text):
    """Types a line into the composer and presses Return, with no wait for a notice."""
    c.app.type(text)
    wait_for(lambda: c.app.session()["draft"] == text, 3, "the typed line")
    if c.app.session()["slashRows"]:
        c.app.key("escape")
    c.app.key("return")


def first_escalation(c):
    return wait_for(lambda: c.app.session()["escalations"], 40, "an approval")[0]


# The composer's lines.


@scenario("CO-07", "CO-10")
def the_composer_says_whom_it_addresses_and_who_it_is(c):
    """The editor names the addressed strand above it, and the footer names who the window acts as."""
    c.app.dispatch("Addressing please", WORKSPACE)
    c.app.open_session("Addressing please")
    settle(c)
    check(c.app.session()["to"] == "main", c.app.session()["to"])
    c.app.see(r"^To main$")
    who = wait_for(lambda: c.app.session()["who"], 10, "who the window acts as")
    check(who.endswith("· owner"), f"the role should follow the name: {who!r}")
    c.app.see(r"Acting as.*owner")
    run_command(c, "/fork branch-b")
    name = wait_for(lambda: next((x for x in c.app.session()["strands"] if "branch-b" in x), None), 10, "the forked strand")
    c.app.cmd(f"strand {name}")
    wait_for(lambda: c.app.session()["to"] == "branch-b", 5, "the addressee to follow the strand")
    c.app.see(r"^To branch-b$")


# Typed commands.


@scenario("CO-34")
def typed_approve_allows_a_request(c):
    """/approve with the start of an id allows that request, as the button does."""
    pending_approval(c, "Typed allow")
    ident = first_escalation(c)
    say(c, f"/approve {ident}")
    wait_for(lambda: not c.app.session()["escalations"], 15, "the approval to clear")
    c.app.transcript_has("decision approved", 15)
    check(not c.app.session()["noticeIsWarning"], c.app.session()["notice"])


@scenario("CO-35")
def typed_deny_refuses_a_request(c):
    """/deny with the start of an id denies that request, and one that matches nothing says so."""
    pending_approval(c, "Typed deny")
    ident = first_escalation(c)
    note = run_command(c, "/deny zzzz")
    check(c.app.session()["noticeIsWarning"] and "zzzz" in note, note)
    check(c.app.session()["escalations"], "a request that matched nothing must stay pending")
    say(c, f"/deny {ident}")
    wait_for(lambda: not c.app.session()["escalations"], 15, "the approval to clear")
    c.app.transcript_has("decision rejected", 15)


@scenario("CO-33")
def approvals_command_lists_the_answers(c):
    """/approvals lists the requests that were answered, and one id names one answer."""
    pending_approval(c, "Ledger words")
    ident = first_escalation(c)
    check("No request has been answered" in run_command(c, "/approvals"), "nothing is answered yet")
    say(c, f"/approve {ident}")
    wait_for(lambda: not c.app.session()["escalations"], 15, "the approval to clear")
    listed = run_command(c, "/approvals")
    check("Allowed" in listed, f"the list should say what was answered: {listed!r}")
    check(ident in listed, f"the list should name the id: {listed}")
    one = run_command(c, f"/approvals {ident}")
    check(one.startswith("Allowed") and "\n" not in one, one)
    check("No answered request" in run_command(c, "/approvals ffff"), "an unknown id is said plainly")


@scenario("CO-39")
def clear_hides_the_window_and_keeps_the_session(c):
    """/clear empties this window's transcript, and what comes after still shows."""
    sid = c.app.dispatch("Clear me demo", WORKSPACE)
    c.app.open_session("Clear me")
    c.app.transcript_has("Retry budget", 40)
    settle(c)
    check(c.app.session()["blocks"] > 2, "the run should have left several rows")
    note = run_command(c, "/clear")
    wait_for(lambda: c.app.session()["blocks"] == 0, 10, "the transcript to empty")
    check("session still holds" in note, note)
    c.app.not_see("Retry budget is now per host")
    c.app.prompt(sid, "after the clear")
    c.app.transcript_has("after the clear", 20)
    settle(c)
    check(not any("Retry budget" in t for t in c.app.session()["transcript"]), "cleared rows must not return")
    check(not c.app.session()["hasOlder"], "a cleared window offers no older turns")


@scenario("CO-32")
def unschedule_retires_a_schedule(c):
    """/unschedule with a schedule's name retires it, and /schedules no longer lists it."""
    sid = c.app.dispatch("Retire heartbeat", WORKSPACE)
    c.app.open_session("Retire heartbeat")
    c.app.transcript_has("heartbeat is scheduled", 40)
    settle(c)
    listed = run_command(c, "/schedules")
    check("heartbeat" in listed, listed)
    note = run_command(c, "/unschedule heartbeat")
    check(note.startswith("Retired heartbeat") and not c.app.session()["noticeIsWarning"], note)
    wait_for(lambda: "No schedules" in run_command(c, "/schedules"), 15, "the schedule to leave the list")


@scenario("CO-37")
def side_question_commands_cancel_refresh_and_clear(c):
    """/btw cancel stops a running side question, and refresh, clear and close follow."""
    c.app.dispatch("Side commands", WORKSPACE)
    c.app.open_session("Side commands")
    settle(c)
    c.app.type("/btw hang while I ask")
    c.app.key("escape")
    c.app.key("return")
    wait_for(lambda: c.app.session()["btwStatus"] == "running", 15, "the side question to run")
    c.app.press("Close Side Question")
    say(c, "/btw cancel")
    wait_for(lambda: c.app.session()["btwStatus"] not in ("running", ""), 15, "the cancel to settle")
    after_cancel = c.app.session()["btwStatus"]
    check(after_cancel in ("cancelled", "canceled", "failed", "idle"), f"cancel left {after_cancel!r}")
    c.app.press("Close Side Question")
    say(c, "/btw clear")
    wait_for(lambda: c.app.session()["btwStatus"] != "running" and not any("hang while I ask" in t for t in c.app.texts()), 10, "clear to empty the panel")
    c.app.press("Close Side Question")
    say(c, "/btw close")
    wait_for(lambda: not c.app.session()["btwStatus"], 10, "close to hide the panel")


@scenario("CO-17", "TR-32")
def compact_cuts_the_conversation_and_says_so(c):
    """/compact on a conversation with something to cut leaves a compaction row in the transcript."""
    sid = c.app.dispatch("Compact for real demo", WORKSPACE)
    c.app.open_session("Compact for real")
    c.app.transcript_has("Retry budget", 40)
    settle(c)
    c.app.prompt(sid, "tell me again")
    wait_for(lambda: sum("Retry budget" in t for t in c.app.session()["transcript"]) >= 1, 20, "the second reply")
    settle(c)
    note = run_command(c, "/compact")
    check(not c.app.session()["noticeIsWarning"], note)
    wait_for(lambda: any(t == "Earlier conversation compacted." for t in c.app.session()["transcript"]), 40, "the compaction row")


@scenario("CO-24")
def profile_switch_moves_the_session(c):
    """/profile names the profiles on offer, switches to one, and /profile default returns."""
    c.app.dispatch("Profile switch", WORKSPACE)
    c.app.open_session("Profile switch")
    settle(c)
    shown = run_command(c, "/profile")
    check("review" in shown, f"the cluster defines a review profile: {shown}")
    note = run_command(c, "/profile review")
    check(not c.app.session()["noticeIsWarning"], note)
    wait_for(lambda: c.app.session().get("profile") == "review" or "review" in run_command(c, "/profile"), 40, "the session to use the profile")
    c.app.open_session("Profile switch")
    wait_for(lambda: c.app.session().get("isLive") and c.app.session().get("isAdopted"), 60, "the session to come back")
    c.app.focus("Message")
    back = run_command(c, "/profile default")
    check(not c.app.session()["noticeIsWarning"], back)


# The prompt cache.


@scenario("CO-11", "TR-30")
def cache_outlook_and_a_miss_row(c):
    """After a pause the footer says how long the cache sat idle, and the next request that re-reads it leaves a row."""
    sid = c.app.dispatch("Cache watch cachehit", WORKSPACE)
    c.app.open_session("Cache watch")
    c.app.transcript_has("scripted", 40)
    settle(c)
    check(not c.app.session()["cacheOutlook"], "a fresh request has nothing to report")
    wait_for(lambda: c.app.session()["cacheOutlook"].startswith("cache idle"), 90, "the idle label", every=1.0)
    c.app.see(r"Cache outlook.*cache idle")
    c.app.prompt(sid, "second request cachemiss")
    c.app.transcript_has("scripted", 40)
    settle(c)
    row = wait_for(lambda: next((t for t in c.app.session()["transcript"] if t.startswith("Cache missed")), None), 20, "the miss row")
    check("idle" in row and "12,000 tokens" in row, row)
    check(not c.app.session()["cacheOutlook"], "a fresh request clears the outlook")


# The transcript.


@scenario("TR-05")
def generation_speed_is_timed_from_the_stream(c):
    """After a reply that took a few seconds, the footer shows its output speed in tokens a second."""
    c.app.dispatch("Speed check slow", WORKSPACE)
    c.app.open_session("Speed check")
    c.app.see(r"Output speed.*— tok/s", 10)
    c.app.transcript_has("scripted", 60)
    settle(c)
    rate = wait_for(lambda: c.app.session()["outputRate"], 10, "a measured rate")
    check(0 < rate < 1000, f"the scripted reply is 300 tokens over several seconds: {rate}")
    c.app.see(rf"Output speed.*{rate} tok/s")


@scenario("TR-06", "TR-10")
def markdown_alerts_footnotes_and_links(c):
    """An alert is titled, a footnote reads in brackets, and only a plain web address is followed."""
    c.app.dispatch("Markdown tour markdown", WORKSPACE)
    c.app.open_session("Markdown tour")
    c.app.transcript_has("The budget resets", 40)
    settle(c)
    c.app.see(r"^Warning: The budget resets on a timer", 5)
    c.app.see(r"notes\[1\]", 5)
    c.app.see(r"^\[1\]$", 5)
    c.app.see(r"link not followed", 5)
    links = [n for n in c.app.tree() if n["role"] == "AXLink"]
    names = [n["name"] for n in links]
    check("the Loom site" in names, f"a plain https address is a link: {names}")
    check("a script" not in names, f"a javascript: address must not be a link: {names}")
    c.app.see(r"mermaid", 5)
    c.app.see(r"Copy code", 5)


@scenario("TR-15")
def a_running_step_ticks(c):
    """A step still going shows the seconds it has run, counted from its record."""
    c.app.dispatch("Ticking step slowstep", WORKSPACE)
    c.app.open_session("Ticking step")
    wait_for(lambda: c.app.session()["isBusy"], 20, "a busy session")
    c.app.see(r"^Running sleep 7; echo slow-step-done", 10)
    first = wait_for(lambda: next((t for t in c.app.texts() if re.fullmatch(r"[1-9]\d?s", t)), None), 10, "an elapsed time")
    wait_for(lambda: next((t for t in c.app.texts() if re.fullmatch(r"[1-9]\d?s", t) and t != first), None), 10, "the clock to move")
    c.app.menu("Stop Run")
    settle(c)


@scenario("TR-12")
def a_stopped_turn_says_interrupted_on_its_divider(c):
    """The divider counts the failed steps, and says interrupted once a person stops the turn."""
    c.app.dispatch("Stopped mid stopmid", WORKSPACE)
    c.app.open_session("Stopped mid")
    wait_for(lambda: c.app.session()["isBusy"] and c.app.session()["hasStream"], 30, "the hung reply")
    c.app.menu("Stop Run")
    settle(c)
    title = wait_for(lambda: next((f["title"] for f in c.app.session()["folds"] if "interrupted" in f["title"]), None), 15, "an interrupted divider")
    check(re.fullmatch(r"Worked .*1 step · interrupted", title), title)
    c.app.dispatch("Failed and finished tour", WORKSPACE)
    c.app.open_session("Failed and finished")
    c.app.transcript_has("The tour is done", 40)
    settle(c)
    check(re.search(r"3 steps · 1 file · 1 failed$", fold_titles(c)[0]), "a finished turn does not say interrupted")


@scenario("TR-22")
def memory_context_is_a_closed_row(c):
    """The notes index attached to a run draws as one closed row, which opens to its text."""
    sid = c.app.dispatch("Remember writenote", WORKSPACE)
    c.app.open_session("Remember writenote")
    c.app.transcript_has("wrote that down", 40)
    settle(c)
    c.app.prompt(sid, "do the work again demo")
    c.app.transcript_has("Retry budget", 40)
    settle(c)
    check(not any("Notes saved in this repository" in t for t in c.app.session()["transcript"]), "the injected text is not a prompt")
    c.app.not_see(r"Retry budget lives in fetch")
    c.app.press(fold_titles(c)[-1])
    row = name_starting(c, "Memory context")
    check(re.fullmatch(r"Memory context, \d+ lines?", row), row)
    c.app.press(row)
    c.app.see(r"Retry budget lives in fetch", 5)


@scenario("TR-23", "TR-24")
def a_subagent_is_started_and_reports(c):
    """The transcript shows the agent a turn started, and its report opens to what the agent said."""
    c.app.dispatch("Delegate spawnagent", WORKSPACE)
    c.app.open_session("Delegate")
    c.app.transcript_has("The subagent has reported", 60)
    settle(c)
    c.app.see(r"^Started agent survey-files-\w+: survey files", 5)
    report = name_starting(c, "Report from survey-files")
    check("completed" in report, report)
    c.app.press(report)
    c.app.see(r"scripted", 5)


# Approvals and keys.


@scenario("AP-12")
def an_answer_to_a_record_that_moved_is_refused_with_words(c):
    """An answer built from a record the session no longer holds is refused locally, and the request stays."""
    pending_approval(c, "Stale answer")
    c.app.cmd("staleapprove")
    wait_for(lambda: "changed before your answer" in c.app.session()["lastError"], 10, "the refusal in words")
    c.app.see(r"That request changed before your answer was sent")
    check(c.app.session()["escalations"], "a refused answer leaves the request pending")
    c.app.press("Deny")
    wait_for(lambda: not c.app.session()["escalations"], 15, "the real answer to clear it")


@scenario("KB-03")
def command_b_toggles_the_sidebar(c):
    """⌘B hides the sidebar, and a second ⌘B shows it again."""
    c.app.go("mission")
    c.app.menu("Show Sidebar") if not c.app.snap()["showsSidebar"] else None
    wait_for(lambda: c.app.snap()["showsSidebar"], 5, "the sidebar")
    c.app.key("b", "cmd")
    wait_for(lambda: not c.app.snap()["showsSidebar"], 5, "⌘B to hide the sidebar")
    wait_for(lambda: not any(t.startswith("Group by") for t in c.app.texts()), 5, "the sidebar to leave the screen")
    c.app.key("b", "cmd")
    wait_for(lambda: c.app.snap()["showsSidebar"], 5, "⌘B to show the sidebar again")
    c.app.see(r"Group by", 5)


# Images.


def png_in_workspace(name):
    """Writes the 2 by 2 test PNG under a name, in the workspace the scripted model reads."""
    from pathlib import Path
    from scenarios import write_png
    path = Path(WORKSPACE) / name
    write_png(path)
    return path


@scenario("FI-01", "FI-02")
def attachments_are_limited_and_typed_by_their_bytes(c):
    """Four images go in one message, a fifth is refused in words, and a file's type comes from its bytes."""
    from pathlib import Path
    from loomui import BASE
    c.app.dispatch("Attach limits", WORKSPACE)
    c.app.open_session("Attach limits")
    settle(c)

    # A text file wearing an image's name is refused, and a real PNG named as text is accepted.
    liar = Path(BASE) / "not-really.png"
    liar.write_text("this is text, whatever the name says")
    c.app.cmd(f"attachfile {liar}")
    wait_for(lambda: "not a PNG, JPEG, GIF or WebP" in c.app.session()["notice"], 5, "the refusal")
    check(not c.app.session()["images"], "a text file must not become an attachment")
    honest = png_in_workspace("picture.dat")
    for number in range(4):
        c.app.cmd(f"attachfile {honest}")
        wait_for(lambda n=number: len(c.app.session()["images"]) == n + 1, 5, f"attachment {number + 1}")
    c.app.cmd(f"attachfile {honest}")
    wait_for(lambda: "4 of 4 images" in c.app.session()["notice"], 5, "the fifth to be refused")
    check(len(c.app.session()["images"]) == 4, c.app.session()["images"])
    check(c.app.session()["noticeIsWarning"], "the refusal is a warning")


@scenario("TR-39", "FI-03")
def images_are_drawn_with_their_type_size_and_weight(c):
    """An image in a message and one a tool returned each show a line giving type, pixels and bytes."""
    png = png_in_workspace("pixel.png")
    sid = c.app.dispatch("Picture message", WORKSPACE)
    c.app.open_session("Picture message")
    settle(c)
    c.app.cmd(f"attachfile {png}")
    wait_for(lambda: c.app.session()["images"], 5, "the attached chip")
    c.app.type("what is this")
    c.app.key("return")
    caption = wait_for(lambda: next(iter(c.app.session()["pictures"]), None), 20, "the picture in the sent message")
    check(re.fullmatch(r"image/png · 2 × 2 pixels · \d+ bytes", caption), caption)
    c.app.see(r"Image, image/png · 2 × 2 pixels")
    settle(c)
    c.app.dispatch("Tool picture readpicture", WORKSPACE)
    c.app.open_session("Tool picture")
    c.app.transcript_has("I looked at the picture", 40)
    settle(c)
    c.app.press(fold_titles(c)[0])
    c.app.press(name_starting(c, "Read pixel.png"))
    wait_for(lambda: c.app.session()["pictures"], 10, "the tool's picture")
    c.app.see(r"Image, image/png · 2 × 2 pixels")


@scenario("TR-20")
def a_message_names_its_sender_and_role(c):
    """A person's message carries the sender's name and the fixed word operator on a line of its own."""
    c.app.dispatch("Who said this", WORKSPACE)
    c.app.open_session("Who said this")
    c.app.transcript_has("scripted", 30)
    settle(c)
    c.app.see(r"^Owner · operator$", 5)
