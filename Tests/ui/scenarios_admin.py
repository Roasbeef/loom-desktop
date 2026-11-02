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


@scenario("HM-01", "HM-10")
def sidebar_groups_by_project_newest_first(c):
    """Rows sit under their project, newest first, and a worktree names its directory."""
    old = c.app.dispatch("Sidebar older please demo", WORKSPACE)
    new = c.app.dispatch("Sidebar newer please demo", WORKSPACE)
    tree = c.app.dispatch("Sidebar tree please demo", TREE)
    wait_for(
        lambda: section_of(c, "proj") and len(section_of(c, "proj")["rows"]) >= 2,
        what=f"the project section (sections: {[s['title'] for s in sidebar(c)['Project']]}, daemons: {[(d['label'], d['state'], len(d['sessions'])) for d in c.app.snap()['daemons']]})",
    )
    ids = [r["id"] for r in section_of(c, "proj")["rows"]]
    check(ids.index(new) < ids.index(old), f"newest should come first: {ids}")
    check(section_of(c, "proj")["count"] == len(ids), "a heading states how many rows it holds")
    row = wait_for(lambda: row_of(c, tree), what="the worktree row")
    check(row["worktree"] == "wtrepo-feature", f"worktree was {row['worktree']!r}")
    check(row_of(c, new)["worktree"] == "", "a plain checkout has no worktree name")
    check(row_of(c, new)["created"] == "just now", f"created was {row_of(c, new)['created']!r}")


@scenario("HM-02")
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


@scenario("HM-04", "HM-05")
def sidebar_opens_running_and_saved_rows(c):
    """Selecting a running row opens it, a saved row resumes, and the saved fold is remembered."""
    sid = c.app.dispatch("Sidebar reopen please demo", WORKSPACE)
    c.app.cmd(f"select {sid}")
    wait_for(lambda: c.app.snap()["destination"] == f"session:{sid}", what="the running row to open")
    stop_open_session(c)
    wait_for(lambda: (row_of(c, sid) or {}).get("standing") == "saved", 60, "saved")
    before = sidebar(c)["savedOpen"]
    c.app.menu("Toggle Saved Sessions")
    wait_for(lambda: sidebar(c)["savedOpen"] != before, what="the saved fold to change")
    c.app.menu("Toggle Saved Sessions")
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


# A second daemon, reached directly.


def second_daemon(c, name="other"):
    """Connects the executor's daemon as a second daemon, without saving it."""
    from loomui import SLOT
    token = (BASE / "exec/.loom/owner.token").read_text().strip()
    (c.app.dir / "token").write_text(token)
    reply = c.app.cmd(f"attach {name} ws://127.0.0.1:{7442 + SLOT * 10}")
    check(not reply.startswith("error"), reply)
    wait_for(lambda: any(d["label"] == name and d["state"] == "connected" for d in c.app.snap()["daemons"]), 30, "the second daemon")


def open_form(c):
    c.app.menu("New Agent…")
    wait_for(lambda: c.app.snap()["isDispatching"], what="the new-session form")


def close_form(c):
    if c.app.snap()["isDispatching"]:
        c.app.key("escape")
        wait_for(lambda: not c.app.snap()["isDispatching"], what="the form to close")


@scenario("NS-04", "NS-22", "MA-15")
def a_session_starts_on_another_daemon(c):
    """With a second daemon connected, the form offers it, and the session is created there."""
    second_daemon(c)
    try:
        # With two daemons the sidebar's foot names each by its label.
        c.app.see(r"^other$", 10)
        open_form(c)
        try:
            c.app.press("other")
            c.app.focus("Prompt")
            c.app.type("Other daemon check demo")
            c.app.fill("Folder", WORKSPACE)
            c.app.fill("Configuration", str(BASE / "orch/.loom/loom.toml"))
            wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed")
            c.app.press("Dispatch")
            wait_for(lambda: not c.app.snap()["isDispatching"], 60, "the form to close")
        finally:
            close_form(c)
        other = next(d for d in c.app.snap()["daemons"] if d["label"] == "other")
        wait_for(lambda: any("Other daemon check" in s["title"] for s in next(d for d in c.app.snap()["daemons"] if d["label"] == "other")["sessions"]), 30, "the session on the second daemon")
    finally:
        c.app.cmd("unattach other")


# Settings.


@scenario("SE-01")
def appearance_follows_the_menu_choice(c):
    """Light, dark and system appearance are chosen from the View menu and take effect at once."""
    try:
        c.app.menu("Use Light Appearance")
        wait_for(lambda: (s := c.app.snap())["appearance"] == "light" and s["effectiveAppearance"] == "light", what="light")
        c.app.menu("Use Dark Appearance")
        wait_for(lambda: (s := c.app.snap())["appearance"] == "dark" and s["effectiveAppearance"] == "dark", what="dark")
    finally:
        c.app.menu("Use System Appearance")
        c.app.appearance("dark")
    check(c.app.snap()["appearance"] == "system", "the choice should return to the system's")


@scenario()
def the_inspector_stays_open_across_launches(c):
    """The inspector column is open again after the app is quit and started."""
    if not c.app.snap()["showsInspector"]:
        c.app.menu("Toggle Inspector")
    wait_for(lambda: c.app.snap()["showsInspector"], what="the inspector to open")
    try:
        c.app.quit()
        c.app.launch()
        wait_for(lambda: c.app.snap()["showsInspector"], what="the inspector to be open after the start")
    finally:
        if c.app.snap()["showsInspector"]:
            c.app.menu("Toggle Inspector")


# Accepting an invitation.


@scenario("SH-07")
def an_invitation_is_accepted_with_its_claim(c):
    """Pasting an invitation's claim token and address connects as the invited person, who sees the shared session."""
    import re
    from scenarios_lifecycle import invite, make_shareable
    sid = c.app.dispatch("Claim subject please demo", WORKSPACE)
    wait_for(lambda: next(s for s in c.app.sessions() if s["id"] == sid)["activity"] == "idle", 60, "the run to finish")
    make_shareable(c, sid)
    invite(c, "Claire", "Observer")
    claim = address = None
    def read():
        nonlocal claim, address
        for text in c.app.texts():
            if m := re.search(r"(loomclaim_[0-9a-f]{64})", text):
                claim = m.group(1)
            if m := re.search(r"(ws://127\.0\.0\.1:\d+)/v2/claim", text):
                address = m.group(1)
        return claim and address
    wait_for(read, what="the claim token and address")
    c.app.press("I've Sent It")
    c.app.press("Done")
    try:
        c.app.menu("Connect a Daemon…")
        wait_for(lambda: c.app.snap()["isAddingDaemon"], what="the sheet")
        c.app.fill("Daemon name", "claimed")
        c.app.fill("Daemon address", address)
        c.app.fill("Credential", claim)
        c.app.press("Connect")
        wait_for(lambda: not c.app.snap()["isAddingDaemon"], 30, "the sheet to close")
        wait_for(
            lambda: any(d["label"] == "claimed" and d["state"] == "connected" and any("Claim subject" in s["title"] for s in d["sessions"]) for d in c.app.snap()["daemons"]),
            40, "the invited person to see the shared session",
        )
    finally:
        c.app.cmd("unattach claimed")
        if c.app.snap()["isAddingDaemon"]:
            c.app.key("escape")


@scenario("NS-20")
def a_refused_creation_is_worded(c):
    """A workspace name the executor has not registered is refused in plain words, and no session is made."""
    open_form(c)
    try:
        from scenarios_lifecycle import find_box_label
        c.app.press(find_box_label(c, "box ·"))
        c.app.focus("Prompt")
        c.app.type("Refusal check demo")
        c.app.fill("Folder", "unregistered")
        wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed")
        c.app.press("Dispatch")
        c.app.see(r"The session was created but did not open.*serves no workspace named", 30)
        c.app.not_see(r"start_failed|executor_unavailable")
    finally:
        close_form(c)
