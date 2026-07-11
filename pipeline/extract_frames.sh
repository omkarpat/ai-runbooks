#!/usr/bin/env bash
# Extract keyframes from a screen recording: scene-change detection with a
# periodic floor, so both sharp transitions and slow interactions are sampled.
#
# Usage: extract_frames.sh <video> <out_dir>
# Output: <out_dir>/frame_<seconds>.png  (zero-padded, e.g. frame_0012.40.png)
#
# Tunables (env):
#   SCENE_THRESH  scene-change score threshold 0..1   (default 0.10)
#   FLOOR_SECS    max gap between samples in seconds  (default 1)
#   MAX_WIDTH     downscale ceiling for Holo cost     (default 1920; Retina 2x
#                 recordings are ~5K wide — full res is wasted tokens)
set -euo pipefail

VIDEO="${1:?usage: extract_frames.sh <video> <out_dir>}"
OUT="${2:?usage: extract_frames.sh <video> <out_dir>}"
SCENE_THRESH="${SCENE_THRESH:-0.10}"
FLOOR_SECS="${FLOOR_SECS:-1}"
MAX_WIDTH="${MAX_WIDTH:-1920}"

mkdir -p "$OUT"
LOG="$OUT/.showinfo.log"

# Select a frame when the scene changes OR when FLOOR_SECS elapsed since the
# last selected frame ('prev_selected_t' is ffmpeg's own bookkeeping).
# showinfo logs each selected frame's pts_time so we can timestamp filenames.
# isnan() term selects the very first frame (prev_selected_t is NaN until
# something has been selected, which would otherwise suppress everything).
ffmpeg -hide_banner -y -i "$VIDEO" \
  -vf "select='isnan(prev_selected_t)+gt(scene,${SCENE_THRESH})+gte(t-prev_selected_t,${FLOOR_SECS})',showinfo,scale='min(${MAX_WIDTH},iw)':-2" \
  -vsync vfr "$OUT/tmp_%06d.png" 2> "$LOG"

# Rename tmp_NNNNNN.png -> frame_<pts>.png using showinfo's pts_time sequence.
mapfile -t TIMES < <(grep -o 'pts_time:[0-9.]*' "$LOG" | cut -d: -f2)
i=1
for t in "${TIMES[@]}"; do
  src=$(printf '%s/tmp_%06d.png' "$OUT" "$i")
  [ -f "$src" ] || break
  mv "$src" "$(printf '%s/frame_%09.2f.png' "$OUT" "$t")"
  i=$((i + 1))
done
rm -f "$OUT"/tmp_*.png "$LOG"

COUNT=$(find "$OUT" -name 'frame_*.png' | wc -l)
echo "extract_frames: $COUNT keyframes -> $OUT" >&2
[ "$COUNT" -ge 2 ] || { echo "extract_frames: need >=2 frames for pair analysis" >&2; exit 4; }
