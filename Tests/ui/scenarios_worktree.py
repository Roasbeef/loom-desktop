"""Scenarios for the per-session worktree choice (loom's protocol-change/133): the
Worktree toggle on the new-session form, and a session created in a worktree of its own.

The form's judgement of the choice needs no particular daemon, so it is proven against
any. A session actually created in a worktree needs a daemon that serves
protocol-change/133. The pinned harness daemon predates it and answers a creation that
asks for a worktree as an ordinary session, which the app detects from the reply and
reports as 'too old'. The scenario treats that report as a reason not to run, counted as
blocked and not as passed.
"""
import os
import subprocess
from pathlib import Path

from loomui import BASE, Unproven, wait_for
from scenarios import check, scenario
from scenarios_lifecycle import choose_folder, choose_placement, close_form, open_form, picker_closed, record, scratch_folder, find_box_label

TOO_OLD = "too old to start a session in its own worktree"
NOT_A_REPOSITORY = "A worktree needs the top folder of a Git repository"


def shoot(c, name):
    """Saves a capture in each appearance when LOOM_UITEST_SHOTS names a directory."""
    where = os.environ.get("LOOM_UITEST_SHOTS")
    if not where:
        return
    Path(where).mkdir(parents=True, exist_ok=True)
    for appearance in ("light", "dark"):
        c.app.appearance(appearance)
        wait_for(lambda: True, what="the appearance")
        c.app.shot(Path(where) / f"{name}-{appearance}.png")
    c.app.appearance("light")


def worktree_toggle(c):
    """The Worktree toggle's accessibility node, or None while the form does not draw it."""
    return next((n for n in c.app.tree() if n["name"] == "Worktree"), None)


def repository(name):
    """A folder that is the top of a primary checkout with one commit, so `HEAD` resolves."""
    path = Path(BASE) / name
    if not (path / ".git").exists():
        path.mkdir(parents=True, exist_ok=True)
        git = ["git", "-C", str(path), "-c", "user.name=Loom Test", "-c", "user.email=test@example.invalid"]
        subprocess.run(git + ["init", "-q"], check=True)
        (path / "README.md").write_text("a repository\n")
        subprocess.run(git + ["add", "README.md"], check=True)
        subprocess.run(git + ["commit", "-q", "-m", "first"], check=True)
    return str(path.resolve())


@scenario("NS-23")
def the_worktree_toggle_is_off_by_default_local_only_and_judges_the_folder(c):
    """The toggle shows for a local folder, starts off, names a folder that cannot hold a worktree, and takes a base."""
    plain = scratch_folder("worktree-plain")
    repo = repository("worktree-repo")
    open_form(c)
    try:
        c.app.focus("Prompt")
        c.app.type("Worktree form demo")
        choose_folder(c, plain)
        wait_for(lambda: worktree_toggle(c), what="the Worktree toggle")
        check(worktree_toggle(c)["value"] == "off", f"the toggle should start off: {worktree_toggle(c)}")
        c.app.not_see("Worktree base")
        wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed with the toggle off")

        # On, a folder that is not a repository is named, and nothing can be sent.
        c.app.press("Worktree")
        wait_for(lambda: worktree_toggle(c)["value"] == "on", what="the toggle to turn on")
        c.app.see(NOT_A_REPOSITORY)
        check(not c.app.enabled("Dispatch"), "a folder that is not a repository should not allow a worktree dispatch")

        # A repository is accepted, and the base sits behind a disclosure.
        choose_folder(c, repo)
        wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed for a repository")
        c.app.not_see(NOT_A_REPOSITORY)
        c.app.press("Worktree base disclosure")
        c.app.fill("Worktree base", "-bad")
        c.app.see("cannot start with a dash")
        check(not c.app.enabled("Dispatch"), "a base that starts with a dash should not allow dispatch")
        c.app.fill("Worktree base", "HEAD")
        c.app.not_see("cannot start with a dash")
        wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed for a good base")
        shoot(c, "worktree-form")

        # Turning it off again sends nothing about a worktree.
        c.app.press("Worktree")
        wait_for(lambda: worktree_toggle(c)["value"] == "off", what="the toggle to turn off")
        c.app.not_see("Worktree base")

        # An executor's workspace chooses its own mode, so the toggle is not drawn.
        choose_placement(c, "box")
        wait_for(lambda: worktree_toggle(c) is None, what="the toggle to leave for an executor")
    finally:
        close_form(c)


@scenario("NS-24")
def a_session_created_in_a_worktree_shows_its_branch_in_the_header_and_the_sidebar(c):
    """The daemon's worktree reply is what the header and the sidebar row say, and the workspace stays the folder."""
    repo = repository("worktree-session-repo")
    open_form(c)
    try:
        c.app.focus("Prompt")
        c.app.type("Worktree session demo")
        choose_folder(c, repo)
        c.app.press("Worktree")
        wait_for(lambda: worktree_toggle(c)["value"] == "on", what="the toggle to turn on")
        wait_for(lambda: c.app.enabled("Dispatch"), what="Dispatch to be allowed")
        c.app.press("Dispatch")

        # Either the form closes on the new session, or the app says the daemon ignored
        # the request, which is the harness daemon from before protocol-change/133.
        def outcome():
            if not c.app.snap()["isDispatching"]:
                return "created"
            return "too old" if any(TOO_OLD in t for t in c.app.texts()) else None
        if wait_for(outcome, 60, "the form to close or name a daemon too old") == "too old":
            raise Unproven("the daemon does not serve protocol-change/133, so it started the session in the folder and the app removed it")
    finally:
        close_form(c)

    sid = c.app.session_id("Worktree session demo")
    row = wait_for(lambda: record(c, sid), what="the session in the list")
    check(row["workspace"] == repo, f"the workspace should stay the folder: {row}")
    check(row["worktreeBranch"] == f"loom/{sid}", f"the branch is loom/<id>: {row}")
    check(row["worktreeBase"] == "HEAD", f"the default base is HEAD: {row}")

    # The sidebar row says it has a worktree, and its tooltip names the branch.
    sidebar = c.app.snap()["sidebar"]
    rows = [r for group in sidebar["Status"] for r in group["rows"]] + sidebar["saved"]
    mine = next((r for r in rows if r["id"] == sid), None)
    check(mine is not None, "the session should be in the sidebar")
    check(mine["ownBranch"] == f"loom/{sid}", f"the row names the branch: {mine}")
    check(f"loom/{sid}" in mine["ownWorktreeHelp"], f"the tooltip names the branch: {mine}")

    # The page's header names the folder and the branch.
    c.app.open_session("Worktree session demo")
    wait_for(lambda: f"worktree loom/{sid}" in c.app.session().get("placeLine", ""), what="the header to name the branch")
    check(c.app.session()["placeLine"].startswith(Path(repo).name), f"the header leads with the folder: {c.app.session()['placeLine']}")
    shoot(c, "worktree-session")
