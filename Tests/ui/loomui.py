"""A test client for the running app, built on its debug driver.

Everything here addresses the app by meaning: state comes from `snapshot`, controls
are found by accessibility name, and waits poll for a condition rather than sleep. A
test that passes here still passes after a layout change, and one that fails names
what a person would have seen.
"""
import json
import os
import random
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TIMEOUT = 15.0

# Independent runs take different slots, so they share no ports, paths or node names.
SLOT = int(os.environ.get("LOOM_UITEST_SLOT", "0"))
BASE = Path(f"/tmp/loom-uitest-{SLOT}")


class Failure(AssertionError):
    pass


def wait_for(condition, timeout=DEFAULT_TIMEOUT, what="condition", every=0.1):
    """Polls until `condition` returns something true, and returns it."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = condition()
        if last:
            return last
        time.sleep(every)
    raise Failure(f"timed out after {timeout}s waiting for {what} (last: {last!r})")


def screen_locked():
    """Whether the session's screen is locked. A locked screen composites nothing,
    so a capture is blank and frames stop, and pixel checks prove nothing."""
    out = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, text=True).stdout
    key = "<key>CGSSessionScreenIsLocked</key>"
    return key in out and out.split(key, 1)[1].lstrip().startswith("<true/>")


class Cluster:
    """A real orchestrator and executor with the scripted model, on throwaway paths."""

    def __init__(self, base):
        self.base = Path(base)
        self.state = self.base / "orch/.loom"

    def _stop_daemons(self):
        # The pid files name the wrapper, and the VM it starts can outlive a signal
        # to it, or a killed run, and hold the slot's ports. The base path is unique
        # to the slot, so this matches only this cluster's processes.
        subprocess.run(["pkill", "-f", f"{self.base}/(orch|exec)/.loom/loom.toml"], check=False)

    def start(self):
        self._stop_daemons()
        if self.base.exists():
            shutil.rmtree(self.base)
        env = dict(os.environ)
        env["PATH"] = f"/usr/local/bin:{Path.home()}/.local/bin:" + env["PATH"]
        subprocess.run(
            [str(ROOT / "scripts/dev-cluster.sh"), str(self.base), str(SLOT)],
            env=env, check=True, capture_output=True,
        )
        wait_for(lambda: (self.base / "orch/.loom/daemon.endpoint").exists(), 30, "the orchestrator")
        log = self.base / "logs/exec.log"
        wait_for(lambda: log.exists() and "executor_serving" in log.read_text(errors="ignore"), 30, "the executor")

    def restart_orch(self):
        """Starts the orchestrator again after it drained, with the command dev-cluster.sh uses."""
        env = dict(os.environ, HOME=str(self.base / "orch"), FAKE_KEY="x", LOOM_COMPACTION_KEEP_RECENT="100",
                   LOOM_DISTRIBUTION_OPTFILE=str(self.base / "orch/.loom/distribution/dist.options"))
        env["PATH"] = f"/usr/local/bin:{Path.home()}/.local/bin:" + env["PATH"]
        log = open(self.base / "logs/orch.log", "ab")
        proc = subprocess.Popen(
            [os.environ.get("LOOMD_BIN", "loomd"), "--config", str(self.base / "orch/.loom/loom.toml"),
             "--bind", f"127.0.0.1:{7441 + SLOT * 10}"],
            env=env, stdout=log, stderr=log, start_new_session=True,
        )
        (self.base / "orch.pid").write_text(str(proc.pid))

    def _pid(self, name):
        path = self.base / f"{name}.pid"
        return int(path.read_text()) if path.exists() else None

    def kill(self, name, sig=signal.SIGKILL):
        pid = self._pid(name)
        if pid:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass

    def stop(self):
        for name in ("orch", "exec"):
            self.kill(name, signal.SIGTERM)
        self._stop_daemons()
        subprocess.run(["pkill", "-f", f"fake_provider.py {18999 + SLOT}"], check=False)


class App:
    """The app under test. It never takes focus unless a test asks."""

    def __init__(self, base, state_root, binary=None, active=False):
        self.dir = Path(base) / "driver"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.binary = binary or ROOT / "build/Loom.app/Contents/MacOS/Loom"
        self.state_root = state_root
        self.active = active
        self.proc = None
        self.seq = 0

    def launch(self):
        env = dict(os.environ, LOOM_DEBUG_DRIVER=str(self.dir), LOOM_STATE_DIR=str(self.state_root))
        if self.active:
            env["LOOM_FORCE_ACTIVE"] = "1"
        self.log = open(self.dir / "app.log", "ab")
        self.proc = subprocess.Popen([str(self.binary)], env=env, stdout=self.log, stderr=self.log)
        wait_for(lambda: self.ready(), 30, "the app to answer")
        return self

    def ready(self):
        try:
            return self.cmd("snapshot", timeout=1.0).startswith("{")
        except Failure:
            return False

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def quit(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def cmd(self, text, timeout=DEFAULT_TIMEOUT):
        self.seq += 1
        reply = self.dir / f"reply-{self.seq}"
        pending = self.dir / "commands"
        wait_for(lambda: not pending.exists(), timeout, "the driver to take the last command", 0.02)
        temp = self.dir / "commands.tmp"
        temp.write_text(f"#{self.seq} {text}\n")
        temp.rename(pending)
        wait_for(reply.exists, timeout, f"a reply to {text!r}", 0.02)
        value = reply.read_text()
        reply.unlink()
        return value

    # State.

    def snap(self):
        return json.loads(self.cmd("snapshot"))

    def tree(self):
        return json.loads(self.cmd("tree"))

    def texts(self):
        return [" ".join([n["name"], n["value"]]).strip() for n in self.tree()]

    def session(self):
        return self.snap().get("session") or {}

    def sessions(self):
        return [s for d in self.snap()["daemons"] for s in d["sessions"]]

    def session_id(self, title):
        def find():
            for session in self.sessions():
                if title in session["title"]:
                    return session["id"]
            return None
        return wait_for(find, what=f"a session titled {title!r}")

    # Assertions.

    def see(self, pattern, timeout=DEFAULT_TIMEOUT):
        """Waits until some on-screen element's name or value matches `pattern`."""
        rx = re.compile(pattern)
        return wait_for(lambda: any(rx.search(t) for t in self.texts()), timeout, f"to see /{pattern}/")

    def not_see(self, pattern):
        rx = re.compile(pattern)
        hits = [t for t in self.texts() if rx.search(t)]
        if hits:
            raise Failure(f"should not see /{pattern}/, found {hits[:2]}")

    def transcript_has(self, pattern, timeout=DEFAULT_TIMEOUT):
        rx = re.compile(pattern)
        return wait_for(lambda: any(rx.search(t) for t in self.session().get("transcript", [])), timeout, f"transcript /{pattern}/")

    # Actions.

    def go(self, where):
        self.cmd(f"go {where}")
        wait_for(lambda: self.snap()["destination"].replace(":", " ") == where, what=f"navigation to {where}")

    def open_session(self, title):
        sid = self.session_id(title)
        self.go(f"session {sid}")
        wait_for(lambda: self.session().get("isAdopted"), what="the session to attach")
        return sid

    def press(self, label, timeout=DEFAULT_TIMEOUT):
        """Presses a control by accessibility name, waiting for it to exist."""
        return wait_for(lambda: self.cmd(f"press {label}") == "ok", timeout, f"a control named {label!r}")

    def key(self, name, mods=""):
        self.cmd(f"key {name} {mods}".strip())

    def type(self, text):
        self.cmd(f"type {text}")

    def focus(self, label):
        """Puts the caret in a text field of the open sheet by its accessibility label."""
        wait_for(lambda: self.cmd(f"focus {label}") == "ok", what=f"a text field named {label!r}")

    def fill(self, label, text):
        """Replaces the contents of a text field, as a person would by selecting it and typing."""
        self.focus(label)
        wait_for(lambda: self.cmd("clear") == "ok", what="the field to be emptied")
        if text:
            self.type(text)

    def enabled(self, label):
        """Whether the control with this accessibility name exists and is enabled."""
        nodes = [n for n in self.tree() if n["name"] == label]
        return bool(nodes) and all(n["enabled"] for n in nodes)

    def menu(self, title):
        self.cmd(f"menu {title}")

    def dispatch(self, prompt, workspace, executor="local"):
        reply = self.cmd(f"dispatch {executor} {workspace} {prompt}", timeout=70)
        if reply.startswith("error"):
            raise Failure(f"dispatch refused: {reply}")
        return wait_for(lambda: self.session_id(prompt[:30]), what="the dispatched session")

    def prompt(self, sid, text):
        self.cmd(f"prompt {sid} {text}")

    def shot(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.cmd(f"shot {path.stem}")
        source = self.dir / f"{path.stem}.png"
        wait_for(source.exists, 5, "a capture")
        shutil.move(source, path)
        return path

    def resize(self, width, height):
        self.cmd(f"resize {width} {height}")

    def appearance(self, name):
        self.cmd(name)

    def hitch(self, seconds, during=None):
        """Returns frame statistics over `seconds`, with `during` run at the start."""
        self.cmd("hitch start")
        if during:
            during()
        time.sleep(seconds)
        name = f"hitch{self.seq}"
        self.cmd(f"hitch stop {name}")
        text = (self.dir / f"{name}.txt").read_text()
        return {k: float(v.rstrip("ms")) for k, v in re.findall(r"(\w+)=([\d.]+m?s?)", text)}

    def stats(self):
        name = f"stats{self.seq}"
        self.cmd(f"stats {name}")
        text = (self.dir / f"{name}.txt").read_text()
        return dict(re.findall(r"(\w+)=(\S+)", text))

    def audit(self):
        """Returns controls the accessibility tree cannot name, minus system chrome."""
        unnamed = []
        for node in self.tree():
            if node["role"] in ("AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXRadioButton", "AXTextArea") and not node["name"]:
                x, y, w, h = node["frame"]
                unnamed.append(node)
        # The window's three title bar buttons are drawn and named by the system.
        unnamed = [n for n in unnamed if n["frame"][2] > 20]
        return unnamed


def rng(seed):
    return random.Random(seed)
