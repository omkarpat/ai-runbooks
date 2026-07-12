#!/usr/bin/env python3
"""Orchestrate: recording -> runbook.

Usage:  run.py <video.mov> [workflow-name] [--skip-synthesis] [--skip-ingest]

Keys/config are loaded from the first .env found (already-exported shell env
always wins over the file):
  1. $ENV_FILE            explicit override
  2. /sandbox/.env        sandbox path
  3. <repo-root>/.env     local dev (gitignored; see .env.example)
Vars: HAI_API_KEY, GRADIUM_API_KEY, SYNTH_URL/SYNTH_TOKEN/SYNTH_MODEL,
RUNBOOKS_DIR, KB_DIR (+ tuning knobs, see the stage scripts' headers).

--skip-synthesis stops after steps.jsonl/transcript.jsonl (used when the
Hermes agent itself performs synthesis — skill path). It also implies
--skip-ingest: the agent calls kb.py ingest itself AFTER writing runbook.md,
so the KB entry carries the runbook (and the merge check sees it).
--skip-ingest skips registering the run in the knowledge base (kb.py).

Output: $RUNBOOKS_DIR/<name>_<epoch>/{runbook.md,steps.jsonl,transcript.jsonl,work/}
plus a knowledge-base entry under $KB_DIR (see kb.py).
"""
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PY = sys.executable or "python3"


def load_env() -> None:
    candidates = []
    if os.environ.get("ENV_FILE"):
        candidates.append(Path(os.environ["ENV_FILE"]))
    candidates += [Path("/sandbox/.env"), HERE.parent / ".env"]
    for path in candidates:
        if path.is_file():
            for line in path.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                os.environ.setdefault(key.strip(), value.strip())
            print(f"run: loaded env from {path}", file=sys.stderr)
            return


def stage(script: str, *args: str) -> int:
    """Run a pipeline stage, streaming its stderr through."""
    return subprocess.run([PY, str(HERE / script), *args]).returncode


def main() -> int:
    flags = ("--skip-synthesis", "--skip-ingest")
    argv = [a for a in sys.argv[1:] if a not in flags]
    skip_synth = "--skip-synthesis" in sys.argv
    skip_ingest = "--skip-ingest" in sys.argv
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    video = argv[0]
    name = argv[1] if len(argv) > 1 else Path(video).stem

    load_env()

    safe = name.replace(" ", "-").replace("/", "-")
    run_dir = Path(os.environ.get("RUNBOOKS_DIR", "/sandbox/runbooks")) \
        / f"{safe}_{int(time.time())}"
    work = run_dir / "work"
    frames = work / "frames"
    frames.mkdir(parents=True, exist_ok=True)
    print(f"run: {video} -> {run_dir}", file=sys.stderr)

    # --- 1. frames and audio in parallel --------------------------------------
    results = {}

    def frames_job():
        results["frames"] = stage("extract_frames.py", video, str(frames))

    def audio_job():
        results["audio"] = stage("extract_audio.py", video, str(work / "audio.wav"))

    threads = [threading.Thread(target=frames_job),
               threading.Thread(target=audio_job)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    if results["frames"] != 0:
        print("run: frame extraction failed — aborting", file=sys.stderr)
        return results["frames"]

    # --- 2. transcription (graceful degradation) ------------------------------
    transcript = "-"
    if results["audio"] == 0:
        rc = stage("transcribe.py", str(work / "audio.wav"),
                   str(run_dir / "transcript.jsonl"))
        if rc == 0:
            transcript = str(run_dir / "transcript.jsonl")
        else:
            print("run: transcription unavailable — continuing video-only",
                  file=sys.stderr)
    else:
        print("run: no usable narration — continuing video-only", file=sys.stderr)

    # --- 3. per-pair action inference (Holo) ----------------------------------
    rc = stage("analyze_pairs.py", str(frames), str(run_dir / "steps.jsonl"))
    if rc != 0:
        print("run: action inference failed — aborting", file=sys.stderr)
        return rc

    # --- 4. synthesis ----------------------------------------------------------
    if skip_synth:
        print(f"run: skipping synthesis (agent will synthesize). "
              f"Artifacts in {run_dir}", file=sys.stderr)
    else:
        rc = stage("synthesize.py", str(run_dir / "steps.jsonl"), transcript,
                   str(run_dir / "runbook.md"), name)
        if rc != 0:
            print("run: synthesis failed", file=sys.stderr)
            return rc
        print(f"run: done -> {run_dir}/runbook.md", file=sys.stderr)

    # --- 5. ingest into the knowledge base (never fatal) -----------------------
    # --skip-synthesis implies --skip-ingest: there is no runbook.md yet, the
    # agent writes it and then calls kb.py ingest itself (runbook-builder skill).
    if skip_ingest or skip_synth:
        reason = "(agent synthesizes + ingests via kb.py)" if skip_synth else ""
        print(f"run: skipping KB ingest {reason}".rstrip(), file=sys.stderr)
    else:
        # Captured (not streamed) so kb.py's JSON stdout can't pollute this
        # script's stdout contract: stdout is the run dir path, nothing else.
        proc = subprocess.run(
            [PY, str(HERE / "kb.py"), "ingest", str(run_dir), video,
             "--name", name],
            capture_output=True, text=True)
        for chunk in (proc.stderr, proc.stdout):
            if chunk.strip():
                print(chunk.strip(), file=sys.stderr)
        if proc.returncode != 0:
            print("run: WARNING KB ingest failed — run dir is preserved",
                  file=sys.stderr)

    print(run_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
