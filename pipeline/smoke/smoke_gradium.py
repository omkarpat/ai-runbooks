#!/usr/bin/env python3
"""Milestone B smoke test: one Gradium STT call from inside the sandbox.

Generates a 1-second 24 kHz mono WAV (a quiet tone — we only care that the
endpoint accepts the request and streams NDJSON back; "no speech" is a PASS
for connectivity purposes).

Run inside the sandbox:  python3 smoke_gradium.py
Needs: GRADIUM_API_KEY (and the gradium-stt egress policy applied).
"""
import io
import json
import math
import os
import struct
import sys
import wave

import requests

URL = os.environ.get("GRADIUM_URL", "https://api.gradium.ai/api/post/speech/asr")


def tone_wav(seconds=1.0, rate=24000, freq=440.0) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        n = int(seconds * rate)
        frames = b"".join(
            struct.pack("<h", int(8000 * math.sin(2 * math.pi * freq * i / rate)))
            for i in range(n))
        w.writeframes(frames)
    return buf.getvalue()


def main() -> int:
    key = os.environ.get("GRADIUM_API_KEY", "")
    if not key:
        print("FAIL: GRADIUM_API_KEY not set")
        return 2
    resp = requests.post(URL, data=tone_wav(), stream=True, timeout=(10, 120),
                         headers={"x-api-key": key, "Content-Type": "audio/wav"})
    if resp.status_code != 200:
        print(f"FAIL: HTTP {resp.status_code}: {resp.text[:200]}")
        return 1
    types = []
    for line in resp.iter_lines(decode_unicode=True):
        if line:
            types.append(json.loads(line).get("type"))
    print(f"OK: Gradium streamed {len(types)} NDJSON messages "
          f"(types: {sorted(set(types))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
