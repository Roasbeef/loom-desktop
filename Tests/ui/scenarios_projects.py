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
