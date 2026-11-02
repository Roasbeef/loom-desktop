#!/bin/sh
# Brings up a throwaway orchestrator and executor on this machine, joined by real
# TLS distribution, with the scripted model. This follows quick start A of Loom's
# docs/distributed-setup.md and touches nothing outside the chosen directory.
#
#   scripts/dev-cluster.sh [dir] [slot]     default /tmp/lc, slot 0
#
# A slot offsets every port and node name, so clusters can run side by side.
#
# The orchestrator's state root is printed at the end, for LOOM_STATE_DIR.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
base=${1:-/tmp/lc}
slot=${2:-0}
exec_dist=$((9150 + slot))
orch_bind=$((7441 + slot * 10))
exec_bind=$((7442 + slot * 10))
provider=$((18999 + slot))
loom=${LOOM_BIN:-loom}
loomd=${LOOMD_BIN:-loomd}

if [ -e "$base" ]; then
    echo "$base exists; remove it first" >&2
    exit 1
fi
mkdir -p "$base/proj" "$base/logs"
git -C "$base/proj" init -q
echo "hello from the executor's checkout" > "$base/proj/README.md"

cat > "$base/plan.toml" <<EOF
[[node]]
name = "orch"
role = "orchestrator"
erlang_node = "orch$slot@127.0.0.1"
executors = ["box"]

[[node]]
name = "box"
role = "executor"
erlang_node = "exec$slot@127.0.0.1"
listen_port = $exec_dist

[node.workspaces]
proj = "$base/proj"
EOF

"$loom" distribution provision "$base/plan.toml" "$base/out" --static
"$loom" distribution install "$base/out/box.loombundle" --home "$base/exec"
"$loom" distribution install "$base/out/orch.loombundle" --home "$base/orch"

cat >> "$base/orch/.loom/loom.toml" <<EOF

[models.fake]
dialect = "openai"
base_url = "http://127.0.0.1:$provider/v1"
api_key_env = "FAKE_KEY"
model_id = "fake"
thinking = "unsupported"
context_window = 200000
max_output_tokens = 4096

[models.fake.pricing]
input = 3.0
output = 15.0

[models.fake2]
dialect = "openai"
base_url = "http://127.0.0.1:$provider/v1"
api_key_env = "FAKE_KEY"
model_id = "fake"
thinking = "unsupported"
context_window = 200000
max_output_tokens = 4096

[roles]
main = ["fake"]
advisor = ["fake"]

[profiles.review.roles]
main = ["fake2"]

[pools.boxes]
executors = ["box"]
EOF

if ! lsof -nP -iTCP:$provider -sTCP:LISTEN >/dev/null 2>&1; then
    nohup python3 "$here/fake_provider.py" "$provider" > "$base/logs/provider.log" 2>&1 &
fi

HOME="$base/exec" LOOM_DISTRIBUTION_OPTFILE="$base/exec/.loom/distribution/dist.options" \
    nohup "$loomd" --config "$base/exec/.loom/loom.toml" --bind "127.0.0.1:$exec_bind" \
    > "$base/logs/exec.log" 2>&1 &
echo $! > "$base/exec.pid"

# A tiny recent-tail target lets a short scripted session have something to cut,
# so /compact can succeed. A real session keeps the default of 20,000 tokens.
HOME="$base/orch" FAKE_KEY=x LOOM_COMPACTION_KEEP_RECENT=100 LOOM_DISTRIBUTION_OPTFILE="$base/orch/.loom/distribution/dist.options" \
    nohup "$loomd" --config "$base/orch/.loom/loom.toml" --bind "127.0.0.1:$orch_bind" \
    > "$base/logs/orch.log" 2>&1 &
echo $! > "$base/orch.pid"

echo "orchestrator state root: $base/orch/.loom"
echo "stop with: kill \$(cat $base/orch.pid) \$(cat $base/exec.pid)"
