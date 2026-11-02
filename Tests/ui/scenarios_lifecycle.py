"""Scenarios for the session life cycle: naming, stopping, archiving, deleting.

Native dialogs and sheets are driven the way a person drives them: a menu item opens
the question, and a control inside it is pressed by name. The question's state is read
from the app snapshot (`pendingAction`) so a test can say that no question was asked.
"""
import time

from loomui import wait_for
from scenarios import WORKSPACE, check, scenario


def record(c, sid):
    for session in c.app.sessions():
        if session["id"] == sid:
            return session
    return None


def asked(c, kind):
    """Waits for a question of this kind and returns its description."""
    return wait_for(lambda: (p := c.app.snap()["pendingAction"]).startswith(kind) and p, what=f"a {kind} question")


def go(c, sid):
    c.app.go(f"session {sid}")
    wait_for(lambda: c.app.snap()["destination"] == f"session:{sid}", what="the session to show")


@scenario("HM-13", "HM-18", "SH-06")
def a_session_is_renamed_from_its_menu(c):
    """Rename Session opens a sheet whose name replaces the row's title."""
    sid = c.app.dispatch("Rename subject please demo", WORKSPACE)
    go(c, sid)
    c.app.menu("Rename Session…")
    asked(c, "rename")
    c.app.fill("Session name", "Quarterly plan")
    c.app.press("Rename")
    wait_for(lambda: record(c, sid)["title"] == "Quarterly plan", what="the new title")
    wait_for(lambda: c.app.snap()["pendingAction"] == "", what="the sheet to close")
    c.app.see("Quarterly plan")


@scenario("HM-16", "HM-13")
def stopping_asks_only_when_mid_turn(c):
    """A mid-turn stop asks and can be declined; an idle stop does not ask."""
    sid = c.app.dispatch("Mid turn stop, hang", WORKSPACE)
    go(c, sid)
    wait_for(lambda: record(c, sid)["activity"] == "working", 60, "the run to be working")
    c.app.menu("Stop Session")
    asked(c, "stop")
    c.app.press("Cancel")
    wait_for(lambda: c.app.snap()["pendingAction"] == "", what="the question to close")
    check(record(c, sid)["state"] == "Running", "declining must leave the run alone")
    c.app.menu("Stop Session")
    asked(c, "stop")
    c.app.press("Stop Session")
    wait_for(lambda: record(c, sid)["state"] == "Saved", 60, "the session to be saved")

    idle = c.app.dispatch("Idle stop check demo", WORKSPACE)
    go(c, idle)
    wait_for(lambda: record(c, idle)["activity"] == "idle", 60, "the run to finish")
    c.app.menu("Stop Session")
    wait_for(lambda: record(c, idle)["state"] == "Saved", 60, "the idle session to stop")
    check(c.app.snap()["pendingAction"] == "", "an idle stop should not ask")


@scenario("HM-14", "HM-15", "HM-17")
def archive_and_delete_ask_first(c):
    """Archiving a saved row, stop-and-archive of a running one, and delete each ask."""
    saved = c.app.dispatch("Archive saved row demo", WORKSPACE)
    go(c, saved)
    wait_for(lambda: record(c, saved)["activity"] == "idle", 60, "the run to finish")
    c.app.menu("Stop Session")
    wait_for(lambda: record(c, saved)["state"] == "Saved", 60, "the stop")
    c.app.menu("Archive Session…")
    check(asked(c, "archive").endswith("saved:quiet"), "a saved row asks plainly")
    c.app.press("Archive")
    wait_for(lambda: record(c, saved) is None, 60, "the archived session to leave the list")

    running = c.app.dispatch("Archive running row demo", WORKSPACE)
    go(c, running)
    wait_for(lambda: record(c, running)["activity"] == "idle", 60, "the run to finish")
    c.app.menu("Archive Session…")
    check(asked(c, "archive").endswith("running:quiet"), "a running row says it will stop first")
    c.app.press("Stop and Archive")
    wait_for(lambda: record(c, running) is None, 60, "the stopped and archived session to leave")

    doomed = c.app.dispatch("Delete this one demo", WORKSPACE)
    go(c, doomed)
    wait_for(lambda: record(c, doomed)["activity"] == "idle", 60, "the run to finish")
    c.app.menu("Delete Session…")
    time.sleep(0.5)
    check(c.app.snap()["pendingAction"] == "", "a running session cannot be deleted")
    c.app.menu("Stop Session")
    wait_for(lambda: record(c, doomed)["state"] == "Saved", 60, "the stop")
    c.app.menu("Delete Session…")
    asked(c, "delete")
    c.app.press("Cancel")
    wait_for(lambda: c.app.snap()["pendingAction"] == "", what="the question to close")
    check(record(c, doomed) is not None, "declining must keep the session")
    c.app.menu("Delete Session…")
    asked(c, "delete")
    c.app.press("Delete Session")
    wait_for(lambda: record(c, doomed) is None, 60, "the deleted session to leave the list")


# Creating a session.

SCRATCH = None


def scratch_folder(name):
    from pathlib import Path
    from loomui import BASE
    path = Path(BASE) / name
    path.mkdir(parents=True, exist_ok=True)
    (path / "README.md").write_text("scratch\n")
    # The daemon reports canonical paths, and /tmp is a link to /private/tmp.
    return str(path.resolve())


def open_form(c):
    c.app.menu("New Agent…")
    wait_for(lambda: c.app.snap()["isDispatching"], what="the new-session form")


def close_form(c):
    if c.app.snap()["isDispatching"]:
        c.app.key("escape")
        wait_for(lambda: not c.app.snap()["isDispatching"], what="the form to close")


@scenario("NS-03", "NS-06", "NS-07", "NS-19")
def the_folder_field_searches_recent_places_and_judges_typing(c):
    """Recent places are listed and filtered by typing, a bad path is named, and a place can be forgotten."""
    keep = scratch_folder("keep-place")
    gone = scratch_folder(f"forget-place-{int(time.time())}")
    c.app.dispatch("Seed keep place demo", keep)
    c.app.dispatch("Seed forget place demo", gone)
    open_form(c)
    try:
        c.app.focus("Folder")
        c.app.see(f"Use folder {keep}")
        c.app.see(f"Use folder {gone}")

        c.app.fill("Folder", "keep-pl")
        c.app.see(f"Use folder {keep}")
        c.app.not_see(f"Use folder {gone}")

        c.app.fill("Folder", "/no/such/folder/here")
        c.app.see("That folder doesn.t exist")
        check(not c.app.enabled("Dispatch"), "an unusable folder should not allow dispatch")

        c.app.fill("Folder", "")
        c.app.press(f"Forget folder {gone}")
        wait_for(lambda: not any(f"Use folder {gone}" in t for t in c.app.texts()), what="the forgotten place to leave the list")
        c.app.see(f"Use folder {keep}")
        c.app.press(f"Use folder {keep}")
        c.app.focus("Prompt")
        c.app.type("x")
        wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed for a real folder")
    finally:
        close_form(c)


@scenario("NS-14", "NS-15", "NS-16", "NS-17")
def a_session_is_created_with_a_profile_model_name_and_box(c):
    """The form's profile, model, name and shareable choices reach the daemon, which accepts them."""
    folder = scratch_folder("options-place")
    open_form(c)
    try:
        c.app.focus("Prompt")
        c.app.type("Options check demo")
        c.app.fill("Folder", folder)
        c.app.fill("Session name", "Named by the form")
        c.app.press("review")
        c.app.press("fake2")
        c.app.press("Shareable")
        c.app.see("People you invite can read this session")
        wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed")
        c.app.press("Dispatch")
        wait_for(lambda: not c.app.snap()["isDispatching"], 60, "the form to close after creating")
    finally:
        close_form(c)
    wait_for(lambda: c.app.snap()["daemons"][0]["lastCreation"] == "profile=review model=fake2 shareable=true", what="the daemon to accept the choices")
    c.app.session_id("Named by the form")


def find_box_label(c, prefix="box"):
    """A placement segment's name, which carries its platform and free scopes."""
    return wait_for(lambda: next((n["name"] for n in c.app.tree() if n["role"] == "AXRadioButton" and n["name"].startswith(prefix)), None), what=f"the {prefix} segment")


@scenario("NS-12", "NS-08")
def an_executor_offers_its_registered_workspaces(c):
    """Choosing the executor lists the workspace names it registered, and one is used."""
    open_form(c)
    try:
        wait_for(lambda: any(t.startswith("Tools run on") or "box" in t for t in c.app.texts()), what="the placement choice")
        c.app.press(find_box_label(c))
        c.app.see("Use folder proj")
        c.app.focus("Prompt")
        c.app.type("Executor form check demo")
        wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed")
        c.app.press("Dispatch")
        wait_for(lambda: not c.app.snap()["isDispatching"], 60, "the form to close")
    finally:
        close_form(c)
    sid = c.app.session_id("Executor form check")
    wait_for(lambda: record(c, sid)["executor"] == "box", what="the session to be placed on box")


@scenario()
def a_new_session_can_start_in_the_current_folder(c):
    """The Session menu opens the form on the folder of the session in the window."""
    folder = scratch_folder("heading-place")
    sid = c.app.dispatch("Heading place run demo", folder)
    go(c, sid)
    c.app.menu("New Session in This Folder…")
    try:
        wait_for(lambda: c.app.snap()["isDispatching"], what="the new-session form")
        wait_for(lambda: any(n["name"].startswith("Folder") and n["value"] == folder for n in c.app.tree()), what="the folder to be filled")
    finally:
        close_form(c)


@scenario("MV-03")
def a_local_session_cannot_move_and_says_why(c):
    """Move on a session with no executor states that only an executor's sessions move."""
    sid = c.app.dispatch("Move me not demo", WORKSPACE)
    go(c, sid)
    c.app.menu("Move Session…")
    c.app.see("Only a session on an executor can move")
    check(not any(n["name"] == "Move" for n in c.app.tree()), "a local session must offer no Move button")
    c.app.press("Close")
    wait_for(lambda: not any("Only a session on an executor" in t for t in c.app.texts()), what="the sheet to close")


# Sharing and people.


def share_dialog(c, sid):
    go(c, sid)
    c.app.menu("Share Session…")
    c.app.see("Share “")


def make_shareable(c, sid):
    share_dialog(c, sid)
    c.app.see("This session is private")
    c.app.press("Make Shareable…")
    c.app.press("Make Shareable")
    c.app.see("Invite someone", 60)


def invite(c, name, role="Operator"):
    c.app.fill("Invitee name", name)
    c.app.press(role)
    c.app.press("Invite")
    c.app.see(f"Hand this to {name}")


@scenario("SH-02", "SH-03", "SH-04", "SH-05", "CR-08", "CR-09", "CR-10")
def a_session_is_made_shareable_and_someone_is_invited(c):
    """A private session becomes shareable, an invitation hands over its claim, and the person's role and access can change."""
    sid = c.app.dispatch("Private to share demo", WORKSPACE)
    wait_for(lambda: record(c, sid)["activity"] == "idle", 60, "the run to finish")
    make_shareable(c, sid)
    invite(c, "Ada", "Observer")
    c.app.see("Claim token loomclaim_[0-9a-f]{64}")
    c.app.see(r"loom claim --addr ws://127\.0\.0\.1:\d+/v2/claim")
    c.app.press("Hide Token")
    c.app.see("Claim token hidden")
    c.app.not_see("loomclaim_")
    c.app.press("I've Sent It")
    c.app.see("Make Ada an operator")
    c.app.press("Make Ada an operator")
    c.app.see("Make Ada an observer")
    c.app.press("Remove Ada")
    c.app.press("Remove Access")
    wait_for(lambda: not any("Remove Ada" in t for t in c.app.texts()), what="Ada to be removed")
    c.app.press("Done")


@scenario("CR-01", "CR-02", "CR-03", "CR-04", "CR-05", "CR-07")
def people_are_renamed_rotated_and_revoked(c):
    """The People sheet lists everyone, renames them, rotates a credential into a handover and revokes access."""
    sid = c.app.dispatch("People subject demo", WORKSPACE)
    wait_for(lambda: record(c, sid)["activity"] == "idle", 60, "the run to finish")
    make_shareable(c, sid)
    invite(c, "Grace")
    c.app.press("I've Sent It")
    c.app.press("Done")
    c.app.menu("People…")
    c.app.press("Person Grace")
    c.app.fill("Person name", "Grace H")
    c.app.press("Save Name")
    c.app.see("Person Grace H")
    c.app.fill("Your name", "Owner Olu")
    c.app.press("Rename Me")
    c.app.see("Person Owner Olu")
    c.app.press("Person Grace H")
    c.app.press("Rotate Credential…")
    c.app.press("Rotate Credential")
    c.app.see("Hand this to Grace H")
    c.app.see("Claim token loomclaim_")
    c.app.press("I've Sent It")
    c.app.press("Revoke Access…")
    c.app.press("Revoke Access")
    c.app.see("Credential: No credential")
    c.app.press("Done")


# Session settings.


@scenario("SE-03", "SE-04")
def effort_and_profile_are_changed_on_a_running_session(c):
    """Reasoning effort applies to the strand, and a profile switch restarts the session under it."""
    sid = c.app.dispatch("Settings subject demo", WORKSPACE)
    c.app.open_session("Settings subject")
    wait_for(lambda: record(c, sid)["activity"] == "idle", 60, "the run to finish")
    c.app.menu("Session Settings…")
    c.app.see("Reasoning effort")
    c.app.press("High")
    wait_for(lambda: c.app.session()["thinkingLevel"] == "high", what="the strand to carry the new effort")
    wait_for(lambda: c.app.session()["profile"] == "" and "review" in " ".join(c.app.texts()), what="the profile choices to load")
    # The daemon refuses a switch while any strand is working, even briefly.
    wait_for(lambda: not c.app.session()["isBusy"], what="the strand to rest")
    time.sleep(1)
    c.app.press("review")
    c.app.press("Switch Profile")
    wait_for(lambda: c.app.session().get("profile") == "review", 60, "the session to restart under the review profile")
    c.app.press("Done")


@scenario("NS-09", "MA-04")
def a_session_is_created_in_a_pool(c):
    """A pool is offered as a place, named on the Machines screen, and the daemon picks its executor."""
    c.app.go("machines")
    c.app.see("Pools")
    c.app.see("Pool boxes, ready")
    open_form(c)
    try:
        c.app.press(find_box_label(c, "boxes"))
        c.app.focus("Prompt")
        c.app.type("Pool form check demo")
        c.app.fill("Folder", "proj")
        wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed")
        c.app.press("Dispatch")
        wait_for(lambda: not c.app.snap()["isDispatching"], 60, "the form to close")
    finally:
        close_form(c)
    sid = c.app.session_id("Pool form check")
    wait_for(lambda: c.app.cmd(f"snapshot") and any(s["id"] == sid for s in c.app.sessions()), what="the session")


@scenario("MA-02", "MA-05", "MA-06", "MA-08", "MA-09")
def a_machine_is_read_in_detail(c):
    """Machines are grouped by role, and a machine's detail shows its state, its sessions, its scopes and operator commands."""
    sid = c.app.dispatch("Machine detail run demo", "proj", executor="box")
    c.app.go("machines")
    c.app.see("Orchestrators")
    c.app.see("Executors")
    c.app.press("Details for box")
    c.app.see("Overview")
    c.app.see("Its report agrees with the declaration")
    c.app.see("Machine detail run")
    c.app.see("Every closed scope ended cleanly")
    c.app.see("loom distribution renew box")
    c.app.see(r"loom distribution revoke box --reason 'REASON'")
    c.app.press("Done")


# Peers.


@scenario("PL-01", "PL-02", "PL-03")
def two_sessions_are_linked_and_unlinked(c):
    """A link lets one session's strand message another, shows in both, and can be removed."""
    first = c.app.dispatch("Peer first run demo", WORKSPACE)
    second = c.app.dispatch("Peer second run demo", WORKSPACE)
    for sid in (first, second):
        wait_for(lambda: record(c, sid)["activity"] == "idle", 60, "the run to finish")
    c.app.open_session("Peer first")
    c.app.menu("Peer Links…")
    c.app.see("No links")
    c.app.press("Link target Peer second run demo")
    c.app.press("May wake")
    c.app.press("Link")
    c.app.see("Unlink Peer second run demo")
    c.app.see("may wake it")
    c.app.press("Done")
    c.app.open_session("Peer second")
    c.app.menu("Peer Links…")
    c.app.see("it may message this strand")
    c.app.press("Done")
    c.app.open_session("Peer first")
    c.app.menu("Peer Links…")
    c.app.press("Unlink Peer second run demo")
    c.app.press("Remove Link")
    c.app.see("No links")
    c.app.press("Done")
