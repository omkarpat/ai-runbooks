#!/usr/bin/env bash
# start-webui.sh — deploy and launch the N4 web UI inside the NemoClaw sandbox.
# Idempotent: safe to re-run (kills prior uvicorn, re-uploads, re-forwards).
#
# Usage:  ./scripts/start-webui.sh
#
# Prerequisites: sandbox onboarded + provisioned (policies, pipeline uploaded).
# The script adds the pypi egress policy (idempotent) and pip-installs
# fastapi/uvicorn at runtime — no custom image needed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="${SANDBOX_NAME:-runbooks}"
PORT="${WEBUI_PORT:-9090}"
export PATH="$HOME/.local/bin:$PATH"

log() { printf '\n=== %s ===\n' "$*"; }

# 1. pypi egress (idempotent — already applied = no-op with a warning)
log "Ensuring pypi egress policy"
nemohermes "$SANDBOX" policy-add pypi --yes 2>/dev/null || true

# 2. pip install (skip if already present; uses host-downloaded wheels for
#    cross-platform reliability — sandbox is Linux aarch64, host may be macOS)
log "Ensuring fastapi + uvicorn in sandbox"
CID="$(docker ps --filter "name=openshell-$SANDBOX" --format '{{.ID}}' | head -1)"
if docker exec "$CID" python3 -c "import fastapi, uvicorn" 2>/dev/null; then
  echo "  already installed"
else
  WHEELS="$(mktemp -d)"
  pip3 download --dest "$WHEELS" --only-binary :all: \
    --platform manylinux_2_17_aarch64 --python-version 313 \
    --implementation cp --abi cp313 fastapi uvicorn requests 2>/dev/null
  docker cp "$WHEELS/." "$CID:/tmp/wheels/"
  docker exec "$CID" pip install --break-system-packages --no-index \
    --find-links /tmp/wheels fastapi uvicorn requests
  rm -rf "$WHEELS"
fi

# 3. upload webui (docker cp for reliability — openshell upload has transport issues)
log "Uploading webui"
CID="$(docker ps --filter "name=openshell-$SANDBOX" --format '{{.ID}}' | head -1)"
docker cp "$REPO_ROOT/webui/." "$CID:/sandbox/webui/"
docker exec --user root "$CID" chown -R sandbox:sandbox /sandbox/webui

# 4. kill prior uvicorn (restart-safe)
openshell sandbox exec -n "$SANDBOX" -- sh -lc 'pkill -f "uvicorn app:app" 2>/dev/null || true'
sleep 1

# 5. launch (log to /sandbox/webui/ which is sandbox-writable after chown)
log "Starting uvicorn on :$PORT inside sandbox"
openshell sandbox exec -n "$SANDBOX" -- sh -lc \
  "cd /sandbox/webui && nohup python3 -m uvicorn app:app --host 0.0.0.0 --port $PORT >webui.log 2>&1 &"
sleep 3

# 6. port forward (idempotent)
log "Forwarding port $PORT"
openshell forward start --background "$PORT" "$SANDBOX" 2>/dev/null || true

echo
echo "Web UI: http://127.0.0.1:$PORT"
echo "API:    http://127.0.0.1:$PORT/api/runbooks"
echo "Logs:   openshell sandbox exec -n $SANDBOX -- tail -f /tmp/webui.log"
