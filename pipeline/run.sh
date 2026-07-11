#!/usr/bin/env bash
# Orchestrate: recording -> runbook.
#
# Usage: run.sh <video.mov> [workflow-name] [--skip-synthesis]
#
# Keys/config are loaded from the first .env found (later shell env wins if
# a var is already exported):
#   1. $ENV_FILE            explicit override
#   2. /sandbox/.env        sandbox path
#   3. <repo-root>/.env     local dev on the Mac (gitignored; see .env.example)
# Vars: HAI_API_KEY, GRADIUM_API_KEY, SYNTH_URL/SYNTH_TOKEN/SYNTH_MODEL
# (+ optional overrides, see the individual scripts' headers).
#
# --skip-synthesis stops after steps.jsonl/transcript.jsonl. Used when the
# Hermes agent itself performs synthesis (skill path) instead of calling its
# own API reentrantly.
#
# Output: /sandbox/runbooks/<name>_<epoch>/{runbook.md,steps.jsonl,transcript.jsonl,work/}
set -euo pipefail

VIDEO="${1:?usage: run.sh <video.mov> [workflow-name] [--skip-synthesis]}"
NAME="${2:-$(basename "${VIDEO%.*}")}"
SKIP_SYNTH="${3:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- env loading: explicit ENV_FILE > sandbox > repo-local ---------------------
load_env() {
  # Values already exported in the shell take precedence over the file.
  local f="$1" line key
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"
    [ -n "${!key:-}" ] || export "${line?}"
  done < "$f"
  echo "run: loaded env from $f" >&2
}
if [ -n "${ENV_FILE:-}" ] && [ -f "$ENV_FILE" ]; then
  load_env "$ENV_FILE"
elif [ -f /sandbox/.env ]; then
  load_env /sandbox/.env
elif [ -f "$HERE/../.env" ]; then
  load_env "$HERE/../.env"
fi

RUN_DIR="${RUNBOOKS_DIR:-/sandbox/runbooks}/$(echo "$NAME" | tr ' /' '--')_$(date +%s)"
WORK="$RUN_DIR/work"
mkdir -p "$WORK/frames"

echo "run: $VIDEO -> $RUN_DIR" >&2

# --- 1. extract frames and audio (parallel branches) -------------------------
"$HERE/extract_frames.sh" "$VIDEO" "$WORK/frames" &
FRAMES_PID=$!

HAVE_AUDIO=1
"$HERE/extract_audio.sh" "$VIDEO" "$WORK/audio.wav" || HAVE_AUDIO=0 &
AUDIO_PID=$!

wait "$FRAMES_PID"   # frames are mandatory
wait "$AUDIO_PID" || HAVE_AUDIO=0

# --- 2. transcribe narration (graceful degradation) --------------------------
TRANSCRIPT="-"
if [ "$HAVE_AUDIO" -eq 1 ] && [ -f "$WORK/audio.wav" ]; then
  if python3 "$HERE/transcribe.py" "$WORK/audio.wav" "$RUN_DIR/transcript.jsonl"; then
    TRANSCRIPT="$RUN_DIR/transcript.jsonl"
  else
    echo "run: transcription unavailable — continuing video-only" >&2
  fi
fi

# --- 3. per-pair action inference (Holo) --------------------------------------
python3 "$HERE/analyze_pairs.py" "$WORK/frames" "$RUN_DIR/steps.jsonl"

# --- 4. synthesis --------------------------------------------------------------
if [ "$SKIP_SYNTH" = "--skip-synthesis" ]; then
  echo "run: skipping synthesis (agent will synthesize). Artifacts in $RUN_DIR" >&2
else
  python3 "$HERE/synthesize.py" "$RUN_DIR/steps.jsonl" "$TRANSCRIPT" \
          "$RUN_DIR/runbook.md" "$NAME"
  echo "run: done -> $RUN_DIR/runbook.md" >&2
fi

echo "$RUN_DIR"
