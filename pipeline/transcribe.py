#!/usr/bin/env python3
"""Transcribe narration audio via Gradium STT (one-shot REST).

Usage:  transcribe.py <audio.wav> <out_transcript.jsonl>

Env:    GRADIUM_API_KEY   required (gd_...)
        GRADIUM_URL       default https://api.gradium.ai/api/post/speech/asr
        STT_LANGUAGE      default "en"

Output: one JSON object per line: {"t0": float, "t1": float, "text": str}

The REST endpoint streams NDJSON back. `text` messages carry `start_s`;
the paired `end_text` carries `stop_s` — pair them by `stream_id` (falling
back to arrival order if ids are absent).

Exit codes: 0 ok · 2 config error · 3 STT failed / empty (caller degrades)
"""
import json
import os
import sys

import requests

DEFAULT_URL = "https://api.gradium.ai/api/post/speech/asr"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    wav_path, out_path = sys.argv[1], sys.argv[2]

    api_key = os.environ.get("GRADIUM_API_KEY", "")
    if not api_key:
        print("transcribe: GRADIUM_API_KEY not set", file=sys.stderr)
        return 2

    url = os.environ.get("GRADIUM_URL", DEFAULT_URL)
    language = os.environ.get("STT_LANGUAGE", "en")

    with open(wav_path, "rb") as f:
        audio = f.read()

    segments = []       # finalized {"t0","t1","text"}
    open_by_id = {}     # stream_id -> {"t0", "text"} awaiting end_text
    order = []          # arrival order of open segments (fallback pairing)

    try:
        with requests.post(
            url,
            params={"json_config": json.dumps({"language": language})},
            data=audio,
            headers={"x-api-key": api_key, "Content-Type": "audio/wav"},
            stream=True,
            timeout=(10, 600),
        ) as resp:
            if resp.status_code != 200:
                print(f"transcribe: HTTP {resp.status_code}: {resp.text[:200]}",
                      file=sys.stderr)
                return 3
            for line in resp.iter_lines(decode_unicode=True):
                if not line:
                    continue
                msg = json.loads(line)
                mtype = msg.get("type")
                if mtype == "text":
                    sid = msg.get("stream_id", len(order))
                    open_by_id[sid] = {"t0": float(msg.get("start_s", 0.0)),
                                       "text": (msg.get("text") or "").strip()}
                    order.append(sid)
                elif mtype == "end_text":
                    sid = msg.get("stream_id")
                    if sid not in open_by_id and order:
                        sid = order[0]
                    seg = open_by_id.pop(sid, None)
                    if sid in order:
                        order.remove(sid)
                    if seg and seg["text"]:
                        segments.append({"t0": seg["t0"],
                                         "t1": float(msg.get("stop_s", seg["t0"])),
                                         "text": seg["text"]})
                elif mtype == "error":
                    print(f"transcribe: server error: {msg.get('message')}",
                          file=sys.stderr)
                    return 3
    except requests.RequestException as exc:
        print(f"transcribe: request failed: {exc}", file=sys.stderr)
        return 3

    # Close any segment that never got an end_text.
    for sid in order:
        seg = open_by_id.get(sid)
        if seg and seg["text"]:
            segments.append({"t0": seg["t0"], "t1": seg["t0"], "text": seg["text"]})

    if not segments:
        print("transcribe: no speech detected", file=sys.stderr)
        return 3

    segments.sort(key=lambda s: s["t0"])
    with open(out_path, "w") as f:
        for seg in segments:
            f.write(json.dumps(seg) + "\n")
    print(f"transcribe: {len(segments)} segments -> {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
