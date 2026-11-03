#!/usr/bin/env python3
"""Retakes the README's screenshots from a test cluster.

Run it with the screen unlocked, after a measure build. It writes docs/images.
"""
import sys
import time

import run
import scenarios
from loomui import ROOT, wait_for
from scenarios import WORKSPACE, pending_approval, scenario, settle

IMAGES = ROOT / "docs/images"


@scenario()
def readme_shots(c):
    """Fills the app with a few sessions and photographs each page."""
    c.app.cmd("resize 1400 900")
    c.app.dispatch("Report the failed fetches please demo", WORKSPACE)
    c.app.dispatch("Tighten the retry budget demo run", "proj", executor="box")
    pending_approval(c, "Publish the release notes")
    # The daemon's node report lags a few seconds, and the card arms after a moment.
    time.sleep(12)
    c.app.shot(IMAGES / "approval.png")

    c.app.go("mission")
    time.sleep(1)
    c.app.shot(IMAGES / "mission.png")
    c.app.go("machines")
    time.sleep(1)
    c.app.shot(IMAGES / "machines.png")
    c.app.cmd("light")
    time.sleep(1)
    c.app.shot(IMAGES / "light.png")
    c.app.cmd("dark")

    c.app.open_session("Tighten the retry budget")
    c.app.transcript_has("Retry budget is now per host", 40)
    settle(c)
    c.app.menu("Toggle Inspector")
    wait_for(lambda: c.app.snap()["showsInspector"], 3, "the inspector")
    c.app.press("Changes")
    c.app.see(r"\d+ changed files?", 20)
    time.sleep(1)
    c.app.shot(IMAGES / "session.png")


if __name__ == "__main__":
    scenarios.ALL[:] = [s for s in scenarios.ALL if s.name == "readme_shots"]
    sys.argv = ["run.py"]
    run.main()
