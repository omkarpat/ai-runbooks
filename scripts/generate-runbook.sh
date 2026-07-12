#!/usr/bin/env bash
#
# generate-runbook.sh — turn one recording into a runbook by driving the
# provisioned NemoClaw sandbox: upload the video, run the pipeline, print the
# finished runbook.md to STDOUT. All progress goes to STDERR so a caller (the
# desktop app) can stream it separately from the result.
#
# Usage:  generate-runbook.sh <recording.mov> [workflow-name]
# Requires: the sandbox already provisioned (scripts/provision-sandbox.sh) and
#           `openshell` on PATH.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

REC="${1:?usage: generate-runbook.sh <recording.mov> [workflow-name]}"
SANDBOX="${SANDBOX_NAME:-runbooks}"
NAME="${2:-$(basename "${REC%.*}")}"
BASE="$(basename "$REC")"

[ -f "$REC" ] || { echo "recording not found: $REC" >&2; exit 1; }
command -v openshell >/dev/null || { echo "openshell not found on PATH — is NemoClaw installed?" >&2; exit 1; }

echo "Uploading ${BASE} to the sandbox…" >&2
openshell sandbox upload "$SANDBOX" "$REC" "/sandbox/videos/${BASE}" >&2

echo "Running the runbook pipeline (frames → Holo vision → synthesis)…" >&2
# run.py writes all progress to its own stderr; redirect its stdout there too so
# only the runbook (the final cat below) lands on our stdout.
openshell sandbox exec -n "$SANDBOX" -- \
  python3 /sandbox/pipeline/pipeline/run.py "/sandbox/videos/${BASE}" "$NAME" >&2

echo "Fetching the generated runbook…" >&2
openshell sandbox exec -n "$SANDBOX" -- \
  sh -lc 'd="$(ls -dt /sandbox/runbooks/*/ 2>/dev/null | head -1)"; [ -n "$d" ] && cat "${d}runbook.md"'
