#!/bin/sh
# Blind recall: revert one known fix at a time and check whether the generic swarm finds it.
#
# Each file in scripts/recall/ is a patch that reintroduces one bug into the production
# core, with the simulation that is expected to find it on its first line. For each patch
# this script applies it in a scratch worktree, runs the generic swarm from generator seed 1
# (then 2) with a fixed budget, and prints the run at which the swarm first failed, or
# "missed". Nothing in the harness is specific to any patch, so a miss is a harness gap.
#
# Usage: scripts/recall.sh <scratch worktree> [patch name ...]
#   RECALL_RUNS   seeds per generator (default 20000)
#
# The scratch worktree must be a checkout of the same commit, outside /tmp. Make one with
# `git cow add <path> -b recall/scratch`, and remove it with `git cow remove <path>`.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$1"
shift
runs="${RECALL_RUNS:-20000}"
if [ "$#" -gt 0 ]; then names="$*"; else names="$(ls "$root/scripts/recall" | sed 's/\.patch$//')"; fi
for name in $names; do
    patch="$root/scripts/recall/$name.patch"
    test_class="$(sed -n '1s/^# test: //p' "$patch")"
    git -C "$scratch" checkout -q -- .
    git -C "$scratch" apply "$patch"
    log="$(SIM_RUNS="$runs" swift test --package-path "$scratch" --filter "LoomCoreTests.$test_class/testTheSwarmKeeps" 2>&1 || true)"
    found="$(printf '%s\n' "$log" | sed -n 's/.*generator \([0-9]*\): violation \([A-Za-z0-9]*\):.* at run \([0-9]*\) step.*/generator \1, run \3, rule \2/p' | head -1)"
    if [ -z "$found" ]; then
        found="$(printf '%s\n' "$log" | sed -n 's/.*violation \([A-Za-z0-9]*\):.* at run \([0-9]*\) step.*/run \2, rule \1/p' | head -1)"
    fi
    if printf '%s\n' "$log" | grep -q 'error: SwiftCompile\|error: Build failed'; then found="BUILD FAILED"; fi
    echo "$name | $test_class | ${found:-missed in $runs runs per generator}"
    git -C "$scratch" checkout -q -- .
done
