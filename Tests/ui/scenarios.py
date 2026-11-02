"""The UI scenarios. Each names the parity rows it proves.

`covers` holds ids from docs/parity.md. tests/ui/parity_check.py fails if a row claims
`yes` and no scenario covers it, so the table cannot drift from what is tested.
"""
import re
import time
from dataclasses import dataclass

from loomui import BASE, Failure, ROOT, rng, wait_for
import visual

ALL = []
WORKSPACE = str(BASE / "proj")


@dataclass
class Scenario:
    name: str
    doc: str
    covers: tuple
    foreground: bool
    run: object


class Context:
    def __init__(self, app, cluster, out, args):
        self.app = app
        self.cluster = cluster
        self.out = out
        self.args = args
        self.notes = []


def scenario(*covers, foreground=False):
    def wrap(fn):
        ALL.append(Scenario(fn.__name__, (fn.__doc__ or "").strip(), covers, foreground, fn))
        return fn
    return wrap


def check(condition, message):
    if not condition:
        raise Failure(message)


def pending_approval(c, title):
    """Dispatches a run that raises an approval, and opens it."""
    sid = c.app.dispatch(f"{title} escalate", WORKSPACE)
    c.app.open_session(title)
    wait_for(lambda: c.app.session().get("escalations"), what="the approval")
    return sid


def daemon_state(c):
    return c.app.snap()["daemons"][0]


# Connection and discovery.


@scenario()
def appearance_and_size_matrix(c):
    """Each main screen renders in both appearances, at minimum and default size."""
    # Fixed content on a fresh daemon, first in the run, so differences mean the
    # interface changed and not that earlier scenarios left other sessions behind.
    c.app.dispatch("Baseline one please demo", WORKSPACE)
    c.app.dispatch("Baseline two escalate", WORKSPACE)
    c.app.transcript_has("waiting on your approval", 30)
    screens = ["mission", "inbox", "machines"]
    worst = []
    for appearance in ("dark", "light"):
        c.app.appearance(appearance)
        for width, height in ((1400, 900), (880, 560)):
            c.app.resize(width, height)
            for where in screens:
                c.app.go(where)
                time.sleep(0.5)
                name = f"{where}-{appearance}-{width}"
                shot = c.app.shot(c.out / "matrix" / f"{name}.png")
                changed = visual.compare(
                    shot, ROOT / "tests/ui/baselines" / f"{name}.png",
                    c.out / "diffs" / f"{name}.png", c.args.update,
                )
                if changed is not None and changed > visual.LIMIT:
                    worst.append((name, round(changed, 3)))
    c.app.appearance("dark")
    c.app.resize(1400, 900)
    check(not worst, f"visual change over {visual.LIMIT:.0%}: {worst}")


@scenario("MA-15", "MA-01")
def connects_to_the_daemon(c):
    """The app reaches a connected state and reads the deployment."""
    wait_for(lambda: daemon_state(c)["state"] == "connected", what="connection")
    wait_for(lambda: daemon_state(c)["deployment"], what="the deployment")
    check(c.app.snap()["isMultiMachine"], "an executor is configured, so machines should show")


@scenario()
def no_unnamed_controls(c):
    """Every control on each screen has a name a screen reader can say."""
    for where in ("mission", "inbox", "machines"):
        c.app.go(where)
        time.sleep(0.4)
        unnamed = c.app.audit()
        check(not unnamed, f"{where}: unnamed controls {unnamed[:3]}")


# Dispatch and the transcript.


@scenario("HM-11", "NS-01", "NS-02", "TR-01", "CO-01", "PA-05", "PA-06", "PA-10")
def dispatch_runs_on_this_machine(c):
    """A dispatched prompt runs and its reply lands in the transcript."""
    c.app.dispatch("Local hello from the suite", WORKSPACE)
    c.app.open_session("Local hello")
    c.app.transcript_has("Local hello from the suite")
    c.app.transcript_has("scripted", 30)
    check(not c.app.session()["lastError"], c.app.session()["lastError"])


@scenario("NS-08", "NS-13", "HM-08", "MA-13", "TR-07", "TR-09", "WT-08")
def dispatch_runs_on_the_executor(c):
    """A session placed on an executor shows brain and hands, and its tools ran there."""
    c.app.dispatch("Remote demo run please", "proj", executor="box")
    c.app.open_session("Remote demo")
    c.app.transcript_has("Retry budget is now per host", 40)
    card = wait_for(lambda: [x for x in c.app.snap()["cards"] if "Remote demo" in x["name"]], what="the card")[0]
    check("→ box" in card["placement"], f"placement was {card['placement']!r}")
    check(any("command" in t for t in c.app.session()["transcript"]), "tool runs should be folded in the transcript")


@scenario("TR-02", "CO-08", "TR-37")
def streaming_is_drawn_while_it_arrives(c):
    """Text appears before the run ends, and the run's end is observed."""
    sid = c.app.dispatch("Streaming check, slow", WORKSPACE)
    c.app.open_session("Streaming check")
    wait_for(lambda: c.app.session().get("hasStream") or c.app.session().get("isBusy"), what="a live run")
    c.app.transcript_has("scripted", 40)
    wait_for(lambda: not c.app.session()["isBusy"], 40, "the run to end")


@scenario("CO-18")
def stop_ends_a_run(c):
    """Stop Run ends a run in progress."""
    c.app.dispatch("Please hang for the suite", WORKSPACE)
    c.app.open_session("Please hang")
    wait_for(lambda: c.app.session().get("isBusy"), what="a busy session")
    c.app.menu("Stop Run")
    wait_for(lambda: not c.app.session()["isBusy"], 20, "the run to stop")


@scenario("CO-02", "CO-19")
def steering_reaches_a_busy_run(c):
    """Input to a busy strand is accepted as a steer, with no error shown."""
    sid = c.app.dispatch("Steer me, hang", WORKSPACE)
    c.app.open_session("Steer me")
    wait_for(lambda: c.app.session().get("isBusy"), what="a busy session")
    c.app.prompt(sid, "change of plan")
    time.sleep(1)
    check(not c.app.session()["lastError"], c.app.session()["lastError"])
    c.app.menu("Stop Run")


@scenario()
def a_failed_run_reaches_the_inbox(c):
    """A provider failure shows as a failed run, and the attention list carries it."""
    c.app.dispatch("Please explode now", WORKSPACE)
    wait_for(lambda: any(a["kind"] == "Failed runs" and "explode" in a["agent"] for a in c.app.snap()["attention"]), 60, "the failed run")


# The composer.


def settle(c):
    """Waits for the open session's run to end."""
    wait_for(lambda: not c.app.session()["isBusy"], 40, "the run to end")


def send_line(c, text, mods=""):
    """Types into the composer and presses Return, as a person would."""
    c.app.type(text)
    wait_for(lambda: c.app.session()["draft"] == text, 3, "the typed draft")
    c.app.key("return", mods)


def busy_session(c, title):
    c.app.dispatch(f"{title} hang", WORKSPACE)
    c.app.open_session(title)
    wait_for(lambda: c.app.session().get("isBusy"), 20, "a busy session")


@scenario("CO-03", "CO-04", "CO-02", "QU-01", "TR-41", "CO-09")
def return_queues_and_the_chord_steers(c):
    """Return queues behind a busy turn, and the steer chord joins the turn."""
    busy_session(c, "Queueing")
    send_line(c, "after this run")
    held = wait_for(lambda: c.app.session()["pendingInputs"], 10, "the held input")
    check(held[0]["kind"] == "queue", f"Return should queue, got {held}")
    c.app.see("after this run")
    wait_for(lambda: "Queued" in c.app.session()["notice"], 5, "the notice")
    send_line(c, "change course", "cmd")
    wait_for(lambda: not c.app.session()["lastError"], 5, "no error")
    check(not c.app.session()["lastError"], c.app.session()["lastError"])
    c.app.menu("Stop Run")
    settle(c)


@scenario("CO-04", "CO-01", "CO-16")
def idle_composer_sends_with_return_or_the_chord(c):
    """An empty draft cannot be sent, and Return and the chord both send when idle."""
    c.app.dispatch("Chord check", WORKSPACE)
    c.app.open_session("Chord check")
    settle(c)
    send = [n for n in c.app.tree() if n["name"] == "Send"]
    check(send and not send[0]["enabled"], f"Send should be disabled with an empty draft: {send}")
    send_line(c, "plain return")
    c.app.transcript_has("plain return", 20)
    settle(c)
    send_line(c, "chord return", "cmd")
    c.app.transcript_has("chord return", 20)
    settle(c)


@scenario("CO-05", "CO-06", "KB-06", "CO-21", "CO-22")
def the_command_list_follows_the_draft(c):
    """A slash opens the list, arrows and Tab drive it, Escape closes it."""
    c.app.dispatch("Slash list", WORKSPACE)
    c.app.open_session("Slash list")
    settle(c)
    c.app.type("/")
    rows = wait_for(lambda: c.app.session()["slashRows"], 5, "the command list")
    check("/model" in rows and "/effort" in rows, f"the list should offer commands: {rows}")
    c.app.type("ef")
    wait_for(lambda: c.app.session()["slashRows"] == ["/effort"], 5, "the list to narrow")
    c.app.key("escape")
    wait_for(lambda: not c.app.session()["slashRows"], 5, "Escape to close the list")
    check(c.app.session()["draft"] == "/ef", "Escape must keep the draft")
    c.app.type("f")
    wait_for(lambda: c.app.session()["slashRows"], 5, "typing to reopen the list")
    c.app.key("tab")
    wait_for(lambda: c.app.session()["draft"] == "/effort ", 5, "Tab to complete")
    levels = wait_for(lambda: c.app.session()["slashRows"], 5, "the argument rows")
    check(len(levels) == 7, f"/effort offers seven levels: {levels}")
    c.app.key("down")
    wait_for(lambda: c.app.session()["slashSelected"] == 1, 5, "Down to move")
    c.app.key("up")
    c.app.key("up")
    wait_for(lambda: c.app.session()["slashSelected"] == 6, 5, "Up to wrap")
    c.app.key("return")
    wait_for(lambda: c.app.session()["notice"], 10, "a notice after /effort")
    check(c.app.session()["draft"] == "", "the command should leave the editor empty")

    # The model names come from the daemon's catalogue.
    c.app.type("/model ")
    wait_for(lambda: c.app.session()["slashRows"] == ["/model fake"], 10, "the model rows")
    c.app.key("return")
    wait_for(lambda: "now uses fake" in c.app.session()["notice"], 10, "/model to answer")
    check(not c.app.session()["noticeIsWarning"], c.app.session()["notice"])


@scenario("CO-13", "CO-09", "CO-12")
def a_refused_draft_returns_to_the_editor(c):
    """A pending line shows until the daemon answers, and a refusal restores the text."""
    busy_session(c, "Refusal")
    c.app.cmd("lanedelay 2500")
    c.app.type("slow one")
    c.app.key("return")
    wait_for(lambda: c.app.session()["pendingDrafts"] == ["slow one"], 3, "the pending line")
    c.app.see("Sending: slow one", 3)
    wait_for(lambda: not c.app.session()["pendingDrafts"], 10, "the line to go once taken")
    c.app.cmd("lanedelay 0")
    for number in range(2, 5):
        send_line(c, f"queued {number}")
        wait_for(lambda n=number: len(c.app.session()["pendingInputs"]) == n, 10, f"{number} held inputs")
    send_line(c, "one too many")
    wait_for(lambda: c.app.session()["draft"] == "one too many", 10, "the refused draft to return")
    check(c.app.session()["noticeIsWarning"], "the refusal should be worded as a warning")
    check("full" in c.app.session()["notice"], c.app.session()["notice"])
    c.app.menu("Stop Run")


@scenario("QU-02", "QU-03", "QU-04")
def a_held_input_can_be_edited_and_withdrawn(c):
    """The submitter edits a queued message in place, and removes another."""
    busy_session(c, "Held edit")
    send_line(c, "first words")
    wait_for(lambda: c.app.session()["pendingInputs"], 10, "the held input")
    wait_for(lambda: c.app.session()["pendingInputs"][0]["editable"], 5, "an editable input")
    c.app.press("Edit queued message")
    wait_for(lambda: c.app.session()["editing"] == "first words", 10, "the full text to load")
    c.app.key("a", "cmd")
    c.app.type("second words")
    wait_for(lambda: c.app.session()["editing"] == "second words", 5, "the edited text")
    c.app.press("Save")
    wait_for(lambda: [p["text"] for p in c.app.session()["pendingInputs"]] == ["second words"], 10, "the saved edit")
    c.app.press("Remove queued message")
    wait_for(lambda: not c.app.session()["pendingInputs"], 10, "the input to be withdrawn")
    c.app.menu("Stop Run")


def write_png(path):
    """Writes a 2x2 PNG with no dependency."""
    import struct
    import zlib

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes([200, 40, 40] * 2) for _ in range(2))
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    )


@scenario("CO-15", "TR-39")
def a_pasted_image_goes_with_the_message(c):
    """Paste attaches an image as a chip, and the message carries it to the daemon."""
    from pathlib import Path
    png = Path(BASE) / "pixel.png"
    write_png(png)
    c.app.dispatch("Image paste", WORKSPACE)
    c.app.open_session("Image paste")
    settle(c)
    said = c.app.cmd(f"pasteimage {png}")
    wait_for(lambda: c.app.session()["images"] == ["Pasted image"], 5, f"the attached chip ({said})")
    c.app.see("Remove Pasted image")
    c.app.press("Remove Pasted image")
    wait_for(lambda: not c.app.session()["images"], 5, "the chip to go")
    c.app.cmd(f"pasteimage {png}")
    wait_for(lambda: c.app.session()["images"], 5, "the chip again")
    send_line(c, "describe the picture")
    wait_for(lambda: c.app.session()["userImages"] == 1, 20, "the image in the sent message")
    c.app.see("1 image")
    check(not c.app.session()["lastError"] and not c.app.session()["noticeIsWarning"], c.app.session()["notice"])
    settle(c)


def run_command(c, text):
    """Types a command, presses Return, and returns the notice it produced."""
    c.app.type(text)
    wait_for(lambda: c.app.session()["draft"] == text, 3, "the typed command")
    # Escape closes the command list, so Return submits the line as typed.
    if c.app.session()["slashRows"]:
        c.app.key("escape")
    c.app.key("return")
    return wait_for(lambda: c.app.session()["notice"], 15, f"a notice after {text}")


@scenario("CO-31", "CO-32", "CO-09")
def schedules_list_and_retire(c):
    """/schedules lists, and /unschedule says plainly when nothing matches."""
    c.app.dispatch("Schedule words", WORKSPACE)
    c.app.open_session("Schedule words")
    settle(c)
    check("chedule" in run_command(c, "/schedules"), "schedules should answer")
    note = run_command(c, "/unschedule nothing-here")
    check(c.app.session()["noticeIsWarning"], f"retiring a missing schedule is refused: {note}")


@scenario("CO-25", "KB-05")
def fork_makes_a_strand_and_escape_returns(c):
    """/fork adds a strand, and Escape in the composer returns to main."""
    c.app.dispatch("Fork it", WORKSPACE)
    c.app.open_session("Fork it")
    settle(c)
    run_command(c, "/fork branch-two")
    name = wait_for(lambda: next((x for x in c.app.session()["strands"] if "branch-two" in x), None), 10, "the forked strand")
    c.app.cmd(f"strand {name}")
    wait_for(lambda: c.app.session()["focusedStrand"] == name, 5, "focus on the fork")
    c.app.key("escape")
    wait_for(lambda: c.app.session()["focusedStrand"] == "main", 5, "Escape to return to main")


@scenario("CO-26", "CO-27", "CO-28", "CO-29", "CO-30")
def goals_are_pinned_and_steered(c):
    """/goal pins, checks, pauses, resumes and clears a session goal."""
    c.app.dispatch("Goal words", WORKSPACE)
    c.app.open_session("Goal words")
    settle(c)
    note = run_command(c, "/goal --budget 50000 ship the thing")
    c.notes.append(f"goal_set: {note}")
    check(not c.app.session()["noticeIsWarning"], note)
    check("ship the thing" in note, note)
    check("check" in run_command(c, "/goal check make check").lower(), "the check should be named")
    check("paused" in run_command(c, "/goal pause"), "paused")
    check("active" in run_command(c, "/goal resume"), "resumed")
    check("cleared" in run_command(c, "/goal clear"), "cleared")


@scenario("CO-17", "TR-32")
def compact_runs_and_leaves_a_notice(c):
    """/compact asks the daemon to compact, and the transcript says it happened."""
    c.app.dispatch("Compact me demo", WORKSPACE)
    c.app.open_session("Compact me")
    c.app.transcript_has("Retry budget", 40)
    settle(c)
    note = run_command(c, "/compact")
    c.notes.append(f"compact: {note}")
    wait_for(lambda: any("compacted" in t for t in c.app.session()["transcript"]) or c.app.session()["noticeIsWarning"], 40, "a compaction or a refusal")


@scenario("CO-36", "CO-37")
def a_side_question_is_answered_apart(c):
    """/btw asks a question beside the conversation, and closes."""
    c.app.dispatch("Side question", WORKSPACE)
    c.app.open_session("Side question")
    settle(c)
    c.app.type("/btw what is a lane")
    c.app.key("escape")
    c.app.key("return")
    wait_for(lambda: c.app.session()["btwStatus"], 15, "the side panel")
    c.app.see("Side question")
    wait_for(lambda: c.app.session()["btwStatus"] != "running", 30, "the answer")
    c.app.see("scripted")
    c.app.press("Close side question")
    wait_for(lambda: not c.app.session()["btwStatus"], 5, "the panel to close")


@scenario("CO-23", "CO-24")
def profile_is_shown(c):
    """/profile names the session's profile and the ones it may switch to."""
    c.app.dispatch("Profile words", WORKSPACE)
    c.app.open_session("Profile words")
    settle(c)
    note = run_command(c, "/profile")
    check(note.startswith("Profile:"), note)


@scenario("CO-20", "CO-19")
def typed_queue_and_steer_commands(c):
    """/queue holds text behind the run, and /steer joins it."""
    busy_session(c, "Typed queue")
    run_command(c, "/queue after the hang")
    wait_for(lambda: [p["kind"] for p in c.app.session()["pendingInputs"]] == ["queue"], 10, "the queued input")
    run_command(c, "/steer go another way")
    wait_for(lambda: not c.app.session()["lastError"], 5, "no error")
    c.app.menu("Stop Run")


@scenario("TR-21")
def a_long_message_is_drawn_whole(c):
    """A long message needs no toggle, since the whole text is on screen."""
    c.app.dispatch("Long words", WORKSPACE)
    c.app.open_session("Long words")
    settle(c)
    tail = "THE-END-OF-A-LONG-MESSAGE"
    long = " ".join(["filler"] * 400) + " " + tail
    c.app.cmd(f"prompt {c.app.session_id('Long words')} {long}")
    c.app.see(tail, 20)


@scenario("TR-33")
def a_stopped_run_says_so(c):
    """A run the person stopped leaves a row that says so."""
    busy_session(c, "Stopped words")
    c.app.menu("Stop Run")
    settle(c)
    wait_for(lambda: any("Stopped" in t for t in c.app.session()["transcript"]), 15, "a stopped row")


# The transcript.


def name_starting(c, prefix):
    """The full accessibility name of the first control whose name begins with `prefix`."""
    return wait_for(
        lambda: next((n["name"] for n in c.app.tree() if n["name"].startswith(prefix)), None),
        10, f"a control named {prefix!r}...",
    )


def fold_titles(c):
    return [f["title"] for f in c.app.session()["folds"]]


@scenario("TR-11", "TR-13", "TR-14", "TR-16", "TR-12", "TR-15")
def a_turn_folds_to_one_line_with_figures(c):
    """A turn's work sits behind one line, whose steps say what they did."""
    c.app.dispatch("Folding tour", WORKSPACE)
    c.app.open_session("Folding tour")
    c.app.transcript_has("The tour is done", 40)
    settle(c)
    fold = wait_for(lambda: c.app.session()["folds"], 10, "a fold")[0]
    check(fold["steps"] == 3 and fold["files"] == 1 and fold["failed"] == 1, f"figures were {fold}")
    check(fold["added"] == 4, f"the write adds four lines: {fold}")
    check(re.search(r"Worked .*3 steps · 1 file · 1 failed", fold["title"]), fold["title"])
    c.app.not_see("Wrote tour-notes.txt")
    c.app.press(fold["title"])
    c.app.see("Wrote tour-notes.txt")
    c.app.see("Ran echo tour-command-output")
    c.app.see(r"Did not complete: read no-such-file-for-the-tour.txt")
    c.app.see(r"Wrote tour-notes.txt.*4 added")
    c.app.press("Ran echo tour-command-output")
    c.app.see(r"tour-command-output")
    c.app.see(r"\$ echo tour-command-output")


@scenario("TR-03", "TR-04", "TR-18")
def reasoning_is_live_then_settled(c):
    """Reasoning shows as it streams, and settles to a row with its length."""
    c.app.dispatch("Please think it over", WORKSPACE)
    c.app.open_session("Please think it over")
    wait_for(lambda: c.app.session()["isBusy"], 20, "a busy session")
    check(c.app.session()["turnStartedAt"], "the elapsed time should come from the recorded input")
    wait_for(lambda: c.app.session()["streamThinking"] > 0, 20, "reasoning to stream")
    c.app.press("Thinking")
    c.app.see("First, consider the retry budget")
    c.app.transcript_has("forty-two", 40)
    settle(c)
    title = wait_for(lambda: fold_titles(c), 10, "the settled fold")[0]
    c.app.press(title)
    c.app.see(r"Thought, 3 lines")
    c.app.press(name_starting(c, "Thought, 3 lines"))
    c.app.see("Third, decide what to change")


@scenario("TR-17")
def a_program_draws_as_a_card(c):
    """A code_mode call opens to its program and what it did."""
    c.app.dispatch("Run a program card", WORKSPACE)
    c.app.open_session("Run a program card")
    c.app.transcript_has("The program has run", 40)
    settle(c)
    c.app.press(fold_titles(c)[0])
    c.app.press("Ran a program import cap/fs")
    c.app.see(r"Program: ")
    c.app.see(r"Program · 5 lines")


@scenario("TR-29")
def a_decided_approval_stays_in_the_lane(c):
    """After Allow, the transcript keeps a row saying what was allowed."""
    pending_approval(c, "Decided row")
    c.app.press("Allow")
    wait_for(lambda: not c.app.session()["escalations"], what="the approval to clear")
    wait_for(lambda: any(t.startswith("decision") for t in c.app.session()["transcript"]), 15, "a decision row")
    c.app.see(r"Allowed")


@scenario("TR-34", "TR-35")
def older_turns_page_in(c):
    """A long conversation opens at its end, and Load Older Turns reaches the start."""
    sid = c.app.dispatch("Long history", WORKSPACE)
    c.app.open_session("Long history")
    settle(c)
    for number in range(70):
        c.app.prompt(sid, f"turn number {number}")
        wait_for(lambda n=number: any(f"turn number {n}" in t for t in c.app.session()["transcript"]), 20, "the turn to land")
        settle(c)
    c.app.cmd(f"detach {sid}")
    wait_for(lambda: c.app.session().get("isLive") is False, 10, "the lane to end")
    wait_for(lambda: c.app.session().get("isLive") and c.app.session().get("isAdopted"), 20, "a fresh lane")
    before = c.app.session()["blocks"]
    check(c.app.session()["hasOlder"], f"a reopened long session should have older turns ({before} blocks held)")
    c.app.cmd("scrollup")
    wait_for(lambda: c.app.session()["blocks"] > before, 20, "older turns to arrive")

    # Each page moves the top out of view, so the reader scrolls up again.
    for _ in range(40):
        if not c.app.session()["hasOlder"]:
            break
        c.app.cmd("scrollup")
        time.sleep(0.5)
    wait_for(lambda: not c.app.session()["hasOlder"], 30, "the start of the conversation")
    def at_the_top():
        c.app.cmd("scrollup")
        return any("Beginning of the conversation" in t for t in c.app.texts())
    wait_for(at_the_top, 20, "the beginning of the conversation", every=0.4)


# Approvals.


@scenario("AP-01", "AP-03")
def approval_shows_what_is_asked(c):
    """The card names the authority, the tool and the sample statement."""
    pending_approval(c, "Asking")
    c.app.see(r"Write to /Users/Shared")
    c.app.see(r"fs_write")
    c.app.see(r"sample of the call")


@scenario("AP-05")
def allow_clears_an_approval(c):
    """Pressing Allow answers the request and the attention item goes."""
    pending_approval(c, "Allowing")
    c.app.press("Allow")
    wait_for(lambda: not c.app.session()["escalations"], what="the approval to clear")
    wait_for(lambda: not any("Allowing" in a["agent"] for a in c.app.snap()["attention"]), what="the attention item to go")


@scenario("AP-04")
def deny_clears_an_approval(c):
    """Pressing Deny answers the request."""
    pending_approval(c, "Denying")
    c.app.press("Deny")
    wait_for(lambda: not c.app.session()["escalations"], what="the approval to clear")


@scenario()
def menu_allows_the_first_request(c):
    """The Session menu's Allow Request answers the first card."""
    pending_approval(c, "Menu allow")
    c.app.menu("Allow Request")
    wait_for(lambda: not c.app.session()["escalations"], what="the approval to clear")


@scenario()
def allow_for_session_stops_the_next_prompt(c):
    """Remembering a grant means the same write does not ask again."""
    sid = pending_approval(c, "Remember")
    c.app.menu("Allow Request for This Session")
    wait_for(lambda: not c.app.session()["escalations"], what="the approval to clear")
    c.app.prompt(sid, "escalate again")
    c.app.transcript_has("escalate again")
    time.sleep(4)
    check(not c.app.session()["escalations"], "a remembered grant should not ask again")


@scenario("HM-21", "HM-22", "PA-12")
def approval_appears_in_mission_and_inbox(c):
    """An approval is answerable from Mission Control and listed in the Inbox."""
    pending_approval(c, "Everywhere")
    c.app.go("mission")
    c.app.see("Needs You")
    c.app.go("inbox")
    c.app.see("Write to /Users/Shared")
    c.app.go("mission")
    c.app.press("Allow")


# Panels: the figures, boards and inspector tabs.


def open_tab(c, name):
    """Opens the inspector on a tab, whatever the inspector showed before."""
    if not c.app.snap()["showsInspector"]:
        c.app.menu("Show Inspector")
        wait_for(lambda: c.app.snap()["showsInspector"], 3, "the inspector")
    c.app.press(name)


def run_session(c, title, prompt, wait="scripted"):
    """Dispatches a run, opens it and waits for its closing words."""
    c.app.dispatch(f"{title} {prompt}", WORKSPACE)
    c.app.open_session(title)
    c.app.transcript_has(wait, 40)
    wait_for(lambda: not c.app.session()["isBusy"], 40, "the run to end")


@scenario("PA-01", "PA-07", "PA-08")
def bar_figures_and_tabs(c):
    """The composer shows the connection and an estimated cost, and the inspector has six tabs."""
    run_session(c, "Figures", "check", "scripted")
    c.app.see(r"Connected")
    wait_for(lambda: c.app.session().get("context", "").startswith("ctx ~"), 20, "the context figure")
    # The fake model reports tokens and the cluster prices them, so the bar says
    # how much, as an estimate and not as a bill.
    c.app.see(r"Estimated cost.*est \$0\.0", 10)
    for tab in ("Changes", "Strands", "Session", "Trace", "Notes", "Evolution"):
        open_tab(c, tab)
    open_tab(c, "Trace")
    c.app.see(r"No program has run on this strand", 5)
    open_tab(c, "Session")
    c.app.see(r"Estimated cost", 10)


@scenario("CX-01", "CX-02", "CX-03", "CX-04", "CX-05", "CX-07")
def context_figure_and_breakdown(c):
    """The bar says how full the window is, and its breakdown explains it and can compact."""
    run_session(c, "Context", "demo please", "Retry budget is now per host")
    wait_for(lambda: c.app.session().get("context", "").startswith("ctx ~"), 20, "the context figure")
    c.app.press("Context window")
    c.app.see(r"Context window ~", 10)
    c.app.see(r"tokens until the session compacts itself", 10)
    c.app.see(r"System prompt", 5)
    c.app.see(r"What is in the context", 5)
    c.app.press("Refresh")
    c.app.shot(c.out / "panels" / "context-breakdown.png")
    # A short session has nothing to compact, and the daemon says so. The panel
    # words that refusal as an answer.
    c.app.press("Compact Now")
    c.app.see(r"Nothing to compact yet", 10)
    c.app.key("escape")
    wait_for(lambda: not any("Context window ~" in t for t in c.app.texts()), 5, "the breakdown to close")


@scenario("ST-11")
def todo_board_follows_the_agent(c):
    """The todo board is pinned above the composer with the active task and progress."""
    run_session(c, "Plan", "todoboard now", "first task is finished")
    wait_for(lambda: c.app.session().get("todo") == "1/4 done", 15, "the board")
    c.app.see(r"Todo board.*Add the tests", 5)
    # The board remembers whether it was left open, so open it only if it is not.
    try:
        c.app.see(r"Wire the metrics, pending", 1)
    except Failure:
        c.app.press("Todo board")
    c.app.see(r"Wire the metrics, pending", 5)
    c.app.see(r"Write the parser, done", 5)
    c.app.shot(c.out / "panels" / "todo-board.png")


@scenario("ST-01", "ST-02", "ST-06", "ST-05", "ST-16")
def strands_say_what_they_do(c):
    """Each strand has a card with one status line, a page of detail, and takes the composer."""
    sid = c.app.dispatch("Cards check", WORKSPACE)
    c.app.open_session("Cards")
    c.app.transcript_has("scripted", 30)
    wait_for(lambda: any(l.startswith("advisor: Finished") for l in c.app.session()["strandLines"]), 40, "the advisor to finish")
    c.app.prompt(sid, "please hang here")
    wait_for(lambda: c.app.session().get("isBusy"), 20, "a busy session")
    open_tab(c, "Strands")
    c.app.see(r"Strand main.*Working", 10)
    # The advisor ended its run, so it sits in the closed group.
    c.app.not_see(r"Strand advisor")
    c.app.press("Settled strands")
    c.app.see(r"Strand advisor.*Finished", 5)
    c.app.press("Details for main")
    c.app.see(r"Recent tools", 5)
    c.app.see(r"Not reported yet|tokens", 5)
    c.app.shot(c.out / "panels" / "strand-detail.png")
    c.app.press("All Strands")
    c.app.see(r"Strand main", 5)
    c.app.menu("Stop Run")
    wait_for(lambda: not c.app.session()["isBusy"], 20, "the run to stop")
    wait_for(lambda: any(l.startswith("main: Halted") for l in c.app.session()["strandLines"]), 15, "main to read halted")
    # A card focuses its strand, and what is typed then goes to that strand.
    c.app.press("Strand advisor")
    wait_for(lambda: c.app.session()["focused"] == "advisor", 5, "the advisor to take focus")
    c.app.prompt(sid, "a word for the advisor")
    c.app.transcript_has("a word for the advisor", 20)
    c.app.press("Strand main")
    wait_for(lambda: c.app.session()["focused"] == "main", 5, "main to take focus")
    check(not any("a word for the advisor" in t for t in c.app.session()["transcript"]), "the prompt belonged to the advisor")


@scenario("AP-02", "AP-09")
def approval_says_who_and_waits(c):
    """The card says who asks and what for, and its buttons arm after a moment."""
    c.app.dispatch("Arming escalate", WORKSPACE)
    c.app.open_session("Arming")
    started = time.monotonic()
    wait_for(lambda: c.app.session().get("escalations"), 40, "the approval")
    seen = time.monotonic()
    c.app.see(r"main wants to write a file", 5)
    c.app.see(r"Allow this file write\?|Write to /Users/Shared", 5)
    c.app.press("Allow")
    check(time.monotonic() - seen > 0.3, "Allow answered before the card armed")
    wait_for(lambda: not c.app.session()["escalations"], 15, "the approval to clear")


@scenario("GO-01", "GO-02", "GO-03", "GO-04", "GO-05", "GO-06")
def goal_pauses_resumes_and_clears(c):
    """A pinned goal shows its status and spend, and Pause, Resume and Clear change it."""
    c.app.dispatch("Goal check", WORKSPACE)
    c.app.open_session("Goal check")
    open_tab(c, "Session")
    c.app.see(r"No goal is pinned", 10)
    c.app.cmd('run goal_set {"objective":"land the migration","token_budget":400000}')
    wait_for(lambda: c.app.session()["goal"] in ("active", "paused"), 15, "the goal")
    c.app.see(r"land the migration", 10)
    c.app.press("Pause Goal")
    wait_for(lambda: c.app.session()["goal"] == "paused", 15, "the goal to pause")
    c.app.see(r"Goal paused \(you paused it\)", 10)
    c.app.press("Resume Goal")
    wait_for(lambda: c.app.session()["goal"] in ("active", "budget limited"), 15, "the goal to resume")
    c.app.shot(c.out / "panels" / "goal-dock.png")
    c.app.press("Clear Goal")
    c.app.press("Discard Goal")
    wait_for(lambda: c.app.session()["goal"] in ("none", ""), 15, "the goal to clear")
    c.app.see(r"No goal is pinned", 10)


@scenario("PV-01", "PV-02", "PV-03", "PV-04", "PV-05")
def proposals_are_reviewed(c):
    """A proposed rule is shown whole, and can be rejected, or approved after a question."""
    c.app.dispatch("Rule one proposerule", WORKSPACE)
    c.app.open_session("Rule one")
    c.app.see(r"proposes a rule", 40)
    c.app.see(r"Run make check before pushing", 5)
    c.app.shot(c.out / "panels" / "proposal-dock.png")
    open_tab(c, "Session")
    c.app.see(r"1 proposals waiting", 10)
    c.app.press("Reject rule")
    c.app.see(r"Decided \(1\)", 15)
    c.app.not_see(r"proposes a rule")
    # A second proposal is approved, and only after the question is answered.
    sid = c.app.session_id("Rule one")
    c.app.prompt(sid, "again proposerule")
    c.app.see(r"proposes a rule", 40)
    c.app.press("Approve rule")
    c.app.press("Approve and Write")
    c.app.see(r"Decided \(2\)", 15)


@scenario("NO-01", "NO-02", "NO-03", "NO-04", "NO-05")
def notes_are_searched_and_opened(c):
    """The Notes tab lists the strand's notes, searches them and shows one readable or raw."""
    run_session(c, "Notes", "todoboard", "first task is finished")
    open_tab(c, "Notes")
    c.app.see(r"Note todo", 10)
    c.app.press("Refresh notes")
    c.app.press("Note todo")
    c.app.see(r"All Notes", 5)
    c.app.see(r"Write the parser", 5)
    c.app.press("Raw")
    c.app.see(r"\"phases\"", 5)
    c.app.press("All Notes")
    c.app.see(r"Search notes", 5)


@scenario("PE-01", "PE-02")
def remembered_permissions_can_be_forgotten(c):
    """What Allow for This Session left behind is listed with who approved it, and Forget removes it."""
    pending_approval(c, "Forgetting")
    c.app.menu("Allow Request for This Session")
    wait_for(lambda: not c.app.session()["escalations"], 15, "the approval to clear")
    open_tab(c, "Session")
    # The listing is read when the tab opens, which may be before the daemon has
    # written the remembered fact, so ask again until it is there.
    wait_for(lambda: c.app.press("Refresh permissions") and any("Write to /Users/Shared" in t for t in c.app.texts()), 15, "the remembered permission")
    c.app.see(r"Owner", 5)
    label = wait_for(lambda: next((t for t in c.app.texts() if t.startswith("Forget Write to")), None), 10, "a Forget button")
    c.app.press(label)
    c.app.press("Forget")
    wait_for(lambda: not any("Write to /Users/Shared" in t for t in c.app.texts()), 15, "the permission to go")
    c.app.see(r"Nothing is remembered", 10)


@scenario("SC-01", "SC-02")
def schedules_are_listed_and_retired(c):
    """A schedule a strand created is listed with its timing and can be retired."""
    run_session(c, "Beats", "heartbeat", "heartbeat is scheduled")
    open_tab(c, "Session")
    c.app.press("Refresh schedules")
    c.app.see(r"heartbeat", 10)
    c.app.see(r"fired \d", 5)
    c.app.press("Retire schedule heartbeat")
    c.app.press("Retire Schedule")
    c.app.see(r"Nothing is scheduled", 15)


@scenario("JO-01", "JO-02")
def live_jobs_are_listed(c):
    """A background job is listed with its age and deadline, as of the last refresh."""
    run_session(c, "Jobs", "backgroundjob", "background job is running")
    open_tab(c, "Session")
    c.app.see(r"Live jobs", 5)
    c.app.see(r"at last refresh", 15)
    c.app.see(r"sleep 300", 15)
    c.app.see(r"deadline in", 5)


@scenario("PA-13")
def side_question_panel(c):
    """A question asked on the side is answered in its own panel, which clears and closes."""
    run_session(c, "Aside", "check", "scripted")
    c.app.press("Side Question")
    wait_for(lambda: c.app.session()["side"], 5, "the panel")
    # The field takes focus when the panel opens, so typing needs no click.
    c.app.type("what changed?")
    c.app.press("Ask")
    c.app.see(r"what changed\?", 15)
    c.app.see(r"scripted", 20)
    c.app.press("Refresh")
    c.app.press("Clear")
    c.app.not_see(r"what changed\?")
    c.app.press("Close Side Question")
    wait_for(lambda: not c.app.session()["side"], 5, "the panel to close")


@scenario("ME-01")
def memory_overview_lists_notes(c):
    """The memory overview names what each run receives and the notes the agent wrote."""
    run_session(c, "Memory", "writenote", "wrote that down")
    open_tab(c, "Session")
    c.app.press("Refresh memory")
    c.app.see(r"Retry budget lives in fetch", 15)
    c.app.see(r"loom-memory.notes", 5)


@scenario("WT-04", "WT-05")
def changes_say_how_each_file_changed(c):
    """A new file reads as new, and a commit the session made is listed with its patch."""
    c.app.dispatch("Status commitwork", "proj", executor="box")
    c.app.open_session("Status commit")
    c.app.transcript_has("committed the work", 60)
    open_tab(c, "Changes")
    c.app.see(r"Committed in this session", 20)
    c.app.see(r"BUDGET = 3", 10)
    # A file the session wrote and did not commit is new, and says so.
    c.app.dispatch("Status demo run please", "proj", executor="box")
    c.app.open_session("Status demo")
    c.app.transcript_has("Retry budget is now per host", 60)
    open_tab(c, "Changes")
    c.app.see(r"fetch\.py, \d+ added, \d+ removed, (new|added|modified)", 20)


@scenario("ST-15")
def a_strand_is_forked_from_a_form(c):
    """Fork opens a form, and the new strand appears with the name it was given."""
    run_session(c, "Forking", "check", "scripted")
    open_tab(c, "Strands")
    c.app.press("Fork Strand")
    c.app.type("alt-approach")
    c.app.key("return")
    wait_for(lambda: "alt-approach" in c.app.session()["strands"], 15, "the forked strand")
    c.app.see(r"Strand alt-approach", 10)


@scenario("PA-03", "PA-09")
def home_and_sidebar_controls(c):
    """The sidebar hides and shows, and Mission Control is one press from a session."""
    run_session(c, "Homeward", "check", "scripted")
    c.app.press("Hide Sidebar")
    wait_for(lambda: not any(t.startswith("Mission Control") for t in c.app.texts()), 5, "the sidebar to hide")
    c.app.press("Show Sidebar")
    c.app.menu("Mission Control")
    wait_for(lambda: c.app.snap()["destination"] == "mission", 5, "Mission Control")


@scenario("PV-06", "PV-13")
def evolution_tab_reads_the_board_and_core(c):
    """The Evolution tab reads the catalogue again on request, and reads the core's status."""
    run_session(c, "Evolving", "check", "scripted")
    open_tab(c, "Evolution")
    c.app.see(r"No candidates yet", 15)
    c.app.press("Read Again")
    c.app.see(r"No candidates yet", 10)
    c.app.press("Read Core Status")
    c.app.see(r"boundary", 15)


# Navigation and screens.


@scenario(foreground=True)
def real_keyboard_shortcuts_navigate(c):
    """Real key events reach the menu when the window is key."""
    import subprocess
    subprocess.run(["open", "-b", "com.roasbeef.loom-desktop"], check=True)
    wait_for(lambda: c.app.stats()["active"] == "true", 5, "the app to be active")
    for key, where in (("1", "inbox"), ("2", "mission"), ("3", "machines")):
        c.app.key(key, "cmd")
        wait_for(lambda: c.app.snap()["destination"] == where, 3, f"⌘{key} to reach {where}")
    c.app.cmd("deactivate")


@scenario("KB-01", "KB-02")
def palette_navigates(c):
    """⌘K opens, filters by typing, and Return goes to the match."""
    c.app.go("mission")
    c.app.key("k", "cmd")
    wait_for(lambda: c.app.snap()["isPaletteOpen"], 3, "the palette")
    c.app.type("machines")
    time.sleep(0.3)
    c.app.key("return")
    wait_for(lambda: c.app.snap()["destination"] == "machines", 3, "the palette to navigate")
    check(not c.app.snap()["isPaletteOpen"], "the palette should close")


@scenario("KB-02")
def palette_escape_closes(c):
    """Escape closes the palette and goes nowhere."""
    c.app.go("mission")
    c.app.key("k", "cmd")
    wait_for(lambda: c.app.snap()["isPaletteOpen"], 3, "the palette")
    c.app.key("escape")
    wait_for(lambda: not c.app.snap()["isPaletteOpen"], 3, "the palette to close")
    check(c.app.snap()["destination"] == "mission", "escape should not navigate")


@scenario("PA-02", "WT-01", "WT-02", "WT-03", "KB-04")
def inspector_toggles_and_shows_changes(c):
    """The inspector opens and reads the worktree from the machine with the checkout."""
    c.app.dispatch("Inspector demo run please", "proj", executor="box")
    c.app.open_session("Inspector demo")
    c.app.transcript_has("Retry budget is now per host", 40)
    c.app.menu("Show Inspector")
    wait_for(lambda: c.app.snap()["showsInspector"], 3, "the inspector")
    # The inspector reopens on the tab it was left on, which an earlier scenario chose.
    c.app.press("Changes")
    c.app.see(r"changed file|No uncommitted", 20)
    c.app.see("fetch.py", 10)
    c.app.menu("Hide Inspector")
    c.app.key("i", "cmd,opt")
    wait_for(lambda: not c.app.snap()["showsInspector"], 3, "the inspector to close") if c.app.snap()["showsInspector"] else None


@scenario("MA-12", "MA-14")
def machines_lists_each_node(c):
    """The Machines page shows the orchestrator and executor with their facts."""
    c.app.go("machines")
    c.app.see("box")
    c.app.see("executor")
    c.app.see("orchestrator")


# Scenarios for session life-cycle, creation, sharing and administration live in
# their own file, imported here so they run before the faults damage the cluster.
import scenarios_lifecycle  # noqa: E402,F401


# Faults. These run last among the functional scenarios, since they damage the cluster.


@scenario()
def monkey_keeps_the_app_alive(c):
    """A seeded random walk over safe controls never crashes or leaves an error state."""
    random = rng(c.args.seed)
    safe = lambda n: n["role"] in ("AXButton", "AXRadioButton", "AXCheckBox") and n["name"] and not any(
        word in n["name"] for word in ("Allow", "Deny", "Stop", "Disconnect", "Remove", "Quit", "Close", "close", "minimize", "zoom", "Dispatch", "Connect", "Start", "Resume")
    )
    trail = []
    for step in range(60):
        move = random.random()
        if move < 0.2:
            where = random.choice(["mission", "inbox", "machines"])
            trail.append(f"go {where}")
            c.app.cmd(f"go {where}")
        elif move < 0.35:
            sessions = c.app.sessions()
            if sessions:
                sid = random.choice(sessions)["id"]
                trail.append(f"go session {sid}")
                c.app.cmd(f"go session {sid}")
        elif move < 0.45:
            trail.append("key k cmd, escape")
            c.app.key("k", "cmd")
            c.app.key("escape")
        else:
            controls = [n for n in c.app.tree() if safe(n)]
            if controls:
                name = random.choice(controls)["name"]
                trail.append(f"press {name}")
                c.app.cmd(f"press {name}")
        if not c.app.alive():
            raise Failure(f"crashed after: {trail[-8:]}")
        # A sheet opened by the walk would hide everything behind it.
        if c.app.snap()["isDispatching"]:
            c.app.key("escape")
    check(c.app.alive(), "the app should survive the walk")
    c.notes.append(f"Monkey seed {c.args.seed}: {len(trail)} actions.")


@scenario()
def frames_hold_while_streaming(c):
    """Streaming at about 250 words a second stays under a frame budget."""
    sid = c.app.dispatch("Frame budget, long report", WORKSPACE)
    c.app.open_session("Frame budget")
    time.sleep(1)
    stats = c.app.hitch(6)
    c.notes.append(f"Streaming frames: {stats}")
    wait_for(lambda: c.app.session()["isBusy"] is False, 90, "the long run to end")
    share = stats["over25ms"] / max(stats["frames"], 1)
    check(stats["frames"] > 100, f"too few frames measured: {stats}")
    check(share < 0.05, f"{share:.1%} of frames over 25 ms: {stats}")


@scenario()
def idle_is_quiet(c):
    """An idle app with sessions attached uses little CPU and drops no frames."""
    c.app.go("mission")
    time.sleep(8)
    before = float(c.app.stats()["cpu_seconds"])
    started = time.monotonic()
    stats = c.app.hitch(15)
    used = float(c.app.stats()["cpu_seconds"]) - before
    share = used / (time.monotonic() - started)
    c.notes.append(f"Idle CPU {share:.2%}, frames {stats}")
    check(share < 0.05, f"idle CPU {share:.1%}")


@scenario()
def an_executor_loss_is_reported(c):
    """Killing the executor reaches the Machines page and the Inbox, naming the sessions."""
    c.cluster.kill("exec")
    wait_for(
        lambda: any(n["name"] == "box" and n["state"] == "down" for n in daemon_state(c)["nodes"]),
        40, "box to read down",
    )
    wait_for(lambda: any(a["kind"] == "Machines" for a in c.app.snap()["attention"]), 10, "a machine item")
    c.app.go("inbox")
    c.app.see("box is down")


@scenario("PA-11")
def a_session_says_why_it_ended(c):
    """When the daemon is lost, the open session says it is disconnected and why."""
    run_session(c, "Ending", "check", "scripted")
    c.cluster.kill("orch")
    wait_for(lambda: c.app.session().get("isLive") is False, 30, "the lane to read closed")
    c.app.see(r"Disconnected", 10)
    wait_for(lambda: c.app.session().get("endedWords"), 10, "words for the ending")


@scenario()
def a_daemon_loss_recovers(c):
    """Killing the orchestrator is shown, and the app recovers when it returns."""
    c.cluster.kill("orch")
    wait_for(lambda: daemon_state(c)["state"] == "unavailable", 20, "the daemon to read unavailable")
    check(c.app.alive(), "the app must survive its daemon")
    c.app.go("mission")

    # The monkey may have hidden the sidebar, which is where the footer says this.
    c.app.menu("Show Sidebar")
    c.app.see("unavailable")
