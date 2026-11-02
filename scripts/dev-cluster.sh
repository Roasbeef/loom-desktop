#!/bin/sh
# Brings up a throwaway orchestrator and executor on this machine, joined by real
# TLS distribution, with the scripted model. This follows quick start A of Loom's
# docs/distributed-setup.md and touches nothing outside the chosen directory.
#
#   scripts/dev-cluster.sh [dir]     default /tmp/lc
#
# The orchestrator's state root is printed at the end, for LOOM_STATE_DIR.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
base=${1:-/tmp/lc}
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
erlang_node = "orch@127.0.0.1"
executors = ["box"]

[[node]]
name = "box"
role = "executor"
erlang_node = "exec@127.0.0.1"
listen_port = 9150

[node.workspaces]
proj = "$base/proj"
EOF

"$loom" distribution provision "$base/plan.toml" "$base/out" --static
"$loom" distribution install "$base/out/box.loombundle" --home "$base/exec"
"$loom" distribution install "$base/out/orch.loombundle" --home "$base/orch"

cat >> "$base/orch/.loom/loom.toml" <<EOF

[models.fake]
dialect = "openai"
base_url = "http://127.0.0.1:18999/v1"
api_key_env = "FAKE_KEY"
model_id = "fake"
thinking = "unsupported"
context_window = 200000
max_output_tokens = 4096

[roles]
main = ["fake"]
EOF

if ! lsof -nP -iTCP:18999 -sTCP:LISTEN >/dev/null 2>&1; then
    nohup python3 "$here/fake_provider.py" 18999 > "$base/logs/provider.log" 2>&1 &
fi

HOME="$base/exec" LOOM_DISTRIBUTION_OPTFILE="$base/exec/.loom/distribution/dist.options" \
    nohup "$loomd" --config "$base/exec/.loom/loom.toml" --bind 127.0.0.1:7442 \
    > "$base/logs/exec.log" 2>&1 &
echo $! > "$base/exec.pid"

HOME="$base/orch" FAKE_KEY=x LOOM_DISTRIBUTION_OPTFILE="$base/orch/.loom/distribution/dist.options" \
    nohup "$loomd" --config "$base/orch/.loom/loom.toml" --bind 127.0.0.1:7441 \
    > "$base/logs/orch.log" 2>&1 &
echo $! > "$base/orch.pid"

echo "orchestrator state root: $base/orch/.loom"
echo "stop with: kill \$(cat $base/orch.pid) \$(cat $base/exec.pid)"
