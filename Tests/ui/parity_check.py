#!/usr/bin/env python3
"""Holds docs/parity.md to what the UI scenarios prove.

A row may say `yes` only if a scenario lists its id in `covers`. Implemented work with
no scenario says `code`. This also fails on a scenario naming a row that does not exist,
so a renamed row cannot quietly lose its proof.
"""
import collections
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import scenarios  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
ROW = re.compile(r"^\|\s*([A-Z]{2,3}-\d+)\s*\|")


def main():
    rows = {}
    for line in (ROOT / "docs/parity.md").read_text().splitlines():
        if ROW.match(line):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            rows[cells[0]] = (cells[4].split()[0].strip("`*:,.").lower(), cells[5], cells[1])

    covered = {i for s in scenarios.ALL for i in s.covers}
    errors = []
    for row in sorted(covered - set(rows)):
        errors.append(f"a scenario covers {row}, which docs/parity.md does not list")
    for row, (state, _, name) in sorted(rows.items()):
        if state == "yes" and row not in covered:
            errors.append(f"{row} says yes but no scenario covers it: {name}")

    counts = collections.Counter((state, tier) for state, tier, _ in rows.values())
    print(f"{'state':10}{'tier 1':>8}{'tier 2':>8}{'tier 3':>8}{'total':>8}")
    for state in ("yes", "code", "partial", "no"):
        tiers = [counts[(state, t)] for t in "123"]
        print(f"{state:10}{tiers[0]:>8}{tiers[1]:>8}{tiers[2]:>8}{sum(tiers):>8}")
    print(f"{'total':10}" + "".join(f"{sum(counts[(s, t)] for s in ('yes', 'code', 'partial', 'no')):>8}" for t in "123") + f"{len(rows):>8}")

    for error in errors:
        print("ERROR", error)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
