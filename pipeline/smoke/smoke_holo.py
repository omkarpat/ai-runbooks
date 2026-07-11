#!/usr/bin/env python3
"""Milestone B smoke test: one Holo call from inside the sandbox.

Generates a tiny test image in-process (no fixtures needed), sends it to
chat completions, and prints the model's description. Success = HTTP 200
and a non-empty reply.

Run inside the sandbox:  python3 smoke_holo.py
Needs: HAI_API_KEY (and the holo-models-api egress policy applied).
"""
import base64
import io
import os
import struct
import sys
import zlib

import requests

URL = os.environ.get("HOLO_URL", "https://api.hcompany.ai/v1/chat/completions")
MODEL = os.environ.get("HOLO_MODEL", "holo3-1-35b-a3b")


def tiny_png(width=64, height=64) -> bytes:
    """A minimal valid PNG (red square) built with stdlib only."""
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


def main() -> int:
    key = os.environ.get("HAI_API_KEY", "")
    if not key:
        print("FAIL: HAI_API_KEY not set")
        return 2
    img = base64.b64encode(tiny_png()).decode()
    resp = requests.post(URL, timeout=60,
                         headers={"Authorization": f"Bearer {key}"},
                         json={"model": MODEL, "max_tokens": 64, "messages": [{
                             "role": "user",
                             "content": [
                                 {"type": "image_url", "image_url": {
                                     "url": f"data:image/png;base64,{img}"}},
                                 {"type": "text",
                                  "text": "What color is this image? One word."},
                             ]}]})
    if resp.status_code != 200:
        print(f"FAIL: HTTP {resp.status_code}: {resp.text[:200]}")
        return 1
    reply = resp.json()["choices"][0]["message"]["content"]
    print(f"OK: Holo ({MODEL}) replied: {reply.strip()[:80]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
