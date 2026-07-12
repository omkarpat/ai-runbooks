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
 "context": "<application> — <exact visible window/page/document title in the \
AFTER screenshot, e.g. 'Safari — Contact information (Google Forms)'>",
 "confidence": <0.0-1.0>}

If nothing meaningful changed (cursor moved, spinner, animation), use \
{"action": "none", "target": "", "details": "", "context": "", "confidence": 1.0}."""


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
    last_err = None
    for attempt in range(retries + 1):
        try:
            resp = requests.post(
                url, json=body, timeout=timeout,
                headers={"Authorization": f"Bearer {key}"})
        except (requests.Timeout, requests.ConnectionError) as exc:
            # Transient network trouble (read timeout, reset, DNS blip):
            # retry with backoff instead of losing the pair.
            last_err = exc
            if attempt < retries:
                print(f"analyze_pairs: transient error "
                      f"({type(exc).__name__}), retry {attempt + 1}/{retries} "
                      f"in {backoff}s", file=sys.stderr)
                time.sleep(backoff)
                backoff *= 2
                continue
            raise RuntimeError(f"gave up after {retries} retries: {exc}")
        if resp.status_code in (429, 500, 502, 503, 504) and attempt < retries:
            print(f"analyze_pairs: HTTP {resp.status_code}, "
                  f"retry {attempt + 1}/{retries} in {backoff}s", file=sys.stderr)
            time.sleep(backoff)
            backoff *= 2
            continue
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"]
    raise RuntimeError(f"exhausted retries: {last_err or 'rate-limited'}")


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
    last_context = ""       # carry-forward when Holo omits/fumbles context
    records = []
    with open(out_path, "w") as out:
        for i, (a, b) in enumerate(zip(frames, frames[1:])):
            wait = min_interval - (time.monotonic() - last_call)
            if wait > 0:
                time.sleep(wait)
            last_call = time.monotonic()
            t_start = time.monotonic()
            try:
                reply = call_holo(url, key, model, (a, b))
                step = parse_json_reply(reply)
            except Exception as exc:  # one bad pair shouldn't kill the run
                print(f"analyze_pairs: pair {i} failed after "
                      f"{time.monotonic() - t_start:.1f}s: {exc}",
                      file=sys.stderr)
                continue
            elapsed = time.monotonic() - t_start
            if step.get("action", "none") == "none":
                print(f"analyze_pairs: [{i + 1}/{n_pairs}] none "
                      f"({elapsed:.1f}s)", file=sys.stderr)
                continue
            context = str(step.get("context", "")).strip()[:200]
            if context:
                last_context = context
            record = {
                "t0": frame_time(a), "t1": frame_time(b),
                "action": str(step.get("action", ""))[:300],
                "target": str(step.get("target", ""))[:300],
                "details": str(step.get("details", ""))[:1000],
                "context": context or last_context,
                "confidence": float(step.get("confidence", 0.0)),
            }
            out.write(json.dumps(record) + "\n")
            records.append(record)
            written += 1
            print(f"analyze_pairs: [{i + 1}/{n_pairs}] "
                  f"{record['action']} ({record['confidence']:.2f}) "
                  f"[{elapsed:.1f}s]",
                  file=sys.stderr)

    if records:
        chain = build_context_chain(records)
        chain_path = str(Path(out_path).parent / "context_chain.json")
        with open(chain_path, "w") as f:
            json.dump(chain, f, indent=1)
        print(f"analyze_pairs: context chain ({len(chain['phases'])} phases, "
              f"dominant: {chain['dominant'] or 'n/a'}) -> {chain_path}",
              file=sys.stderr)

    print(f"analyze_pairs: {written} steps -> {out_path}", file=sys.stderr)
    return 0 if written else 3


def build_context_chain(records):
    """Reduce per-step contexts into ordered phases + a dominant context.

    No privileged frame: identity is derived by aggregation, so irrelevant
    openings (permission dialogs) and chained sub-contexts fall out naturally.
    """
    phases = []
    for rec in records:
        ctx = rec.get("context", "")
        if phases and phases[-1]["context"] == ctx:
            phases[-1]["t1"] = rec["t1"]
            phases[-1]["steps"] += 1
        else:
            phases.append({"context": ctx, "t0": rec["t0"],
                           "t1": rec["t1"], "steps": 1})
    # Dominant = most steps, ties broken by longest duration.
    totals = {}
    for ph in phases:
        key = ph["context"]
        cur = totals.setdefault(key, {"steps": 0, "secs": 0.0})
        cur["steps"] += ph["steps"]
        cur["secs"] += ph["t1"] - ph["t0"]
    dominant = ""
    if totals:
        dominant = max(totals, key=lambda k: (totals[k]["steps"],
                                              totals[k]["secs"]))
    return {"dominant": dominant, "phases": phases}


if __name__ == "__main__":
    sys.exit(main())
