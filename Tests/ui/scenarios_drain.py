"""The scenario that drains the orchestrator.

It is apart from the others because it ends the daemon they share and starts it again.
"""
from loomui import wait_for
from scenarios import WORKSPACE, busy_session, check, daemon_state, scenario, send_line


@scenario("CO-14")
def a_held_prompt_comes_back_when_the_daemon_drains(c):
    """A queued prompt the draining daemon hands back is put in the editor, with a warning that says why."""
    busy_session(c, "Drained")
    send_line(c, "finish the report")
    wait_for(lambda: c.app.session()["pendingInputs"], 10, "the held input")
    reply = c.app.cmd("shutdown")
    check(reply == "ok", reply)
    wait_for(lambda: "finish the report" in c.app.session()["draft"], 30, "the held prompt to return")
    note = c.app.session()["notice"]
    check("came back because the daemon is stopping" in note and c.app.session()["noticeIsWarning"], note)
    c.app.see(r"came back because the daemon is stopping", 5)

    # The orchestrator is started again for the scenarios that follow, and the app finds it.
    wait_for(lambda: daemon_state(c)["state"] == "unavailable", 60, "the daemon to read gone")
    c.cluster.restart_orch()
    wait_for(lambda: daemon_state(c)["state"] == "connected", 90, "the app to reconnect")
