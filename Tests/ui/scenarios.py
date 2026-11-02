"""The UI scenarios. Each names the parity rows it proves.

`covers` holds ids from docs/parity.md. tests/ui/parity_check.py fails if a row claims
`yes` and no scenario covers it, so the table cannot drift from what is tested.
"""
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
