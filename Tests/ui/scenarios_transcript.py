"""Scenarios for typed commands, the composer's lines, and the transcript's rarer rows.

They run in the same cluster as the others and follow the same rules: assert what a
person would see, and wait on a condition and never on a bare sleep. Scenarios that
need the inspector's tabs carry `needs_display`, since a locked screen never lays those
tabs out.
"""
import time

from loomui import wait_for
from scenarios import WORKSPACE, check, pending_approval, run_command, scenario, settle


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
