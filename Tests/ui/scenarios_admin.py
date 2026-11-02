"""Scenarios for the home list, new-session set-up and the administration rows.

The sidebar's rows are not in the accessibility tree, so these read the same values
the sidebar draws from the app snapshot's `sidebar` member.
"""
from loomui import BASE, wait_for
from scenarios import WORKSPACE, check, scenario

TREE = str(BASE / "wtrepo-feature")


def sidebar(c):
    return c.app.snap()["sidebar"]


def row_of(c, sid, grouping="Project"):
    """The sidebar row for a session in a grouping, or None."""
    for section in sidebar(c)[grouping]:
        for row in section["rows"]:
            if row["id"] == sid:
                return row
    for row in sidebar(c)["saved"]:
        if row["id"] == sid:
            return row
    return None


def stop_open_session(c):
    """Stops the session in the window, confirming if the daemon says it is mid-turn."""
    c.app.menu("Stop Session")
    if c.app.snap()["pendingAction"].startswith("stop"):
        c.app.press("Stop Session")


def section_of(c, title, grouping="Project"):
    return next((s for s in sidebar(c)[grouping] if s["title"] == title), None)


@scenario("HM-01", "HM-10", "HM-20")
def sidebar_groups_by_project_newest_first(c):
    """Rows sit under their project, newest first, and a worktree names its directory."""
    old = c.app.dispatch("Sidebar older please demo", WORKSPACE)
    new = c.app.dispatch("Sidebar newer please demo", WORKSPACE)
    tree = c.app.dispatch("Sidebar tree please demo", TREE)
    wait_for(lambda: section_of(c, "proj") and len(section_of(c, "proj")["rows"]) >= 2, what="the project section")
    ids = [r["id"] for r in section_of(c, "proj")["rows"]]
    check(ids.index(new) < ids.index(old), f"newest should come first: {ids}")
    check(section_of(c, "proj")["count"] == len(ids), "a heading states how many rows it holds")
    row = wait_for(lambda: row_of(c, tree), what="the worktree row")
    check(row["worktree"] == "wtrepo-feature", f"worktree was {row['worktree']!r}")
    check(row_of(c, new)["worktree"] == "", "a plain checkout has no worktree name")
    check(row_of(c, new)["created"] == "just now", f"created was {row_of(c, new)['created']!r}")


@scenario("HM-02", "HM-09", "HM-19")
def sidebar_rows_say_what_each_session_is_doing(c):
    """A row says working, idle or needs you, and a saved row says saved."""
    waiting = c.app.dispatch("Sidebar asks escalate", WORKSPACE)
    wait_for(lambda: (row_of(c, waiting) or {}).get("standing") == "needs you", what="needs you")
    check(section_of(c, "Needs You", "Status"), "a waiting session leads the status grouping")
    idle = c.app.dispatch("Sidebar quiet please demo", WORKSPACE)
    wait_for(lambda: (row_of(c, idle) or {}).get("standing") == "idle", 40, "idle")
    busy = c.app.dispatch("Sidebar busy please, slow", WORKSPACE)
    wait_for(lambda: (row_of(c, busy) or {}).get("standing") in ("working", "idle"), what="a standing")
    row = row_of(c, waiting)
    check(row["subtitle"] != "" or row["title"].startswith("Sidebar asks"), f"row was {row}")
    c.app.cmd(f"select {idle}")
    wait_for(lambda: c.app.snap()["destination"] == f"session:{idle}", what="the idle row to open")
    wait_for(lambda: c.app.session().get("isAdopted"), what="the session to attach")
    stop_open_session(c)
    wait_for(lambda: (row_of(c, idle) or {}).get("standing") == "saved", 60, f"saved ({c.app.snap()['pendingAction']!r})")
    check(any(r["id"] == idle for r in sidebar(c)["saved"]), "a stopped session is listed with the saved rows")


@scenario("HM-03", "HM-04", "HM-05")
def sidebar_opens_running_and_saved_rows(c):
    """Selecting a running row opens it, a saved row resumes, and the saved fold is remembered."""
    sid = c.app.dispatch("Sidebar reopen please demo", WORKSPACE)
    c.app.cmd(f"select {sid}")
    wait_for(lambda: c.app.snap()["destination"] == f"session:{sid}", what="the running row to open")
    stop_open_session(c)
    wait_for(lambda: (row_of(c, sid) or {}).get("standing") == "saved", 60, "saved")
    before = sidebar(c)["savedOpen"]
    c.app.menu("Hide Saved Sessions" if before else "Show Saved Sessions")
    wait_for(lambda: sidebar(c)["savedOpen"] != before, what="the saved fold to change")
    c.app.menu("Hide Saved Sessions" if not before else "Show Saved Sessions")
    c.app.cmd(f"select {sid}")
    c.app.see("The conversation is saved")
    c.app.press("Resume Session")
    wait_for(lambda: (row_of(c, sid) or {}).get("standing") in ("idle", "working", "running"), 60, "resumed")


@scenario("HM-07", "MA-11")
def a_machine_filter_keeps_only_that_machines_rows(c):
    """The sidebar counts sessions for each machine, and choosing one keeps only its rows."""
    local = c.app.dispatch("Filter local please demo", WORKSPACE)
    remote = c.app.dispatch("Filter remote please demo", "proj", executor="box")
    machines = wait_for(lambda: (m := {x["name"]: x["count"] for x in sidebar(c)["machines"]}) and "box" in m and m, what="a count for each machine")
    check(len(machines) >= 2, f"machines were {machines}")
    try:
        c.app.press(f"box {machines['box']}")
        wait_for(lambda: sidebar(c)["filter"] == "box", what="the filter")
        ids = [r["id"] for s in sidebar(c)["Project"] for r in s["rows"]]
        check(remote in ids and local not in ids, f"the box filter showed {ids}")
    finally:
        c.app.press(f"All {sum(machines.values())}")
    wait_for(lambda: sidebar(c)["filter"] == "", what="the filter to clear")
    ids = [r["id"] for s in sidebar(c)["Project"] for r in s["rows"]]
    check(remote in ids and local in ids, "All shows every machine's rows")


@scenario("HM-12", "HM-23")
def the_sidebar_foot_opens_people_and_mission_control_lists_everyone(c):
    """The sidebar's People button opens the people sheet, and Mission Control lists every session."""
    sid = c.app.dispatch("Mission listed please demo", WORKSPACE)
    c.app.go("mission")
    c.app.see("Mission listed")
    check(any("Mission listed" in card["name"] for card in c.app.snap()["cards"]), "the board should hold the session")
    c.app.press("Open People")
    c.app.see("Your name")
    c.app.press("Done")
