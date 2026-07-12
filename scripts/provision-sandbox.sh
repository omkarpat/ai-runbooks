#!/usr/bin/env bash
#
# provision-sandbox.sh — reproduce the full NemoClaw Hermes + runbook-pipeline
# sandbox on ANY machine from the repo. This is the portable unit: snapshots,
# the running sandbox, and runtime apt installs are machine-local state and do
# NOT move between machines — this script rebuilds them from code + secrets.
#
# Prereqs on the target machine:
#   - Docker running (Docker Desktop: Settings > Resources > Memory >= 8 GB)
#   - NemoClaw installed:  curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_INSTALL_TAG=v0.0.79 bash
#   - Repo checked out, and a .env at the repo root with:
#       OPENAI_API_KEY   (sk-...)   — agent brain (routed via inference.local)
#       H_API_KEY        (hk-...)   — Holo vision  (pipeline)
#       GRADIUM_API_KEY  (gsk_.../gd_...) — STT     (pipeline, optional)
#
# Usage:  ./scripts/provision-sandbox.sh
#
# Everything below was validated interactively; the two non-obvious fixes this
# encodes are: (1) onboard with the DEFAULT full Hermes image (NOT a custom
# --from image built on the bare base — that omits NemoClaw's agent-runtime
# layer and the agent never starts), and (2) ffmpeg must be apt-installed at
# runtime because it isn't in the default image and the egress policy blocks
# apt until debian-apt is applied.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="${SANDBOX_NAME:-runbooks}"
AGENT_MODEL="${AGENT_MODEL:-gpt-5.6-luna}"     # final agent brain
SMOKE_MODEL="${SMOKE_MODEL:-gpt-4o-mini}"      # passes onboarding's inference smoke
export PATH="$HOME/.local/bin:$PATH"

log() { printf '\n=== %s ===\n' "$*"; }

# --- 0. read secrets from repo-root .env ------------------------------------
envval() { python3 -c "import sys
for l in open('$REPO_ROOT/.env'):
    if l.strip().startswith('$1'):
        sys.stdout.write(l.split('=',1)[1].strip().strip(chr(34)).strip(chr(39))); break"; }

OPENAI_API_KEY="$(envval OPENAI_API_KEY)"
HAI_API_KEY="$(envval H_API_KEY)"
GRADIUM_API_KEY="$(envval GRADIUM_API_KEY)"
[ -n "$OPENAI_API_KEY" ] || { echo "OPENAI_API_KEY missing from .env"; exit 1; }
[ -n "$HAI_API_KEY" ]    || echo "WARN: H_API_KEY missing — Holo vision stage will fail"

command -v nemohermes >/dev/null || { echo "nemohermes not installed — see prereqs"; exit 1; }
docker info >/dev/null 2>&1     || { echo "Docker daemon not running"; exit 1; }

# --- 1. onboard with the DEFAULT full Hermes image (the critical fix) --------
log "Onboarding '$SANDBOX' with the default Hermes image (provider=openai)"
NEMOCLAW_PROVIDER=openai \
NEMOCLAW_MODEL="$SMOKE_MODEL" \
NEMOCLAW_PROVIDER_KEY="$OPENAI_API_KEY" \
OPENAI_API_KEY="$OPENAI_API_KEY" \
NEMOCLAW_IGNORE_RUNTIME_RESOURCES=1 \
NEMOCLAW_RECREATE_WITHOUT_BACKUP=1 \
  nemohermes onboard --non-interactive --fresh --recreate-sandbox --agent hermes --name "$SANDBOX" \
    --no-gpu --no-sandbox-gpu --yes --yes-i-accept-third-party-software

# --- 2. point the agent brain at the real model -----------------------------
log "Setting agent model -> $AGENT_MODEL"
nemohermes inference set --provider openai-api --model "$AGENT_MODEL" --sandbox "$SANDBOX" --no-verify

# --- 3. egress policies (pipeline + runtime installs) -----------------------
# NOTE: these widen the sandbox's deny-by-default egress. Review the YAMLs in
# sandbox/policies/ before running on a new machine.
log "Applying egress policies"
# holo/gradium: pipeline vision+STT. github-agent/github: agent startup fetch.
# debian-apt: ffmpeg install (step 4). openai-api-direct: direct api.openai.com
# (usually unnecessary — the gateway proxies OpenAI via inference.local — but
# included per project config; harmless if unused).
# hai-trajectory-read: lets runbook-runner read the public session trajectory
# (event log) for evidence-based per-step reports (N2 §4.7 fix).
for f in holo-models-api gradium-stt github-agent debian-apt openai hai-trajectory-read; do
  nemohermes runbooks policy-add --from-file "$REPO_ROOT/sandbox/policies/$f.yaml" --yes
done
nemohermes runbooks policy-add github --yes    # built-in: git -> github.com

# --- 3b. register the H hosted-agent-platform MCP server (N2/E1) -------------
# Native managed MCP (NemoClaw v0.0.74+): this ONE command creates the OpenShell
# credential provider, generates the `protocol: mcp` egress policy for
# agp.eu.hcompany.ai, and writes the /sandbox/.hermes/config.yaml entry with an
# `openshell:resolve:env:` placeholder. The raw hk- key NEVER lands in the
# sandbox — it stays in OpenShell's provider store and is resolved only at
# egress. This supersedes N2's original hand-written policy+config approach
# (that would have written the bearer token into the config as plaintext).
# The default full Hermes image already carries HTTP-MCP support, so no custom
# image is needed; `mcp add` fails closed with rebuild guidance if it doesn't.
if [ -n "$HAI_API_KEY" ]; then
  log "Registering hai-agent-platform MCP server (agp.eu.hcompany.ai)"
  HAI_AGENT_MCP_TOKEN="$HAI_API_KEY" \
    nemohermes runbooks mcp add hai-agent-platform \
      --url https://agp.eu.hcompany.ai/mcp \
      --env HAI_AGENT_MCP_TOKEN
  nemohermes runbooks mcp status hai-agent-platform || true
else
  echo "WARN: H_API_KEY missing — skipping hai-agent-platform MCP (runbook-runner needs it)"
fi

# --- 4. install ffmpeg at runtime (not in the default image) ----------------
log "Installing ffmpeg via apt (needs debian-apt egress from step 3)"
CID="$(docker ps --filter "name=openshell-$SANDBOX" --format '{{.ID}}' | head -1)"
docker exec --user root "$CID" apt-get update
docker exec --user root "$CID" apt-get install -y --no-install-recommends ffmpeg
openshell sandbox exec -n "$SANDBOX" -- sh -lc 'ffmpeg -version | head -1'

# --- 5. upload the pipeline + write in-sandbox keys --------------------------
log "Uploading pipeline + writing /sandbox/.env"
openshell sandbox upload "$SANDBOX" "$REPO_ROOT/pipeline" /sandbox/pipeline
TMP_ENV="$(mktemp)"
{
  echo "HAI_API_KEY=$HAI_API_KEY"
  [ -n "$GRADIUM_API_KEY" ] && echo "GRADIUM_API_KEY=$GRADIUM_API_KEY"
  echo "SYNTH_URL=https://inference.local/v1/chat/completions"
  echo "SYNTH_MODEL=$AGENT_MODEL"
} > "$TMP_ENV"
openshell sandbox upload "$SANDBOX" "$TMP_ENV" /sandbox/.env
rm -f "$TMP_ENV"

# --- 5b. install skills (builder = record→runbook, runner = N2 execution,
#          merger = N3 merge-queue review) -----------------------------------
log "Installing skills (runbook-builder, runbook-runner, runbook-merger)"
for skill in runbook-builder runbook-runner runbook-merger; do
  if [ -f "$REPO_ROOT/sandbox/skills/$skill/SKILL.md" ]; then
    nemohermes runbooks skill install "$REPO_ROOT/sandbox/skills/$skill"
  fi
done

# --- 5c. standing agent context (runbook domain contract) --------------------
# SOUL.md is folded into the agent's system prompt EVERY turn — it carries the
# runbook-domain contract + kb.py cheatsheet so the agent always knows what
# runbooks are (skills only carry the long procedures, and are retrieval-gated).
# openshell upload can't overwrite this dotfile path, so write via exec+base64.
log "Installing agent standing context (SOUL.md)"
SOUL_B64="$(base64 < "$REPO_ROOT/sandbox/agent-context/SOUL.md")"
openshell sandbox exec -n "$SANDBOX" -- sh -lc \
  "printf %s '$SOUL_B64' | base64 -d > /sandbox/.hermes/SOUL.md"

# --- 6. snapshot (machine-local durability across recreate) ------------------
log "Creating snapshot 'provisioned'"
nemohermes runbooks snapshot create --name provisioned || true

# --- 7. print what the desktop app needs ------------------------------------
log "Done. For the app's chat bar, put these in the repo-root .env:"
echo "  HERMES_API_URL = http://127.0.0.1:8642/v1/chat/completions"
printf "  HERMES_API_TOKEN = "; nemohermes runbooks gateway-token --quiet 2>/dev/null; echo
echo
echo "Pipeline entrypoint is /sandbox/pipeline/pipeline/run.py inside the sandbox."
echo "Run:  openshell sandbox exec -n $SANDBOX -- python3 /sandbox/pipeline/pipeline/run.py /sandbox/videos/<clip>.mov \"my workflow\""
