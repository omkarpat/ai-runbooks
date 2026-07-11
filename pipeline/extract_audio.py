#!/usr/bin/env python3
"""Extract the narration (microphone) track for STT.

The recorder app writes two audio tracks (RECORDING_CONTRACT.md §1):
a:0 system audio, a:1 microphone. We take the mic, downmixed to mono
16-bit PCM at 24 kHz (Gradium's native rate).

Usage:  extract_audio.py <video> <out_wav>
Exit:   0 ok · 3 no usable narration (caller degrades, not dies) · 1 error
"""
import re
import subprocess
import sys

SILENCE_DB = -60.0


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    video, out_wav = sys.argv[1], sys.argv[2]

    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a",
         "-show_entries", "stream=index", "-of", "csv=p=0", video],
        capture_output=True, text=True)
    n_streams = len([l for l in probe.stdout.splitlines() if l.strip()])

    if n_streams >= 2:
        amap = "0:a:1"       # contract layout: mic is the second audio track
    elif n_streams == 1:
        amap = "0:a:0"       # single track: assume narration (non-app source)
        print("extract_audio: only one audio track, using a:0", file=sys.stderr)
    else:
        print("extract_audio: no audio track — degrading to video-only",
              file=sys.stderr)
        return 3

    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-y", "-i", video, "-map", amap, "-vn",
         "-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le", out_wav],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        print(proc.stderr[-2000:], file=sys.stderr)
        print("extract_audio: ffmpeg failed", file=sys.stderr)
        return 1

    # Silent mic (permission denied but track present) → skip the STT spend.
    vol = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", out_wav, "-af", "volumedetect",
         "-f", "null", "-"],
        capture_output=True, text=True)
    match = re.search(r"mean_volume:\s*(-?[0-9.]+)\s*dB", vol.stderr)
    mean_db = float(match.group(1)) if match else None
    if mean_db is not None and mean_db < SILENCE_DB:
        print(f"extract_audio: mic near-silent (mean {mean_db} dB) — degrading",
              file=sys.stderr)
        return 3

    print(f"extract_audio: narration -> {out_wav} "
          f"(mean volume {mean_db if mean_db is not None else 'n/a'} dB)",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
