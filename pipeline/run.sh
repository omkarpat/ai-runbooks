#!/usr/bin/env bash
# Orchestrate: recording -> runbook.
#
# Usage: run.sh <video.mov> [workflow-name] [--skip-synthesis]
#
# Runs inside the NemoClaw sandbox. Reads keys from /sandbox/.env if present:
#   HAI_API_KEY, GRADIUM_API_KEY, SYNTH_TOKEN (+ optional overrides, see the
#   individual scripts' headers).
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
[ -f /sandbox/.env ] && set -a && . /sandbox/.env && set +a

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
