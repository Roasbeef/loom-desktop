#!/bin/sh
# Fails if anything under Sources/LoomCore can block, wait, read a clock or touch
# the operating system. The core decides and returns effects as data, so a
# simulation can step it with no scheduler and a virtual clock, and two runs of one
# seed cannot differ. The same rule gates Loom's portable Gleam packages (lint R6).
#
# Comments are skipped, so prose may name what the code must not use.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/Sources/LoomCore"
pattern='(^|[^A-Za-z_])(async|await|Task|Date\(|ContinuousClock|SuspendingClock|UserDefaults|FileManager|URLSession|DispatchQueue|DispatchTime|Process\(|NSWorkspace|@MainActor|Thread\.|sleep\(|NotificationCenter|ProcessInfo)([^A-Za-z_]|$)'
status=0
for file in $(find "$dir" -name '*.swift' | sort) "$root/Sources/LoomKit/ControlLane.swift"; do
    # Strip // comments (including doc comments) before matching.
    hits="$(sed -e 's://.*$::' "$file" | grep -nE "$pattern" || true)"
    if [ -n "$hits" ]; then
        echo "core-purity: $file"
        echo "$hits"
        status=1
    fi
done
if [ "$status" -ne 0 ]; then
    echo "core-purity: Sources/LoomCore must not use async, a clock, a timer or an OS call." >&2
    exit 1
fi
echo "core-purity: ok"
