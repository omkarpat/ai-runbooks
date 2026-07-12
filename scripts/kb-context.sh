#!/usr/bin/env bash
# kb-context.sh — print a compact, chat-injectable summary of the runbook
# catalog (one line per workflow, plus pending-merge count). Used by the app's
# HermesRuntime to ground every chat message in live KB state, so even a weak
# agent model can answer "what runbooks are available?" without tool calls.
#
# Prints NOTHING (exit 0) if the sandbox/CLI is unavailable — grounding is
# best-effort and must never block or break chat.
set -u
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
SANDBOX="${SANDBOX_NAME:-runbooks}"

JSON="$(openshell sandbox exec -n "$SANDBOX" -- sh -lc \
  'python3 /sandbox/pipeline/pipeline/kb.py list 2>/dev/null && python3 /sandbox/pipeline/pipeline/kb.py merges 2>/dev/null' \
  2>/dev/null)" || exit 0
[ -n "$JSON" ] || exit 0

python3 - <<'PY' "$JSON" 2>/dev/null || exit 0
import json, sys
raw = sys.argv[1]
# Two concatenated JSON objects (list + merges) — split on the boundary.
dec = json.JSONDecoder()
objs, idx = [], 0
while idx < len(raw):
    raw_tail = raw[idx:].lstrip()
    if not raw_tail:
        break
    obj, end = dec.raw_decode(raw_tail)
    objs.append(obj)
    idx += len(raw) - idx - len(raw_tail) + end
wfs = next((o["workflows"] for o in objs if "workflows" in o), [])
merges = next((o["pending_merges"] for o in objs if "pending_merges" in o), [])
if not wfs and not merges:
    sys.exit(0)
lines = [f"- \"{w['title']}\" (id {w['id']}, {len(w['runs'])} run(s), context: {w['dominant_context'] or 'n/a'})"
         for w in wfs]
out = "Runbook catalog right now:\n" + "\n".join(lines)
if merges:
    out += f"\nPending merge proposals: {len(merges)} (see runbook-merger skill)"
print(out)
PY
