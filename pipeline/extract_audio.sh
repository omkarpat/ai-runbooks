#!/usr/bin/env bash
# Extract the narration (microphone) track for STT.
#
# The recorder app writes two audio tracks (RECORDING_CONTRACT.md §1):
#   a:0 system audio, a:1 microphone. We want the mic, downmixed to mono
#   16-bit PCM at 24 kHz (Gradium's native rate).
#
# Usage: extract_audio.sh <video> <out_wav>
# Exit codes: 0 ok · 3 no usable narration track (caller should degrade, not die)
set -euo pipefail

VIDEO="${1:?usage: extract_audio.sh <video> <out_wav>}"
OUT="${2:?usage: extract_audio.sh <video> <out_wav>}"

# Count audio streams; contract says 2, but mic capture is best-effort.
NSTREAMS=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$VIDEO" | wc -l)

if [ "$NSTREAMS" -ge 2 ]; then
  MAP="0:a:1"          # contract layout: mic is the second audio track
elif [ "$NSTREAMS" -eq 1 ]; then
  MAP="0:a:0"          # single track: assume it's the narration (non-app source)
  echo "extract_audio: only one audio track, using a:0" >&2
else
  echo "extract_audio: no audio track — degrading to video-only" >&2
  exit 3
fi

ffmpeg -hide_banner -y -i "$VIDEO" -map "$MAP" -vn -ac 1 -ar 24000 -c:a pcm_s16le "$OUT" 2>/dev/null

# A silent mic (permission denied but track present) produces a valid but
# useless wav; detect near-silence so the caller can skip the STT spend.
MEANVOL=$(ffmpeg -hide_banner -i "$OUT" -af volumedetect -f null - 2>&1 \
          | grep -o 'mean_volume: [-0-9.]* dB' | grep -o '\-\?[0-9.]*' | head -1 || echo "")
if [ -n "$MEANVOL" ] && awk "BEGIN{exit !($MEANVOL < -60)}"; then
  echo "extract_audio: mic track is near-silent (mean ${MEANVOL} dB) — degrading" >&2
  exit 3
fi

echo "extract_audio: narration -> $OUT (mean volume ${MEANVOL:-n/a} dB)" >&2
