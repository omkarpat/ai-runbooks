#!/usr/bin/env python3
"""Infer user actions from consecutive keyframe pairs via the Holo VLM.

Usage:  analyze_pairs.py <frames_dir> <out_steps.jsonl>

Env:    HAI_API_KEY   required (hk-...)
        HOLO_URL      default https://api.hcompany.ai/v1/chat/completions
        HOLO_MODEL    default holo3-1-35b-a3b
        HOLO_RPM      request budget per minute (default 10 = free tier)

Input:  frames_dir/frame_<seconds>.png (from extract_frames.sh)
Output: one JSON object per line:
        {"t0","t1","action","target","details","confidence"}

Each call sends the before+after frame (2 images — within H's guidance of
keeping <=3 images in context) and asks what single user action explains the
transition. Plain-JSON prompting for v1; TODO: switch to Holo structured
outputs (top-level `structured_outputs` body field) once schema is pinned.
"""
import base64
import json
import os
import re
import sys
import time
from pathlib import Path

import requests

DEFAULT_URL = "https://api.hcompany.ai/v1/chat/completions"

PROMPT = """These are two consecutive screenshots (BEFORE, then AFTER) from a screen \
recording of a user performing a workflow on a desktop computer.

Identify the single user action that most plausibly explains the change from \
BEFORE to AFTER. Answer with ONLY a JSON object, no other text:

{"action": "<verb phrase, e.g. 'clicked Send button'>",
 "target": "<the UI element/app acted on, e.g. 'Gmail compose window'>",
 "details": "<text typed, option chosen, or '' if none>",
 "confidence": <0.0-1.0>}

If nothing meaningful changed (cursor moved, spinner, animation), use \
{"action": "none", "target": "", "details": "", "confidence": 1.0}."""


def b64_image(path: Path) -> dict:
    data = base64.b64encode(path.read_bytes()).decode()
    return {"type": "image_url",
            "image_url": {"url": f"data:image/png;base64,{data}"}}


def parse_json_reply(text: str) -> dict:
    """Extract the first JSON object from a model reply, tolerantly."""
    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        raise ValueError(f"no JSON in reply: {text[:120]!r}")
    return json.loads(match.group(0))


def frame_time(path: Path) -> float:
    return float(path.stem.split("_", 1)[1])


def call_holo(url, key, model, frames, timeout=120, retries=3):
    body = {
        "model": model,
        "max_tokens": 512,
        "messages": [{
            "role": "user",
            "content": [b64_image(frames[0]), b64_image(frames[1]),
                        {"type": "text", "text": PROMPT}],
        }],
    }
    backoff = 10
    for attempt in range(retries + 1):
        resp = requests.post(
            url, json=body, timeout=timeout,
            headers={"Authorization": f"Bearer {key}"})
        if resp.status_code == 429 and attempt < retries:
            time.sleep(backoff)
            backoff *= 2
            continue
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]
    raise RuntimeError("rate-limited after retries")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    frames_dir, out_path = Path(sys.argv[1]), sys.argv[2]

    key = os.environ.get("HAI_API_KEY", "")
    if not key:
        print("analyze_pairs: HAI_API_KEY not set", file=sys.stderr)
        return 2
    url = os.environ.get("HOLO_URL", DEFAULT_URL)
    model = os.environ.get("HOLO_MODEL", "holo3-1-35b-a3b")
    rpm = max(1, int(os.environ.get("HOLO_RPM", "10")))
    min_interval = 60.0 / rpm

    frames = sorted(frames_dir.glob("frame_*.png"), key=frame_time)
    if len(frames) < 2:
        print("analyze_pairs: need >=2 frames", file=sys.stderr)
        return 2

    n_pairs = len(frames) - 1
    print(f"analyze_pairs: {n_pairs} pairs, model={model}, "
          f"budget {rpm} rpm (~{n_pairs * min_interval / 60:.1f} min)",
          file=sys.stderr)

    written = 0
    last_call = 0.0
    with open(out_path, "w") as out:
        for i, (a, b) in enumerate(zip(frames, frames[1:])):
            wait = min_interval - (time.monotonic() - last_call)
            if wait > 0:
                time.sleep(wait)
            last_call = time.monotonic()
            try:
                reply = call_holo(url, key, model, (a, b))
                step = parse_json_reply(reply)
            except Exception as exc:  # one bad pair shouldn't kill the run
                print(f"analyze_pairs: pair {i} failed: {exc}", file=sys.stderr)
                continue
            if step.get("action", "none") == "none":
                continue
            record = {
                "t0": frame_time(a), "t1": frame_time(b),
                "action": str(step.get("action", ""))[:300],
                "target": str(step.get("target", ""))[:300],
                "details": str(step.get("details", ""))[:1000],
                "confidence": float(step.get("confidence", 0.0)),
            }
            out.write(json.dumps(record) + "\n")
            written += 1
            print(f"analyze_pairs: [{i + 1}/{n_pairs}] "
                  f"{record['action']} ({record['confidence']:.2f})",
                  file=sys.stderr)

    print(f"analyze_pairs: {written} steps -> {out_path}", file=sys.stderr)
    return 0 if written else 3


if __name__ == "__main__":
    sys.exit(main())
