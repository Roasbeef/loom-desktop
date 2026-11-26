#!/bin/sh
# A long simulation campaign with a rotating generator seed, then the cross-process comparison and,
# when a scratch worktree is given, blind recall. Meant to be run on a schedule (cron or launchd);
# the repository has no CI, so there is no workflow file.
#
#   scripts/sim-nightly.sh [scratch-worktree]
#
#   SIM_RUNS   seeds per model (default 100000)
#   SIM_SEED   generator seed; by default the day of the year, so each night draws new schedules
#              and a failure is reproducible from the date in the log
#   NIGHTLY_LOG   directory for the log (default build/nightly)
#
# Exit status is nonzero if any stage fails. A failing seed is printed with its replay command
# (`make sim-replay MODEL=... SEED=...`), so the log is enough to reproduce it.
set -u
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
runs=${SIM_RUNS:-100000}
seed=${SIM_SEED:-$(date +%j | sed 's/^0*//')}
logdir=${NIGHTLY_LOG:-$root/build/nightly}
mkdir -p "$logdir"
log="$logdir/$(date +%Y-%m-%d).log"
status=0
{
    echo "sim-nightly $(date) runs=$runs generator=$seed"

    echo "== campaign"
    SIM_RUNS=$runs SIM_SEED=$seed swift test --package-path "$root" --filter 'LoomCoreTests.*ModelTests' 2>&1 | grep -E "violation|failed|error:|Executed [0-9]+ tests" | tail -20
} > "$log" 2>&1
if grep -q "violation\|error:" "$log"; then status=1; fi

{
    echo "== cross-process"
    SIM_RUNS=${CROSS_RUNS:-1000} SIM_SEED=$seed sh "$root/scripts/cross-process.sh" 2>&1 || status=1
    if [ $# -gt 0 ]; then
        echo "== recall"
        RECALL_RUNS=${RECALL_RUNS:-20000} sh "$root/scripts/recall.sh" "$1" 2>&1 | tee "$logdir/recall.txt"
        if grep -q "missed\|BUILD FAILED" "$logdir/recall.txt"; then status=1; fi
    fi
    echo "exit $status"
} >> "$log" 2>&1
cat "$log"
exit $status
