"""Scenarios that take the executor down. They run before the scenario that reports
the loss, and later scenarios find the executor already gone."""
from loomui import wait_for
from scenarios import WORKSPACE, check, scenario
from scenarios_admin import close_form, open_form, second_daemon
from scenarios_lifecycle import find_box_label


@scenario("NS-05", "NS-11", "NS-21", "MA-03")
def a_down_machine_is_named_and_may_still_be_chosen(c):
    """A down executor and an unreachable daemon are named in the form, the executor can still be chosen, and the Machines page says it is not linked."""
    second_daemon(c)
    try:
        c.cluster.kill("exec")
        wait_for(
            lambda: any(n["name"] == "box" and n["state"] == "down" for d in c.app.snap()["daemons"] for n in d["nodes"]),
            40, "box to read down",
        )
        wait_for(lambda: any(d["label"] == "other" and d["state"] == "unavailable" for d in c.app.snap()["daemons"]), 40, "the second daemon to read unavailable")
        c.app.go("machines")
        c.app.see("Not linked from here")
        open_form(c)
        try:
            c.app.see(r"other · unavailable")
            c.app.press(find_box_label(c))
            c.app.see(r"box is down\. The session will wait")
            c.app.focus("Prompt")
            c.app.type("Down executor check demo")
            c.app.fill("Folder", "proj")
            wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed")
            c.app.press("Dispatch")
            c.app.see("The session was created, but its message was not sent", 90)
            c.app.press("Open the session")
            wait_for(lambda: not c.app.snap()["isDispatching"], what="the form to close")
        finally:
            close_form(c)
        check(c.app.snap()["destination"].startswith("session:"), "Open the session should show the session")
    finally:
        c.app.cmd("unattach other")
