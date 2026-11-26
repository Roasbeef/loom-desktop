#!/bin/sh
# Records session traces from a real loomd driven by the scripted model.
#
#   scripts/record-traces.sh <out-dir> [name]...
#
# It starts its own loomd with a state directory and a home directory under a scratch
# directory, on port 17741, and its own scripted model endpoint on port 19741. It never
# uses port 7440 or ~/.loom, needs no provider key (the model is scripts/fake_provider.py
# and the key variable holds a placeholder), and prints no credential. Each trace is a
# file of frames, one JSON object per line, written by `loom-probe record`.
#
#   LOOMD_BIN   the daemon binary (required; a checkout's bin/loomd)
#   PROBE       the loom-probe binary (default .build/debug/loom-probe; run `swift build` first)
#   TRACE_ROOT  the scratch directory (default build/trace-run under the repository)
#
# The scenarios are named after the scripted model's keywords: `plain` (a short reply),
# `think` (reasoning then a reply), `tour` (tool calls, one failing), `stopmid` (a turn the
# person aborts), `explode` (a turn that fails with no entry), `escalate` (an approval the
# policy raises), `two` (two prompts, the second sent while the first runs).
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
root=$(dirname "$here")
out=$1
shift
loomd=${LOOMD_BIN:?set LOOMD_BIN to a loomd binary}
probe=${PROBE:-$root/.build/debug/loom-probe}
scratch=${TRACE_ROOT:-$root/build/trace-run}
port=17741
provider=19741
names=${*:-plain think tour stopmid explode escalate two}

if [ -e "$scratch" ]; then
    echo "$scratch exists; remove it first" >&2
    exit 1
fi
mkdir -p "$scratch/home" "$scratch/state" "$scratch/ws" "$out"
git -C "$scratch/ws" init -q
echo "hello" > "$scratch/ws/README.md"

cat > "$scratch/loom.toml" <<TOML
[models.fake]
dialect = "openai"
base_url = "http://127.0.0.1:$provider/v1"
api_key_env = "FAKE_KEY"
model_id = "fake"
thinking = "unsupported"
context_window = 200000
max_output_tokens = 4096

[roles]
main = ["fake"]
TOML

python3 "$here/fake_provider.py" "$provider" > "$scratch/provider.log" 2>&1 &
provider_pid=$!
HOME="$scratch/home" FAKE_KEY=placeholder "$loomd" --config "$scratch/loom.toml" \
    --state-dir "$scratch/state" --bind "127.0.0.1:$port" > "$scratch/loomd.log" 2>&1 &
daemon_pid=$!

# Stops only the two processes this script started.
stop() {
    "$probe" shutdown "$scratch/state" > /dev/null 2>&1 || true
    kill "$provider_pid" 2> /dev/null || true
    kill "$daemon_pid" 2> /dev/null || true
}
trap stop EXIT

# The daemon is ready when it has published its endpoint record.
n=0
while [ ! -s "$scratch/state/daemon.endpoint" ] && [ "$n" -lt 100 ]; do
    sleep 0.3
    n=$((n + 1))
done
test -s "$scratch/state/daemon.endpoint" || { echo "loomd did not start; see $scratch/loomd.log" >&2; exit 1; }

for name in $names; do
    case "$name" in
        plain) set -- "say something short" ;;
        think) set -- "think about it" ;;
        tour) set -- "tour" ;;
        stopmid) set -- "stopmid|abort=3" ;;
        explode) set -- "explode" ;;
        escalate) set -- "escalate" ;;
        two) set -- "slow" "demo" ;;
        *) echo "unknown scenario $name" >&2; exit 2 ;;
    esac
    "$probe" record "$scratch/state" "$scratch/ws" "$scratch/loom.toml" "$out/$name.jsonl" "$@" > "$scratch/$name.log" 2>&1 \
        || echo "scenario $name failed; see $scratch/$name.log" >&2
done
echo "traces in $out"
