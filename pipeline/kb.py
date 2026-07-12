#!/usr/bin/env python3
"""Stateful runbook knowledge base (NEXT_STEPS N1 + N3).

Usage:  kb.py ingest <run_dir> <video> [--name NAME]
        kb.py list [--status STATUS]
        kb.py show <workflow_id>
        kb.py merges
        kb.py show-merge <merge_id>
        kb.py accept-merge <merge_id> [--editor EDITOR]
        kb.py reject-merge <merge_id> [--editor EDITOR]

Env:    KB_DIR   knowledge-base root (default /sandbox/kb)
        SYNTH_URL/SYNTH_TOKEN/SYNTH_MODEL   LLM for match + merge (see llm.py)

Every command prints exactly one JSON object to stdout; logs go to stderr.
Exit codes: 0 ok, 2 usage, 3 not found, 4 invalid state, 5 IO/catalog error.

Layout:
  $KB_DIR/catalog.json
  $KB_DIR/<workflow-id>/
    runbook.md              canonical version
    versions/               prior canonicals (merges / N5 edits)
    runs/<epoch>/           steps.jsonl, context_chain.json, transcript.jsonl,
                            runbook.md, recording.mov, audio.wav, frames/
    pending/<merge_id>/     merged_runbook.md + run/ (an unconfirmed run)
    edits.jsonl             merge/edit decision log (N3/N5)

Dedup (N3): on ingest, candidates are pre-filtered by dominant_context, then
an LLM judges same-workflow-ness and drafts a merged runbook. The draft goes
to a pending-merge queue — nothing becomes canonical without an explicit
accept (propose + user confirms, via the Hermes chat skills). Every LLM
failure degrades safely: unparseable/failed compare = no match (new
workflow); failed draft = queued with draft:false (reject-only).
This CLI is the stable contract the Hermes skills (N2) and web UI (N4) use.
"""
import argparse
import difflib
import hashlib
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

import llm

EMPTY_CATALOG = {"version": 1, "workflows": [], "pending_merges": []}

COMPARE_SYSTEM = """You judge whether two screen-recorded workflow runs are \
the SAME workflow — same goal and essentially the same procedure — not merely \
runs in similar apps.
Reply with EXACTLY one JSON object and nothing else:
{"match": true|false, "confidence": <0.0-1.0>, "reason": "<one short sentence>"}"""

MERGE_SYSTEM = """You merge two runbooks that describe the SAME workflow into \
one canonical runbook — a union of their knowledge.

Rules:
- Include every real step either version observed; fill gaps one run missed.
- Where both describe the same step, keep the clearer phrasing.
- Where they genuinely diverge, keep one canonical step and add a
  "> Alternative:" note under it describing the other observed path.
- Preserve the structure exactly: "# Runbook: <name> — <context>",
  "## Preconditions", "## Steps" (numbered, imperative), "## Outcome".

Output ONLY the merged runbook markdown, nothing else."""


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


def find_merge(catalog: dict, merge_id: str):
    for entry in catalog["pending_merges"]:
        if entry["merge_id"] == merge_id:
            return entry
    return None


def refresh_status(catalog: dict, wf: dict) -> None:
    pending = any(pm["workflow_id"] == wf["id"]
                  for pm in catalog["pending_merges"])
    wf["status"] = "pending_merge" if pending else "active"


def append_edit(wf_dir: Path, record: dict) -> None:
    with open(wf_dir / "edits.jsonl", "a") as f:
        f.write(json.dumps(record) + "\n")


def sha256_of(path: Path) -> str:
    if not path.is_file():
        return ""
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


# --- ingest helpers ----------------------------------------------------------

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


def copy_run_artifacts(run_dir: Path, video: Path, dest: Path,
                       epoch: int) -> dict:
    """Copy a pipeline run's artifacts into `dest` (copies only — the source
    run dir must survive ingest). Returns the catalog run entry."""
    dest.mkdir(parents=True, exist_ok=True)
    steps_n = 0
    if copy_if_exists(run_dir / "steps.jsonl", dest / "steps.jsonl"):
        with open(run_dir / "steps.jsonl") as f:
            steps_n = sum(1 for line in f if line.strip())
    copy_if_exists(run_dir / "context_chain.json",
                   dest / "context_chain.json")
    has_transcript = copy_if_exists(run_dir / "transcript.jsonl",
                                    dest / "transcript.jsonl")
    has_runbook = copy_if_exists(run_dir / "runbook.md", dest / "runbook.md")
    copy_if_exists(run_dir / "work" / "audio.wav", dest / "audio.wav")
    frames_src = run_dir / "work" / "frames"
    if frames_src.is_dir():
        shutil.copytree(frames_src, dest / "frames", dirs_exist_ok=True)

    if video.is_file():
        shutil.copy2(video, dest / "recording.mov")
    else:
        log(f"WARNING source video not found: {video} — "
            f"ingesting without recording.mov")

    return {
        "epoch": epoch,
        "source_run": run_dir.name,
        "source_video": str(video),
        "steps": steps_n,
        "has_runbook": has_runbook,
        "has_transcript": has_transcript,
    }


# --- dedup matching (N3) -----------------------------------------------------

def norm(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower()).strip()


def app_segment(dominant: str) -> str:
    return dominant.split(" — ")[0]


def find_candidates(catalog: dict, dominant: str) -> list:
    nd, napp = norm(dominant), norm(app_segment(dominant))
    out = []
    for wf in catalog["workflows"]:
        wd = wf.get("dominant_context", "")
        if not wd:
            continue
        if norm(wd) == nd or norm(app_segment(wd)) == napp:
            out.append(wf)
    return out[:3]


def step_digest(steps_path: Path, limit: int = 50) -> str:
    if not steps_path.is_file():
        return "(no step data)"
    lines = []
    with open(steps_path) as f:
        for i, line in enumerate(f, 1):
            if not line.strip():
                continue
            if len(lines) >= limit:
                break
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            lines.append(f"{i}. {rec.get('action', '?')} — "
                         f"{rec.get('target', '')}")
    return "\n".join(lines) or "(no step data)"


def latest_run_steps(root: Path, wf: dict) -> Path:
    if wf["runs"]:
        epoch = wf["runs"][-1]["epoch"]
        return root / wf["id"] / "runs" / str(epoch) / "steps.jsonl"
    return root / wf["id"] / "runs" / "none" / "steps.jsonl"


def llm_same_workflow(title_a, dom_a, digest_a, title_b, dom_b, digest_b):
    """LLM judgment: are these the same workflow? None on any failure —
    callers must treat that as no-match (never blocks, never wrong-merges)."""
    user = (f"Run A: {title_a}\nContext: {dom_a}\nSteps:\n{digest_a}\n\n"
            f"Run B: {title_b}\nContext: {dom_b}\nSteps:\n{digest_b}")
    try:
        reply = llm.chat(COMPARE_SYSTEM, user, timeout=300)
    except Exception as e:  # degrade to no-match on any LLM trouble
        log(f"WARNING compare LLM failed ({e}) — treating as no-match")
        return None
    parsed = llm.parse_json_loose(reply)
    if not parsed or "match" not in parsed:
        log("WARNING compare reply unparseable — treating as no-match")
        return None
    return parsed


# --- ingest ------------------------------------------------------------------

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
    for pm in catalog["pending_merges"]:
        if pm["run"].get("source_run") == run_dir.name:
            log(f"run {run_dir.name} already pending as {pm['merge_id']}")
            emit({"result": "merge_pending",
                  "workflow_id": pm["workflow_id"],
                  "merge_id": pm["merge_id"]})
            return 0

    epoch = epoch_of(run_dir)
    title = args.name or run_dir.name.rsplit("_", 1)[0].replace("-", " ")
    video = Path(args.video)

    chain = {}
    chain_path = run_dir / "context_chain.json"
    if chain_path.is_file():
        try:
            with open(chain_path) as f:
                chain = json.load(f)
        except json.JSONDecodeError:
            log(f"WARNING unreadable {chain_path} — ingesting without context")
    dominant = chain.get("dominant", "")

    # --- N3: candidate match (pre-filter, then LLM judgment) -----------------
    match_wf, verdict = None, None
    if dominant:
        incoming_digest = step_digest(run_dir / "steps.jsonl")
        for cand in find_candidates(catalog, dominant):
            cand_digest = step_digest(latest_run_steps(root, cand))
            v = llm_same_workflow(title, dominant, incoming_digest,
                                  cand["title"], cand["dominant_context"],
                                  cand_digest)
            if v and v.get("match"):
                match_wf, verdict = cand, v
                log(f"matched workflow {cand['id']} "
                    f"(confidence {v.get('confidence', '?')}): "
                    f"{v.get('reason', '')}")
                break
    else:
        log("no dominant context — skipping dedup match")

    # --- matched, but incoming run has no runbook: attach run, no merge ------
    if match_wf and not (run_dir / "runbook.md").is_file():
        wf_dir = root / match_wf["id"]
        entry = copy_run_artifacts(run_dir, video,
                                   wf_dir / "runs" / str(epoch), epoch)
        match_wf["runs"].append(entry)
        match_wf["updated"] = int(time.time())
        save_catalog(root, catalog)
        log(f"run-only ingest into {match_wf['id']} (no incoming runbook)")
        emit({"result": "run_added", "workflow_id": match_wf["id"],
              "epoch": epoch})
        return 0

    # --- matched with runbook: queue a merge proposal -------------------------
    if match_wf:
        merge_id = f"m_{epoch}_{match_wf['id']}"
        wf_dir = root / match_wf["id"]
        pending_dir = wf_dir / "pending" / merge_id
        entry = copy_run_artifacts(run_dir, video, pending_dir / "run", epoch)

        canonical = wf_dir / "runbook.md"
        draft_ok = False
        if canonical.is_file():
            current = canonical.read_text()
            incoming = (run_dir / "runbook.md").read_text()
            user = (f"Current canonical runbook:\n\n{current}\n\n---\n\n"
                    f"New run's runbook:\n\n{incoming}\n\n---\n\n"
                    f"New run's observed steps (evidence):\n"
                    f"{step_digest(run_dir / 'steps.jsonl')}")
            try:
                merged = llm.chat(MERGE_SYSTEM, user)
                with open(pending_dir / "merged_runbook.md", "w") as f:
                    f.write(merged.strip() + "\n")
                draft_ok = True
            except Exception as e:
                log(f"WARNING merge draft failed ({e}) — queued without draft")
        else:
            log("WARNING matched workflow has no canonical runbook — "
                "queued without draft")

        catalog["pending_merges"].append({
            "merge_id": merge_id,
            "workflow_id": match_wf["id"],
            "incoming_epoch": epoch,
            "draft": draft_ok,
            "base_hash": sha256_of(canonical),
            "match": {"confidence": verdict.get("confidence"),
                      "reason": verdict.get("reason", "")},
            "created": int(time.time()),
            "run": entry,
        })
        refresh_status(catalog, match_wf)
        save_catalog(root, catalog)
        log(f"merge proposal {merge_id} queued for {match_wf['id']}")
        emit({"result": "merge_pending", "workflow_id": match_wf["id"],
              "merge_id": merge_id, "draft": draft_ok,
              "match": {"confidence": verdict.get("confidence"),
                        "reason": verdict.get("reason", "")}})
        return 0

    # --- no match: new workflow (N1 behavior) ---------------------------------
    if not dominant:
        log("no dominant context — ingesting as new workflow without one")
    wf_id = workflow_id_for(title, dominant, epoch)
    wf_dir = root / wf_id
    entry = copy_run_artifacts(run_dir, video,
                               wf_dir / "runs" / str(epoch), epoch)
    (wf_dir / "versions").mkdir(exist_ok=True)
    if entry["has_runbook"]:
        shutil.copy2(run_dir / "runbook.md", wf_dir / "runbook.md")  # canonical

    catalog["workflows"].append({
        "id": wf_id,
        "title": title,
        "dominant_context": dominant,
        "created": epoch,
        "updated": epoch,
        "status": "active",
        "runs": [entry],
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


# --- merge queue (N3) ---------------------------------------------------------

def cmd_merges(args) -> int:
    emit({"pending_merges": load_catalog(kb_dir())["pending_merges"]})
    return 0


def cmd_show_merge(args) -> int:
    root = kb_dir()
    catalog = load_catalog(root)
    entry = find_merge(catalog, args.merge_id)
    if entry is None:
        emit({"error": f"merge not found: {args.merge_id}"})
        return 3
    wf_dir = root / entry["workflow_id"]
    canonical = wf_dir / "runbook.md"
    current = canonical.read_text() if canonical.is_file() else ""
    merged = None
    merged_path = wf_dir / "pending" / entry["merge_id"] / "merged_runbook.md"
    if entry["draft"] and merged_path.is_file():
        merged = merged_path.read_text()
    diff = ""
    if merged is not None:
        diff = "".join(difflib.unified_diff(
            current.splitlines(keepends=True),
            merged.splitlines(keepends=True),
            fromfile="current/runbook.md", tofile="merged/runbook.md"))
    emit({**entry, "current_runbook": current, "merged_runbook": merged,
          "unified_diff": diff})
    return 0


def cmd_accept_merge(args) -> int:
    root = kb_dir()
    catalog = load_catalog(root)
    entry = find_merge(catalog, args.merge_id)
    if entry is None:
        emit({"error": f"merge not found: {args.merge_id}"})
        return 3
    wf = find_workflow(catalog, entry["workflow_id"])
    if wf is None:
        emit({"error": f"workflow gone: {entry['workflow_id']}"})
        return 3
    wf_dir = root / wf["id"]
    pending_dir = wf_dir / "pending" / entry["merge_id"]
    merged_path = pending_dir / "merged_runbook.md"
    if not entry["draft"] or not merged_path.is_file():
        emit({"error": f"merge {entry['merge_id']} has no draft — "
                       f"reject it (keep separate) or re-ingest"})
        return 4
    run_dest = wf_dir / "runs" / str(entry["incoming_epoch"])
    if run_dest.exists():
        emit({"error": f"run slot already exists: {run_dest}"})
        return 4

    canonical = wf_dir / "runbook.md"
    before_hash = sha256_of(canonical)
    stale_base = bool(entry["base_hash"]) and entry["base_hash"] != before_hash
    current = canonical.read_text() if canonical.is_file() else ""
    merged = merged_path.read_text()
    diff = "".join(difflib.unified_diff(
        current.splitlines(keepends=True), merged.splitlines(keepends=True),
        fromfile="current/runbook.md", tofile="merged/runbook.md"))

    now = int(time.time())
    (wf_dir / "versions").mkdir(exist_ok=True)
    if canonical.is_file():
        shutil.copy2(canonical, wf_dir / "versions" / f"runbook_{now}.md")
    shutil.move(str(merged_path), str(canonical))
    shutil.move(str(pending_dir / "run"), str(run_dest))
    shutil.rmtree(pending_dir, ignore_errors=True)

    wf["runs"].append(entry["run"])
    wf["runs"].sort(key=lambda r: r["epoch"])
    wf["updated"] = now
    append_edit(wf_dir, {
        "ts": now, "editor": args.editor, "kind": "merge",
        "decision": "accept", "merge_id": entry["merge_id"],
        "before_hash": before_hash, "after_hash": sha256_of(canonical),
        "unified_diff": diff, "section": "*",
    })
    catalog["pending_merges"].remove(entry)
    refresh_status(catalog, wf)
    save_catalog(root, catalog)
    log(f"merge {entry['merge_id']} accepted -> canonical updated, "
        f"{len(wf['runs'])} runs")
    out = {"result": "merged", "workflow_id": wf["id"],
           "merge_id": entry["merge_id"], "runs": len(wf["runs"])}
    if stale_base:
        out["stale_base"] = True
    emit(out)
    return 0


def cmd_reject_merge(args) -> int:
    root = kb_dir()
    catalog = load_catalog(root)
    entry = find_merge(catalog, args.merge_id)
    if entry is None:
        emit({"error": f"merge not found: {args.merge_id}"})
        return 3
    wf = find_workflow(catalog, entry["workflow_id"])
    if wf is None:
        emit({"error": f"workflow gone: {entry['workflow_id']}"})
        return 3
    wf_dir = root / wf["id"]
    pending_dir = wf_dir / "pending" / entry["merge_id"]
    run_src = pending_dir / "run"

    # "Keep separate": the pending run becomes its own workflow.
    run_entry = entry["run"]
    epoch = entry["incoming_epoch"]
    dominant = ""
    chain_path = run_src / "context_chain.json"
    if chain_path.is_file():
        try:
            with open(chain_path) as f:
                dominant = json.load(f).get("dominant", "")
        except json.JSONDecodeError:
            pass
    new_id = workflow_id_for(wf["title"], dominant or wf["dominant_context"],
                             epoch)
    new_dir = root / new_id
    (new_dir / "runs").mkdir(parents=True, exist_ok=True)
    (new_dir / "versions").mkdir(exist_ok=True)
    shutil.move(str(run_src), str(new_dir / "runs" / str(epoch)))
    if (new_dir / "runs" / str(epoch) / "runbook.md").is_file():
        shutil.copy2(new_dir / "runs" / str(epoch) / "runbook.md",
                     new_dir / "runbook.md")
    shutil.rmtree(pending_dir, ignore_errors=True)

    now = int(time.time())
    catalog["workflows"].append({
        "id": new_id,
        "title": wf["title"],
        "dominant_context": dominant or wf["dominant_context"],
        "created": epoch,
        "updated": now,
        "status": "active",
        "runs": [run_entry],
    })
    append_edit(wf_dir, {
        "ts": now, "editor": args.editor, "kind": "merge",
        "decision": "reject", "merge_id": entry["merge_id"],
        "separated_to": new_id,
    })
    catalog["pending_merges"].remove(entry)
    refresh_status(catalog, wf)
    save_catalog(root, catalog)
    log(f"merge {entry['merge_id']} rejected -> kept separate as {new_id}")
    emit({"result": "kept_separate", "workflow_id": new_id,
          "merge_id": entry["merge_id"], "original_workflow": wf["id"]})
    return 0


# --- execution logging ---------------------------------------------------------

def cmd_log_execution(args) -> int:
    root = kb_dir()
    catalog = load_catalog(root)
    wf = find_workflow(catalog, args.workflow_id)
    if not wf:
        emit({"error": f"workflow not found: {args.workflow_id}"})
        return 3
    data = sys.stdin.read().strip()
    if not data:
        emit({"error": "no JSON on stdin"})
        return 2
    try:
        record = json.loads(data)
    except json.JSONDecodeError:
        emit({"error": "invalid JSON on stdin"})
        return 2
    record.setdefault("ts", int(time.time()))
    wf_dir = root / wf["id"]
    with open(wf_dir / "executions.jsonl", "a") as f:
        f.write(json.dumps(record) + "\n")
    wf["updated"] = int(time.time())
    save_catalog(root, catalog)
    log(f"execution logged for {wf['id']}")
    emit({"result": "logged", "workflow_id": wf["id"]})
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

    p = sub.add_parser("merges", help="list pending merge proposals")
    p.set_defaults(func=cmd_merges)

    p = sub.add_parser("show-merge", help="one proposal + runbooks + diff")
    p.add_argument("merge_id")
    p.set_defaults(func=cmd_show_merge)

    p = sub.add_parser("accept-merge",
                       help="merged draft becomes canonical (old -> versions/)")
    p.add_argument("merge_id")
    p.add_argument("--editor", default="hermes-chat")
    p.set_defaults(func=cmd_accept_merge)

    p = sub.add_parser("reject-merge",
                       help="keep separate: pending run becomes a new workflow")
    p.add_argument("merge_id")
    p.add_argument("--editor", default="hermes-chat")
    p.set_defaults(func=cmd_reject_merge)

    p = sub.add_parser("log-execution",
                       help="append an execution record (JSON from stdin)")
    p.add_argument("workflow_id")
    p.set_defaults(func=cmd_log_execution)

    args = parser.parse_args()
    llm.load_env()   # SYNTH_* for match/merge when invoked standalone
    try:
        return args.func(args)
    except OSError as e:
        emit({"error": f"io: {e}"})
        return 5


if __name__ == "__main__":
    sys.exit(main())
