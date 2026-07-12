#!/usr/bin/env python3
"""Extract keyframes: scene-change detection with a periodic floor.

Usage:  extract_frames.py <video> <out_dir>

Env:    SCENE_THRESH  scene-change score 0..1        (default 0.10)
        FLOOR_SECS    max gap between samples, sec   (default 1)
        MAX_WIDTH     downscale ceiling for Holo     (default 1920)

Output: <out_dir>/frame_<seconds>.png  (e.g. frame_000012.40.png)
Exit:   0 ok · 4 fewer than 2 frames (pair analysis impossible)
"""
import os
import re
import subprocess
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    video, out_dir = sys.argv[1], Path(sys.argv[2])
    thresh = os.environ.get("SCENE_THRESH", "0.10")
    floor = os.environ.get("FLOOR_SECS", "1")
    max_w = os.environ.get("MAX_WIDTH", "1920")

    out_dir.mkdir(parents=True, exist_ok=True)

    # isnan() selects the very first frame (prev_selected_t is NaN until
    # something is selected); after that: scene change OR floor elapsed.
    vf = (
        f"select='isnan(prev_selected_t)+gt(scene,{thresh})"
        f"+gte(t-prev_selected_t,{floor})',"
        f"showinfo,scale='min({max_w},iw)':-2"
    )
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-y", "-i", video,
         "-vf", vf, "-vsync", "vfr", str(out_dir / "tmp_%06d.png")],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        print(proc.stderr[-2000:], file=sys.stderr)
        print("extract_frames: ffmpeg failed", file=sys.stderr)
        return 1

    # showinfo logs one pts_time per selected frame, in output order.
    times = re.findall(r"pts_time:([0-9.]+)", proc.stderr)
    count = 0
    for i, t in enumerate(times, start=1):
        src = out_dir / f"tmp_{i:06d}.png"
        if not src.exists():
            break
        src.rename(out_dir / f"frame_{float(t):09.2f}.png")
        count += 1
    for leftover in out_dir.glob("tmp_*.png"):
        leftover.unlink()

    print(f"extract_frames: {count} keyframes -> {out_dir}", file=sys.stderr)
    if count < 2:
        print("extract_frames: need >=2 frames for pair analysis", file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
