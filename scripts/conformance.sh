#!/bin/sh
# Regenerates the conformance vectors: what Loom's own session_view draws for each committed trace.
#
#   LOOM_CHECKOUT=<a loom checkout> scripts/conformance.sh
#
# It builds a scratch Gleam project under build/conformance that depends on the checkout's
# session_view by path, generates a module holding the traces' frames, runs the projection, and
# writes Tests/LoomCoreTests/Traces/conformance.json. Nothing is added to the loom checkout.
# The Swift test reads the committed vectors, so the checkout is needed only to regenerate them.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
root=$(dirname "$here")
loom=${LOOM_CHECKOUT:?set LOOM_CHECKOUT to a loom checkout}
work="$root/build/conformance"
rm -rf "$work"
mkdir -p "$work/src/conformance"
cp "$here/conformance/src/conformance.gleam" "$work/src/conformance.gleam"
cat > "$work/gleam.toml" <<TOML
name = "conformance"
version = "0.1.0"
gleam = ">= 1.18.0"

[dependencies]
gleam_stdlib = ">= 1.0.0 and < 2.0.0"
core = { path = "$loom/packages/core" }
session_view = { path = "$loom/packages/session_view" }
TOML
python3 - "$root/Tests/LoomCoreTests/Traces" "$work/src/conformance/traces.gleam" <<'PY'
import glob, json, os, sys
src, out = sys.argv[1], sys.argv[2]
def lit(text):
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t') + '"'
entries = []
for path in sorted(glob.glob(os.path.join(src, '*.jsonl'))):
    name = os.path.basename(path)[:-len('.jsonl')]
    frames = []
    for line in open(path, encoding='utf-8'):
        record = json.loads(line)
        frames.append('#(%s, %s)' % (lit(record['d']), lit(record['f'])))
    entries.append('#(%s, [%s])' % (lit(name), ',\n'.join(frames)))
open(out, 'w', encoding='utf-8').write('pub const traces = [%s]\n' % ',\n'.join(entries))
PY
(cd "$work" && gleam run 2> "$work/gleam.log") > "$work/out.json"
python3 -c "import json,sys; json.dump(json.load(open('$work/out.json')), open('$root/Tests/LoomCoreTests/Traces/conformance.json','w'), indent=1, sort_keys=True, ensure_ascii=False)"
echo "wrote Tests/LoomCoreTests/Traces/conformance.json"
