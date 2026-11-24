"""Scenarios for project mode: the Projects destination, the tickets that wait on a person
in the inbox, and a ticket's pane with its controls.

The cluster's orchestrator holds a repository, `project-ws`, with one commit, and a
`[project]` check that always fails (scripts/dev-cluster.sh). The scripted model plays the
router, which accepts the first message it is offered, and the worker, which asks a question
and stops, or, when the post says "commit then wait", commits a file and reports waiting, so
the check rejects the head and the ticket reads `person/check`.

A project is made, and work posted, through the driver's `projectraw`, since creating one in
the app is its own change. Everything else goes through what a person uses: the pane's
controls are pressed by name, and the daemon's own answers are read back from the app's
`projects` snapshot, which is encoded by the same rule the view draws from.
"""
import json
import os
from pathlib import Path

from loomui import BASE, wait_for
from scenarios import check, scenario

TICKET_WAIT = 90


def shoot(c, name):
    """Saves a capture when LOOM_UITEST_SHOTS names a directory. A run that does not asks nothing of the screen."""
    where = os.environ.get("LOOM_UITEST_SHOTS")
    if where:
        Path(where).mkdir(parents=True, exist_ok=True)
        c.app.shot(Path(where) / f"{name}.png")


def raw(c, command, body):
    reply = c.app.cmd(f"projectraw {command} {json.dumps(body)}", timeout=30)
    check(not reply.startswith("error"), f"{command} was refused: {reply}")
    return json.loads(reply)


def project(c):
    """The cluster's project, made once and found again after."""
    made = raw(c, "projects.create", {"workspace": str(BASE / "project-ws"), "name": "project-ws"})
    return made["project"]


def tickets(c, project_id):
    for each in c.app.snap()["projects"]["projects"]:
        if each["id"] == project_id:
            return each["tickets"]
    return []


def wait_ticket(c, project_id, stage, title="Fix the retry loop"):
    return wait_for(
        lambda: next((t for t in tickets(c, project_id) if t["stage"] == stage and t["title"] == title), None),
        TICKET_WAIT, f"a ticket at {stage}",
    )


def open_ticket_thread(c, project_id, ticket):
    """Opens a ticket's thread in the inbox as a click on its row does."""
    row = f"ticket/{project_id}/{ticket['id']}"
    wait_for(lambda: any(r["id"] == row for g in c.app.snap()["inbox"]["groups"] for r in g["rows"]), 30, f"the row {row}")
    c.app.go("inbox")
    c.app.cmd("inboxpick " + row)
    c.app.see(r"The worker asks|The check|Why it waits", 15)


@scenario("PJ-01", "PJ-02", "PJ-03", "PJ-04", "PJ-05")
def a_project_is_made_work_is_posted_and_its_ticket_is_acted_on(c):
    """A project's ticket reaches the inbox, is answered, fails its check, and is closed."""
    pid = project(c)
    wait_for(lambda: any(p["id"] == pid for p in c.app.snap()["projects"]["projects"]), 30, "the project in the list")

    # The router accepts the first message, and the worker asks its question.
    raw(c, "projects.post", {"project": pid, "request_id": "post-question", "text": "fix the retry loop"})
    asked = wait_ticket(c, pid, "person/answer")
    check("Answer" in asked["actions"], f"the daemon lists answer: {asked}")

    # The Projects destination groups the ticket under the daemon's own stage word.
    c.app.go("projects")
    c.app.cmd(f"projectpick {pid}")
    c.app.see("Router running|Router saved", 15)
    c.app.see("Not routed")
    c.app.see("Workers")
    shoot(c, "projects-router-page")
    shown = c.app.snap()["projects"]
    entry = next(p for p in shown["projects"] if p["id"] == pid)
    check("person/answer" in entry["countWords"], f"the counts read in the daemon's words: {entry['countWords']}")
    check(entry["router"], "the project names its router session")

    # The router and the worker are reached from the project, so the conversation list and the
    # inbox's session threads leave them out while neither waits on the owner.
    snap = c.app.snap()
    listed = {row["id"] for grouping in ("status", "project", "machine") for section in snap["sidebar"].get(grouping, [])
              for row in section["rows"]}
    inbox_ids = {row["id"] for group in snap["inbox"]["groups"] for row in group["rows"]}
    for session in {entry["router"], asked["session"]} - {""}:
        check(session not in listed, f"the sidebar lists the project session {session}")
        check(f"session/{session}" not in inbox_ids, f"the inbox lists the project session {session}")

    # A ticket that waits on an answer is a thread under Needs you, with no session of its own.
    open_ticket_thread(c, pid, asked)
    groups = c.app.snap()["inbox"]["groups"]
    needs = next(g for g in groups if g["title"] == "Needs you")
    mine = [r for r in needs["rows"] if r["id"] == f"ticket/{pid}/{asked['id']}"]
    check(mine and mine[0]["kind"] == "Ticket", f"the ticket is a Needs you row: {needs}")
    check("person/answer" in mine[0]["head"], "the row keeps the daemon's stage word")
    c.app.see("Which database should the retry log use")
    c.app.see("Untrusted text from the worker")
    shoot(c, "inbox-ticket-question")

    # The answer button waits for words, then sends them with the question's number.
    check(not c.app.enabled("Answer"), "an empty answer cannot be sent")
    c.app.cmd(f"ticketdraft {pid} {asked['id']} sqlite")
    wait_for(lambda: c.app.enabled("Answer"), 5, "the Answer button to arm")
    c.app.press("Answer")

    # The daemon takes it, and the worker's next report is a new question or none, so
    # the question the ticket held is not the one it holds now. The row may leave the
    # inbox in between, which ends the pane's own notice with it.
    wait_for(
        lambda: next((t for t in tickets(c, pid) if t["id"] == asked["id"] and t["question"] != asked["question"]), None),
        TICKET_WAIT, "the answered question to be replaced",
    )

    # A second post commits a file and waits. The check fails, and the ticket needs a person.
    raw(c, "projects.post", {"project": pid, "request_id": "post-commit", "text": "commit then wait: add a retry log"})
    failed = wait_for(
        lambda: next((t for t in tickets(c, pid) if t["stage"] == "person/check"), None), TICKET_WAIT, "a ticket at person/check",
    )
    check("Check Again" in failed["actions"] and "Close Ticket" in failed["actions"], f"the check's actions come from the daemon: {failed}")
    check("Publish" not in failed["actions"], "the daemon does not list publish, since the project's publish setting is off by default")

    # The failed check is a ticket to read: under To review, with the output and its cause.
    row = f"ticket/{pid}/{failed['id']}"
    wait_for(lambda: any(r["id"] == row for g in c.app.snap()["inbox"]["groups"] if g["title"] == "To review" for r in g["rows"]), 30, "a To review row")
    c.app.go("inbox")
    c.app.cmd("inboxpick " + row)
    c.app.see("The check")
    c.app.see(r"Failed, cause: test")
    c.app.see(r"2 tests failed")
    c.app.see("Output, as the check printed it")
    check(not c.app.enabled("Publish"), "no Publish control is drawn for a ticket whose actions do not list it")
    shoot(c, "inbox-ticket-failed-check")

    # The same pane is on the Projects destination, where it stays while the ticket's stage
    # changes under it. Check Again is sent at once. Close asks once on a button that names it.
    c.app.go("projects")
    c.app.cmd(f"projectpick {pid} {failed['id']}")
    c.app.see("The check")
    shoot(c, "projects-ticket-check")
    c.app.press("Check Again")
    c.app.see("Check started")
    c.app.press("Close Ticket")
    c.app.see("Accepts the work and ends the ticket")
    c.app.press("Confirm Close Ticket")
    wait_for(lambda: any(t["id"] == failed["id"] and t["stage"].startswith("ended/") for t in tickets(c, pid)), 30, "the ticket to end")
    check(not any(r["id"] == row for g in c.app.snap()["inbox"]["groups"] for r in g["rows"]), "an ended ticket leaves the inbox")

    # Stop ends the first ticket too, so a later scenario starts with nothing waiting.
    c.app.cmd(f"projectpick {pid} {asked['id']}")
    c.app.press("Stop")
    c.app.press("Confirm Stop")
    wait_for(lambda: any(t["id"] == asked["id"] and t["stage"].startswith("ended/") for t in tickets(c, pid)), 30, "the first ticket to end")


def settings_value(c, pid, key):
    body = raw(c, "projects.settings", {"project": pid})
    return next(s["value"] for s in body["settings"] if s["key"] == key)


@scenario("PJ-07", "PJ-08", "PJ-09")
def a_project_is_created_set_up_and_given_work(c):
    """The new-project sheet makes a project, saves its check, and the composer's request becomes a ticket."""
    import subprocess

    repo = BASE / "create-ws"
    if not repo.exists():
        repo.mkdir(parents=True)
        (repo / "Makefile").write_text("unit:\n\ttrue\n\ntest:\n\ttrue\n")
        git = ["git", "-C", str(repo), "-c", "user.name=loom", "-c", "user.email=loom@example.com"]
        subprocess.run(["git", "-C", str(repo), "init", "-q", "-b", "main"], check=True)
        subprocess.run(git + ["add", "Makefile"], check=True)
        subprocess.run(git + ["commit", "-q", "-m", "seed"], check=True)

    # The palette offers the destination and the new-project sheet.
    c.app.cmd("palette open")
    c.app.see("Routers, tickets and workers")
    c.app.see("Make a project for a folder")
    c.app.cmd("palette close")

    # Step one chooses the folder. A folder that does not exist is refused in words.
    c.app.go("projects")
    c.app.press("New Project")
    c.app.cmd("projectfield new/folder /no/such/folder")
    c.app.see("That folder doesn't exist")
    check(not c.app.enabled("Create Project"), "a missing folder cannot be made a project")
    c.app.cmd(f"projectfield new/folder {repo}")
    wait_for(lambda: c.app.enabled("Create Project"), 5, "Create Project to arm")
    c.app.press("Create Project")

    # Step two shows what the daemon suggests, which ran nothing, and saves what was edited.
    c.app.see("Nothing has run")
    c.app.see(r"Check: .*Makefile|suggests no check")
    shoot(c, "new-project-settings")
    c.app.cmd("projectfield new/check make unit")
    c.app.press("Save Check and Setup")
    pid = next(p["id"] for p in c.app.snap()["projects"]["projects"] if p["name"] == "create-ws")
    wait_for(lambda: settings_value(c, pid, "check") == ["make unit"], 15, "the check to be saved")
    wait_for(lambda: not c.app.snap()["projects"]["creating"], 15, "the sheet to close")
    check(settings_value(c, pid, "check") == ["make unit"], "the daemon holds the saved check")

    # The project's page reads the settings back with where each value comes from.
    c.app.see("set for this project")
    c.app.see("Request work")
    shoot(c, "project-page-settings")

    # The composer posts a request, which the router turns into a ticket.
    c.app.cmd(f"projectfield post/{pid} fix the retry loop")
    wait_for(lambda: c.app.enabled("Post Request"), 5, "Post Request to arm")
    c.app.press("Post Request")
    c.app.see("Posted. The router reads it next")
    asked = wait_ticket(c, pid, "person/answer")

    # Closing from the inbox moves the ticket out of it, and the pane that replaces the
    # row still says what was done and where the ticket is now.
    open_ticket_thread(c, pid, asked)
    c.app.press("Close Ticket")
    c.app.press("Confirm Close Ticket")
    wait_for(lambda: any(t["id"] == asked["id"] and t["stage"].startswith("ended/") for t in tickets(c, pid)), 30, "the ticket to end")
    c.app.see(r"Closed . the ticket is now ended/closed")
    shoot(c, "inbox-resolved-ticket-result")
    check(
        c.app.snap()["projects"]["results"].get(f"{pid}/{asked['id']}", "").startswith("Closed"),
        "the result is kept for the ticket",
    )


@scenario("PJ-10")
def a_tickets_changes_are_drawn_as_a_diff(c):
    """A worker's uncommitted edit and its committed file are both drawn as the ticket's diff."""
    pid = project(c)
    known = {t["id"] for t in tickets(c, pid)}

    def fresh(stage):
        return wait_for(
            lambda: next((t for t in tickets(c, pid) if t["id"] not in known and t["stage"] == stage), None),
            TICKET_WAIT, f"a new ticket at {stage}",
        )

    # An edit left uncommitted in the worker's clone is a worktree diff against its head.
    raw(c, "projects.post", {"project": pid, "request_id": "post-edit", "text": "edit then wait: raise the retry count"})
    edited = fresh("person/answer")
    known.add(edited["id"])
    c.app.go("projects")
    c.app.cmd(f"projectpick {pid} {edited['id']}")
    c.app.see("Changes")
    c.app.see("review-file/a.gleam|a.gleam", 30)
    c.app.see("Read from the worker's session")
    shoot(c, "projects-ticket-diff")

    # A file the worker committed is in the daemon's read too.
    raw(c, "projects.post", {"project": pid, "request_id": "post-commit-2", "text": "commit then wait: add a retry log"})
    committed = fresh("person/check")
    c.app.cmd(f"projectpick {pid} {committed['id']}")
    c.app.see("review-file/retry.log|retry.log", 30)

    for ticket in (edited, committed):
        c.app.cmd(f"projectpick {pid} {ticket['id']}")
        c.app.press("Stop")
        c.app.press("Confirm Stop")
        wait_for(lambda: any(t["id"] == ticket["id"] and t["stage"].startswith("ended/") for t in tickets(c, pid)), 30, "the ticket to end")
