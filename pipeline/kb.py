#!/usr/bin/env python3
"""Stateful runbook knowledge base (NEXT_STEPS N1).

Usage:  kb.py ingest <run_dir> <video> [--name NAME]
        kb.py list [--status STATUS]
        kb.py show <workflow_id>

Env:    KB_DIR   knowledge-base root (default /sandbox/kb)

Every command prints exactly one JSON object to stdout; logs go to stderr.
Exit codes: 0 ok, 2 usage, 3 not found, 5 IO/catalog error.

Layout:
  $KB_DIR/catalog.json
  $KB_DIR/<workflow-id>/
    runbook.md        canonical version
    versions/         prior canonicals (written by N3 merges / N5 edits)
    runs/<epoch>/     steps.jsonl, context_chain.json, transcript.jsonl,
                      runbook.md, recording.mov, audio.wav, frames/
    edits.jsonl       merge/edit decision log (N3/N5)

Until N3 lands, every ingest creates a NEW workflow (dedup + merge are
deferred); the catalog schema already carries `status` and `pending_merges`
so N3 can extend it without migration. This CLI is the stable contract the
Hermes skill (N2) and the web UI (N4) build on.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

EMPTY_CATALOG = {"version": 1, "workflows": [], "pending_merges": []}


def kb_dir() -> Path:
    return Path(os.environ.get("KB_DIR", "/sandbox/kb"))


def log(msg: str) -> None:
    print(f"kb: {msg}", file=sys.stderr)


def emit(obj: dict) -> None:
    print(json.dumps(obj, indent=1))


# --- catalog ----------------------------------------------------------------

def load_catalog(root: Path) -> dict:
    path = root / "catalog.json"
    if not path.is_file():
        return json.loads(json.dumps(EMPTY_CATALOG))
    try:
        with open(path) as f:
            return json.load(f)
    except json.JSONDecodeError:
        aside = root / f"catalog.json.corrupt.{int(time.time())}"
        path.rename(aside)
        log(f"WARNING corrupt catalog moved to {aside} — reinitializing "
            f"(workflow dirs on disk are untouched)")
        return json.loads(json.dumps(EMPTY_CATALOG))


def save_catalog(root: Path, catalog: dict) -> None:
    root.mkdir(parents=True, exist_ok=True)
    tmp = root / "catalog.json.tmp"
    with open(tmp, "w") as f:
        json.dump(catalog, f, indent=1)
        f.write("\n")
    os.replace(tmp, root / "catalog.json")


def find_workflow(catalog: dict, workflow_id: str):
    for wf in catalog["workflows"]:
        if wf["id"] == workflow_id:
            return wf
    return None


# --- ingest -----------------------------------------------------------------

def slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:40] or "workflow"


def workflow_id_for(title: str, dominant: str, epoch: int) -> str:
    digest = hashlib.sha1(f"{dominant}|{epoch}".encode()).hexdigest()[:6]
    return f"{slug(title)}-{digest}"


def epoch_of(run_dir: Path) -> int:
    tail = run_dir.name.rsplit("_", 1)[-1]
    return int(tail) if tail.isdigit() else int(time.time())


def copy_if_exists(src: Path, dst: Path) -> bool:
    if src.is_file():
        shutil.copy2(src, dst)
        return True
    return False


def cmd_ingest(args) -> int:
    run_dir = Path(args.run_dir)
    if not run_dir.is_dir():
        emit({"error": f"run dir not found: {run_dir}"})
        return 3

    root = kb_dir()
    catalog = load_catalog(root)

    # Idempotency: the run-dir name (<safe-name>_<epoch>) identifies a run.
    for wf in catalog["workflows"]:
        for run in wf["runs"]:
            if run.get("source_run") == run_dir.name:
                log(f"run {run_dir.name} already in workflow {wf['id']}")
                emit({"result": "already_ingested", "workflow_id": wf["id"],
                      "epoch": run["epoch"]})
                return 0

    epoch = epoch_of(run_dir)
    title = args.name or run_dir.name.rsplit("_", 1)[0].replace("-", " ")

    chain = {}
    chain_path = run_dir / "context_chain.json"
    if chain_path.is_file():
        try:
            with open(chain_path) as f:
                chain = json.load(f)
        except json.JSONDecodeError:
            log(f"WARNING unreadable {chain_path} — ingesting without context")
    dominant = chain.get("dominant", "")
    if not dominant:
        log("no dominant context — ingesting as new workflow without one")

    wf_id = workflow_id_for(title, dominant, epoch)
    wf_dir = root / wf_id
    dest = wf_dir / "runs" / str(epoch)
    dest.mkdir(parents=True, exist_ok=True)
    (wf_dir / "versions").mkdir(exist_ok=True)

    # Artifacts — copies only; the source run dir must survive ingest.
    steps_n = 0
    if copy_if_exists(run_dir / "steps.jsonl", dest / "steps.jsonl"):
        with open(run_dir / "steps.jsonl") as f:
            steps_n = sum(1 for line in f if line.strip())
    copy_if_exists(chain_path, dest / "context_chain.json")
    has_transcript = copy_if_exists(run_dir / "transcript.jsonl",
                                    dest / "transcript.jsonl")
    has_runbook = copy_if_exists(run_dir / "runbook.md", dest / "runbook.md")
    if has_runbook:
        shutil.copy2(run_dir / "runbook.md", wf_dir / "runbook.md")  # canonical
    copy_if_exists(run_dir / "work" / "audio.wav", dest / "audio.wav")
    frames_src = run_dir / "work" / "frames"
    if frames_src.is_dir():
        shutil.copytree(frames_src, dest / "frames", dirs_exist_ok=True)

    video = Path(args.video)
    if video.is_file():
        shutil.copy2(video, dest / "recording.mov")
    else:
        log(f"WARNING source video not found: {video} — "
            f"ingesting without recording.mov")

    catalog["workflows"].append({
        "id": wf_id,
        "title": title,
        "dominant_context": dominant,
        "created": epoch,
        "updated": epoch,
        "status": "active",
        "runs": [{
            "epoch": epoch,
            "source_run": run_dir.name,
            "source_video": str(video),
            "steps": steps_n,
            "has_runbook": has_runbook,
            "has_transcript": has_transcript,
        }],
    })
    save_catalog(root, catalog)
    log(f"ingested {run_dir.name} -> {wf_dir}")
    emit({"result": "new", "workflow_id": wf_id, "epoch": epoch})
    return 0


# --- read commands ----------------------------------------------------------

def cmd_list(args) -> int:
    catalog = load_catalog(kb_dir())
    workflows = catalog["workflows"]
    if args.status:
        workflows = [w for w in workflows if w["status"] == args.status]
    emit({"workflows": workflows})
    return 0


def cmd_show(args) -> int:
    root = kb_dir()
    wf = find_workflow(load_catalog(root), args.workflow_id)
    if wf is None:
        emit({"error": f"workflow not found: {args.workflow_id}"})
        return 3
    runbook = None
    path = root / wf["id"] / "runbook.md"
    if path.is_file():
        runbook = path.read_text()
    emit({**wf, "runbook": runbook})
    return 0


# --- entrypoint ---------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(prog="kb.py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("ingest", help="register a pipeline run in the KB")
    p.add_argument("run_dir")
    p.add_argument("video")
    p.add_argument("--name", help="workflow title (default: from run dir name)")
    p.set_defaults(func=cmd_ingest)

    p = sub.add_parser("list", help="list workflows")
    p.add_argument("--status", help="filter by status")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("show", help="one workflow + its canonical runbook")
    p.add_argument("workflow_id")
    p.set_defaults(func=cmd_show)

    args = parser.parse_args()
    try:
        return args.func(args)
    except OSError as e:
        emit({"error": f"io: {e}"})
        return 5


if __name__ == "__main__":
    sys.exit(main())
