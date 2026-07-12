#!/usr/bin/env python3
"""Shared LLM chat helper for pipeline stages (synthesize, kb merge/compare).

Env:    SYNTH_URL     default http://127.0.0.1:8642/v1/chat/completions
        SYNTH_TOKEN   bearer token (empty = no auth header, e.g. local Ollama)
        SYNTH_MODEL   default "default"
"""
import json
import os
import re
import sys
import time
from pathlib import Path

import requests


def load_env() -> None:
    """Populate os.environ from the first .env found (exported env wins).
    Same candidate order as run.py — needed when kb.py/synthesize.py run
    standalone (e.g. a Hermes skill shelling out to kb.py directly)."""
    candidates = []
    if os.environ.get("ENV_FILE"):
        candidates.append(Path(os.environ["ENV_FILE"]))
    here = Path(__file__).resolve().parent
    candidates += [Path("/sandbox/.env"), here.parent / ".env"]
    for path in candidates:
        if path.is_file():
            for line in path.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                os.environ.setdefault(key.strip(), value.strip())
            return


def chat(system: str, user: str, *, timeout: int = 600) -> str:
    """One chat completion; retries once on transport/5xx errors, then raises."""
    url = os.environ.get("SYNTH_URL",
                         "http://127.0.0.1:8642/v1/chat/completions")
    token = os.environ.get("SYNTH_TOKEN", "")
    model = os.environ.get("SYNTH_MODEL", "default")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    payload = {"model": model,
               "messages": [{"role": "system", "content": system},
                            {"role": "user", "content": user}]}

    last = None
    for attempt in (1, 2):
        try:
            resp = requests.post(url, timeout=timeout, headers=headers,
                                 json=payload)
            if resp.status_code >= 500:
                raise requests.RequestException(f"HTTP {resp.status_code}")
            resp.raise_for_status()
            return resp.json()["choices"][0]["message"]["content"]
        except (requests.RequestException, KeyError, ValueError) as e:
            last = e
            if attempt == 1:
                print(f"llm: attempt 1 failed ({e}) — retrying",
                      file=sys.stderr)
                time.sleep(2)
    raise RuntimeError(f"llm: request failed after retry: {last}")


def parse_json_loose(text: str):
    """Best-effort dict from a model reply: strips code fences, grabs the
    first {...} block. Returns None if nothing parses (small local models
    routinely wrap or garble JSON — callers must treat None as a soft miss)."""
    if not text:
        return None
    cleaned = re.sub(r"```(?:json)?", "", text)
    match = re.search(r"\{.*\}", cleaned, re.DOTALL)
    if not match:
        return None
    try:
        parsed = json.loads(match.group(0))
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None
