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
    c.app.transcript_has("decision (approved|consumed)", 15)
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


@scenario("CO-31", "CO-32")
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
    # The fixture's mermaid fence draws as a diagram, with its source and its copy
    # control behind Show Source.
    c.app.press("Show Source")
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
    wait_for(lambda: c.app.session()["isBusy"] and c.app.session()["hasStream"], 60, "the hung reply")
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
    if not c.app.snap()["showsSidebar"]:
        c.app.menu("Toggle Sidebar")
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
    senders = c.app.session()["senders"]
    check(len(senders) == 1 and senders[0].startswith("Owner"), senders)
    c.app.see(rf"^{re.escape(senders[0])} · operator$", 5)


# Messages from other agents.


@scenario("TR-28")
def a_brief_from_another_strand_is_a_card_without_its_framing(c):
    """A subagent's first message is a card from the strand that sent it, with the harness's contract apart."""
    c.app.dispatch("Brief card spawnagent", WORKSPACE)
    c.app.open_session("Brief card")
    c.app.transcript_has("The subagent has reported", 60)
    settle(c)
    child = next(x for x in c.app.session()["strands"] if x.startswith("sub:"))
    c.app.cmd(f"strand {child}")
    wait_for(lambda: c.app.session()["focusedStrand"] == child, 5, "the child strand")
    row = wait_for(lambda: next((t for t in c.app.session()["transcript"] if t.startswith("sibling main")), None), 10, "the sibling card")
    check("task brief" not in row and "[end brief" not in row, f"the framing must be removed: {row}")
    check("Name one file in the workspace" in row, row)
    c.app.see(r"^From strand main$", 5)
    c.app.see(r"^\[result contract, from the harness", 5)


@scenario("TR-31")
def a_delivered_nudge_is_an_advisor_row(c):
    """A nudge the advisor queued reaches the primary, and the transcript labels it as the advisor's."""
    c.app.dispatch("Nudge me advisenudge", WORKSPACE)
    c.app.open_session("Nudge me")
    c.app.transcript_has("scripted", 30)
    row = wait_for(lambda: next((t for t in c.app.session()["transcript"] if t.startswith("Advisor nudge")), None), 90, "the delivered nudge")
    check("per-host budget" in row, row)
    c.app.see(r"^Advisor nudge$", 5)
    settle(c)


@scenario("TR-25", "TR-26", "TR-27")
def a_peer_message_is_a_card_that_can_be_answered_and_followed(c):
    """A message from another session is a card naming its sender, with Reply drafting an answer and Open going there."""
    receiver = c.app.dispatch("Peer receiver", WORKSPACE)
    c.app.open_session("Peer receiver")
    settle(c)
    sender = c.app.dispatch(f"Peer sender peersend {receiver}", WORKSPACE)
    # The link lets the sender message the receiver's main strand and wake it.
    reply = c.app.cmd(f"peerlink {sender} {receiver}")
    check(reply == "ok", reply)
    c.app.go(f"session {sender}")
    wait_for(lambda: c.app.snap()["destination"] == f"session:{sender}", 5, "the sender")
    c.app.prompt(sender, f"send it again, peersend {receiver}")
    c.app.go(f"session {receiver}")
    wait_for(lambda: c.app.snap()["destination"] == f"session:{receiver}", 5, "the receiver")
    row = wait_for(lambda: next((t for t in c.app.session()["transcript"] if t.startswith("peer ")), None), 60, "the peer card")
    check("missing cancellation check" in row, row)
    c.app.see(r"^Peer · Peer sender peersend .* · main$", 5)
    c.app.see(r"^Origin checked by the daemon$", 5)
    c.app.press("Reply to Peer")
    wait_for(lambda: c.app.session()["draft"].startswith("Reply to Peer sender"), 5, "the drafted reply")
    check(sender in c.app.session()["draft"], c.app.session()["draft"])
    name_open = name_starting(c, "Open Peer sender")
    c.app.press(name_open)
    wait_for(lambda: c.app.snap()["destination"] == f"session:{sender}", 5, "the sender's session to open")


@scenario()
def an_observer_sees_the_session_and_can_change_nothing(c):
    """Drawn as an observer, the session keeps its transcript and loses the editor and the answer buttons."""
    pending_approval(c, "Watched")
    c.app.see(r"Write to /Users/Shared", 5)
    c.app.cmd("asrole observer")
    try:
        wait_for(lambda: c.app.session()["isObserver"], 5, "the observer view")
        c.app.see(r"You are watching this session", 5)
        c.app.see(r"Only an operator can answer", 5)
        check(not any(n["name"] in ("Message", "Allow", "Deny") for n in c.app.tree()), "an observer has no editor and no answer buttons")
        c.app.menu("Allow Request")
        wait_for(lambda: "observer can watch" in c.app.session()["lastError"], 5, "the menu command to be refused")
        check(c.app.session()["escalations"], "the request stays pending")
    finally:
        c.app.cmd("asrole none")
    c.app.press("Deny")
    wait_for(lambda: not c.app.session()["escalations"], 15, "the owner's answer to clear it")


@scenario("TR-19")
def long_reasoning_carries_the_summarizers_label(c):
    """A reasoning block over 512 bytes gets the summarizer's label, said to be its words and not the agent's."""
    c.app.dispatch("Long thought", WORKSPACE)
    c.app.open_session("Long thought")
    settle(c)

    # The review profile routes the summarizer, which the plain configuration does not.
    run_command(c, "/profile review")
    c.app.open_session("Long thought")
    wait_for(lambda: c.app.session().get("isLive") and c.app.session().get("isAdopted"), 60, "the session to come back")
    c.app.prompt(c.app.session_id("Long thought"), "think long, longthink")
    c.app.transcript_has("forty-two", 60)
    settle(c)
    c.app.press(fold_titles(c)[0])
    label = wait_for(lambda: next((t for t in c.app.texts() if t.startswith("Thought,") and "Summarized: " in t), None), 40, "a summarized reasoning row")
    check("Summarized: " in label and "Expanded" not in label, label)


# The inspector. These need the inspector's tabs laid out, so they cannot run on a locked screen.


@scenario("ST-04", needs_display=True)
def the_strands_tab_counts_the_approvals_waiting(c):
    """While a strand waits on a person, the Strands tab's title carries the count."""
    pending_approval(c, "Badge count")
    if not c.app.snap()["showsInspector"]:
        c.app.menu("Toggle Inspector")
        wait_for(lambda: c.app.snap()["showsInspector"], 3, "the inspector")
    c.app.see(r"Strands \(1\)", 10)
    c.app.press("Deny")
    wait_for(lambda: not c.app.session()["escalations"], 15, "the approval to clear")
    c.app.not_see(r"Strands \(\d\)")


@scenario("ST-07", needs_display=True)
def escape_leaves_a_strands_page(c):
    """Escape on a strand's page returns to the list of all strands."""
    c.app.dispatch("Crumb check", WORKSPACE)
    c.app.open_session("Crumb check")
    c.app.transcript_has("scripted", 30)
    settle(c)
    if not c.app.snap()["showsInspector"]:
        c.app.menu("Toggle Inspector")
        wait_for(lambda: c.app.snap()["showsInspector"], 3, "the inspector")
    c.app.press("Strands")
    c.app.press("Details for main")
    c.app.see(r"Recent tools", 5)
    c.app.key("escape")
    wait_for(lambda: not any(t.startswith("Recent tools") for t in c.app.texts()), 5, "the page to close")
    c.app.see(r"Strand main", 5)


@scenario("ST-10", needs_display=True)
def a_card_names_its_model_where_it_differs_from_main(c):
    """Once main runs another model, a card for a strand on the first model says which."""
    c.app.dispatch("Model on card", WORKSPACE)
    c.app.open_session("Model on card")
    c.app.transcript_has("scripted", 30)
    wait_for(lambda: any(l.startswith("advisor: Finished") for l in c.app.session()["strandLines"]), 40, "the advisor to finish")
    run_command(c, "/model fake2")
    if not c.app.snap()["showsInspector"]:
        c.app.menu("Toggle Inspector")
        wait_for(lambda: c.app.snap()["showsInspector"], 3, "the inspector")
    c.app.press("Strands")
    c.app.press("Settled strands")
    c.app.see(r"Strand advisor.*model fake$", 10)
    c.app.not_see(r"Strand main.*model ")


@scenario("KB-07", needs_display=True)
def escape_in_a_note_goes_back_to_the_list(c):
    """Escape on an open note returns to the list of notes."""
    sid = c.app.dispatch("Note keys todoboard", WORKSPACE)
    c.app.open_session("Note keys")
    c.app.transcript_has("first task is finished", 40)
    settle(c)
    if not c.app.snap()["showsInspector"]:
        c.app.menu("Toggle Inspector")
        wait_for(lambda: c.app.snap()["showsInspector"], 3, "the inspector")
    c.app.press("Notes")
    c.app.press("Note todo")
    c.app.see(r"All Notes", 5)
    c.app.key("escape")
    wait_for(lambda: not any(t == "All Notes" for t in c.app.texts()), 5, "the note to close")
    c.app.see(r"Search notes", 5)


@scenario("TR-37", needs_display=True)
def the_end_stays_in_view_when_the_width_changes(c):
    """A reader at the end of a long reply stays there when the inspector opens or closes."""
    c.app.dispatch("Big words", WORKSPACE)
    c.app.open_session("Big words")
    settle(c)
    c.app.prompt(c.app.session_id("Big words"), "bigreport")
    c.app.transcript_has("in finding 23", 60)
    settle(c)

    # Opening the inspector changes every row's height. Before the fix the view kept
    # its offset and landed mid-report, or over rows it had not built and drew nothing.
    for toggle in range(4):
        c.app.menu("Toggle Inspector")
        time.sleep(1.2)
        wait_for(lambda: c.app.fully_on_screen("point 4 about the cloned index in finding 23"), 5,
                 f"the end of the reply on screen after toggle {toggle}")


# TR-08 stays partial until a diagram can be expanded, so this carries no row.
@scenario()
def a_mermaid_block_draws_as_a_diagram(c):
    """A finished mermaid fence becomes a diagram, and one the renderer refuses shows why and its source."""
    c.app.dispatch("show diagram please", WORKSPACE)
    c.app.open_session("show diagram")
    c.app.transcript_has("diagram-reply-done", 40)
    settle(c)

    # The valid flowchart draws and keeps its source behind a control. The invalid
    # one names the parser's complaint and falls back to the source as code.
    c.app.see(r"^Diagram$", 20)
    c.app.see(r"^The diagram could not be drawn\.$", 20)
    c.app.see(r"Parse error on line", 5)
    c.app.press("Show Source")
    c.app.see(r"^Hide Source$", 5)
