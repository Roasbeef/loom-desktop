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
    c.app.key("a", "cmd")
    c.app.type("Quarterly plan")
    c.app.press("Rename")
    wait_for(lambda: record(c, sid)["title"] == "Quarterly plan", what="the new title")
    wait_for(lambda: c.app.snap()["pendingAction"] == "", what="the sheet to close")
    c.app.see("Quarterly plan")


@scenario("HM-16", "HM-13")
def stopping_asks_only_when_mid_turn(c):
    """A mid-turn stop asks and can be declined; an idle stop does not ask."""
    sid = c.app.dispatch("Mid turn stop, hang", WORKSPACE)
    go(c, sid)
    wait_for(lambda: record(c, sid)["activity"] == "working", 30, "the run to be working")
    c.app.menu("Stop Session")
    asked(c, "stop")
    c.app.press("Cancel")
    wait_for(lambda: c.app.snap()["pendingAction"] == "", what="the question to close")
    check(record(c, sid)["state"] == "Running", "declining must leave the run alone")
    c.app.menu("Stop Session")
    asked(c, "stop")
    c.app.press("Stop Session")
    wait_for(lambda: record(c, sid)["state"] == "Saved", 30, "the session to be saved")

    idle = c.app.dispatch("Idle stop check demo", WORKSPACE)
    go(c, idle)
    wait_for(lambda: record(c, idle)["activity"] == "idle", 40, "the run to finish")
    c.app.menu("Stop Session")
    wait_for(lambda: record(c, idle)["state"] == "Saved", 30, "the idle session to stop")
    check(c.app.snap()["pendingAction"] == "", "an idle stop should not ask")


@scenario("HM-14", "HM-15", "HM-17")
def archive_and_delete_ask_first(c):
    """Archiving a saved row, stop-and-archive of a running one, and delete each ask."""
    saved = c.app.dispatch("Archive saved row demo", WORKSPACE)
    go(c, saved)
    wait_for(lambda: record(c, saved)["activity"] == "idle", 40, "the run to finish")
    c.app.menu("Stop Session")
    wait_for(lambda: record(c, saved)["state"] == "Saved", 30, "the stop")
    c.app.menu("Archive Session…")
    check(asked(c, "archive").endswith("saved:quiet"), "a saved row asks plainly")
    c.app.press("Archive")
    wait_for(lambda: record(c, saved) is None, 30, "the archived session to leave the list")

    running = c.app.dispatch("Archive running row demo", WORKSPACE)
    go(c, running)
    wait_for(lambda: record(c, running)["activity"] == "idle", 40, "the run to finish")
    c.app.menu("Archive Session…")
    check(asked(c, "archive").endswith("running:quiet"), "a running row says it will stop first")
    c.app.press("Stop and Archive")
    wait_for(lambda: record(c, running) is None, 40, "the stopped and archived session to leave")

    doomed = c.app.dispatch("Delete this one demo", WORKSPACE)
    go(c, doomed)
    wait_for(lambda: record(c, doomed)["activity"] == "idle", 40, "the run to finish")
    c.app.menu("Delete Session…")
    time.sleep(0.5)
    check(c.app.snap()["pendingAction"] == "", "a running session cannot be deleted")
    c.app.menu("Stop Session")
    wait_for(lambda: record(c, doomed)["state"] == "Saved", 30, "the stop")
    c.app.menu("Delete Session…")
    asked(c, "delete")
    c.app.press("Cancel")
    wait_for(lambda: c.app.snap()["pendingAction"] == "", what="the question to close")
    check(record(c, doomed) is not None, "declining must keep the session")
    c.app.menu("Delete Session…")
    asked(c, "delete")
    c.app.press("Delete Session")
    wait_for(lambda: record(c, doomed) is None, 30, "the deleted session to leave the list")
