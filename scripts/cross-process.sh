#!/bin/sh
# Runs the same seeds in two separate `swift test` processes with different hash seeds and compares
# the digest of every final snapshot. A difference means production code or the harness depends on
# the iteration order of a dictionary or set, which two runs in one process cannot show.
#
#   scripts/cross-process.sh                 default 300 seeds per model, generator seed 1
#   SIM_RUNS=2000 SIM_SEED=7 scripts/cross-process.sh
#
# The first process fixes the hash seed (SWIFT_DETERMINISTIC_HASHING=1) and the second leaves it
# unset, so Swift picks a random one.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
dir=${TMPDIR:-/tmp}/cross-process.$$
mkdir -p "$dir"
trap 'rm -rf "$dir"' EXIT
SIM_DIGEST_OUT="$dir/fixed" SWIFT_DETERMINISTIC_HASHING=1 swift test --package-path "$root" --filter CrossProcessTests > "$dir/fixed.log" 2>&1 \
    || { tail -20 "$dir/fixed.log"; exit 1; }
env -u SWIFT_DETERMINISTIC_HASHING SIM_DIGEST_OUT="$dir/random" swift test --package-path "$root" --filter CrossProcessTests > "$dir/random.log" 2>&1 \
    || { tail -20 "$dir/random.log"; exit 1; }
if cmp -s "$dir/fixed" "$dir/random"; then
    echo "cross-process: $(wc -l < "$dir/fixed" | tr -d ' ') seeds agree across two hash seeds"
else
    echo "cross-process: the two processes disagree:" >&2
    diff "$dir/fixed" "$dir/random" | head -20 >&2
    exit 1
fi
