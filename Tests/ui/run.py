#!/usr/bin/env python3
"""Runs the UI scenarios against a real cluster and writes a report.

  tests/ui/run.py                 every scenario, no focus taken
  tests/ui/run.py --only approval name or parity id substring; commas separate several
  tests/ui/run.py --foreground    also the scenarios that need a key window
  tests/ui/run.py --update        accept visual differences as the new baseline
  tests/ui/run.py --seed 7        the monkey's seed, to reproduce a failure

The exit code is the number of failures.
"""
import argparse
import html
import sys
import time
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from loomui import App, BASE, Cluster, ROOT, screen_locked  # noqa: E402
import scenarios  # noqa: E402
import visual  # noqa: E402

OUT = ROOT / "build/uitest"


BLOCKED = "Not run: the screen was locked, so a pixel check could prove nothing."


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default="")
    parser.add_argument("--foreground", action="store_true")
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    selected = [
        s for s in scenarios.ALL
        if (args.foreground or not s.foreground)
        and any(o in s.name or any(o in i for i in s.covers) for o in args.only.split(","))
    ]
    cluster = Cluster(BASE)
    print("starting cluster", flush=True)
    cluster.start()
    app = App(BASE, cluster.state).launch()
    context = scenarios.Context(app, cluster, OUT, args)
    results = []
    try:
        for scenario in selected:
            started = time.monotonic()
            # A pixel check on a locked screen says nothing either way, so it is
            # counted as unproven, and the run does not report green.
            if scenario.needs_display and screen_locked():
                results.append((scenario, BLOCKED, 0.0, None))
                print(f"blocked {scenario.name}: the screen is locked", flush=True)
                continue
            # A scenario that takes the app down must not fail all that follow.
            if not app.alive():
                app.launch()
            try:
                # Each scenario starts with every daemon slot free.
                app.cmd("stopall", timeout=60)
                scenario.run(context)
                error = None
            except Exception:
                error = traceback.format_exc()
            if not app.alive():
                error = (error or "") + "\nTHE APP CRASHED"
            elapsed = time.monotonic() - started
            shot = None
            if app.alive():
                try:
                    shot = app.shot(OUT / "shots" / f"{scenario.name}.png")
                except Exception:
                    pass
            results.append((scenario, error, elapsed, shot))
            print(f"{'FAIL' if error else 'ok  '} {scenario.name} ({elapsed:.1f}s)", flush=True)
            if error:
                print(error, flush=True)
    finally:
        app.quit()
        cluster.stop()

    blocked = sum(1 for _, e, _, _ in results if e == BLOCKED)
    failed = sum(1 for _, e, _, _ in results if e) - blocked
    report(results, context)
    print(f"\n{len(results) - failed - blocked} passed, {failed} failed, {blocked} blocked. Report: {OUT / 'report.html'}")
    return failed + blocked


def report(results, context):
    rows = []
    for scenario, error, elapsed, shot in results:
        image = f'<a href="{shot.relative_to(OUT)}"><img src="{shot.relative_to(OUT)}" loading="lazy"></a>' if shot else ""
        rows.append(
            f'<section class="{"bad" if error else "good"}"><h2>{"✗" if error else "✓"} {html.escape(scenario.name)}</h2>'
            f'<p>{html.escape(scenario.doc)} <small>{elapsed:.1f}s · {", ".join(scenario.covers)}</small></p>'
            f'{f"<pre>{html.escape(error)}</pre>" if error else ""}{image}</section>'
        )
    for line in context.notes:
        rows.append(f"<p class=note>{html.escape(line)}</p>")
    (OUT / "report.html").write_text(
        "<!doctype html><meta charset=utf-8><title>Loom UI tests</title><style>"
        "body{font:14px system-ui;margin:24px;background:#17191b;color:#e7e9ea}"
        "section{border:1px solid #34383b;border-radius:10px;padding:12px;margin:12px 0}"
        ".bad{border-color:#dc625c}img{max-width:700px;width:100%;border-radius:8px}"
        "pre{white-space:pre-wrap;color:#ff7a70}small{color:#bcc2c6}</style>"
        "<h1>Loom UI tests</h1>" + "".join(rows)
    )


if __name__ == "__main__":
    sys.exit(main())
