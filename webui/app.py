"""N4 Web UI — FastAPI REST + static frontend for the runbook knowledge base.

Run:  cd webui && python3 -m uvicorn app:app --host 127.0.0.1 --port 8080
Env:  KB_DIR   default /sandbox/kb (local: ../kb-out or wherever your KB lives)
"""
import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

# --- bootstrap: locate pipeline/kb.py for imports ---
HERE = Path(__file__).resolve().parent
for candidate in [HERE.parent / "pipeline",          # local dev
                  Path("/sandbox/pipeline/pipeline")]: # in-sandbox
    if (candidate / "kb.py").is_file():
        sys.path.insert(0, str(candidate))
        break
import kb  # noqa: E402

KB_CLI = None
for candidate in [HERE.parent / "pipeline" / "kb.py",
                  Path("/sandbox/pipeline/pipeline/kb.py")]:
    if candidate.is_file():
        KB_CLI = str(candidate)
        break

app = FastAPI(title="ai-runbooks", version="0.1.0")


def root() -> Path:
    return kb.kb_dir()


# --- catalog ----------------------------------------------------------------

@app.get("/api/runbooks")
def list_runbooks(status: str = None):
    catalog = kb.load_catalog(root())
    workflows = catalog["workflows"]
    if status:
        workflows = [w for w in workflows if w["status"] == status]
    return {"workflows": workflows}


@app.get("/api/runbooks/{wf_id}")
def get_runbook(wf_id: str):
    r = root()
    wf = kb.find_workflow(kb.load_catalog(r), wf_id)
    if not wf:
        raise HTTPException(404, f"workflow not found: {wf_id}")
    runbook = None
    path = r / wf_id / "runbook.md"
    if path.is_file():
        runbook = path.read_text()
    return {**wf, "runbook": runbook}


@app.put("/api/runbooks/{wf_id}")
async def edit_runbook(wf_id: str, request: Request):
    body = await request.json()
    content = body.get("content", "")
    editor = body.get("editor", "web-ui")
    if not content.strip():
        raise HTTPException(400, "content is empty")

    r = root()
    catalog = kb.load_catalog(r)
    wf = kb.find_workflow(catalog, wf_id)
    if not wf:
        raise HTTPException(404, f"workflow not found: {wf_id}")

    wf_dir = r / wf_id
    canonical = wf_dir / "runbook.md"
    before = canonical.read_text() if canonical.is_file() else ""
    before_hash = kb.sha256_of(canonical)

    (wf_dir / "versions").mkdir(exist_ok=True)
    now = int(time.time())
    if canonical.is_file():
        shutil.copy2(canonical, wf_dir / "versions" / f"runbook_{now}.md")
    with open(canonical, "w") as f:
        f.write(content.rstrip() + "\n")
    after_hash = kb.sha256_of(canonical)

    diff = "".join(difflib.unified_diff(
        before.splitlines(keepends=True), content.splitlines(keepends=True),
        fromfile="before/runbook.md", tofile="after/runbook.md"))
    kb.append_edit(wf_dir, {
        "ts": now, "editor": editor, "kind": "manual",
        "decision": "edit", "before_hash": before_hash,
        "after_hash": after_hash, "unified_diff": diff, "section": "*",
    })
    wf["updated"] = now
    kb.save_catalog(r, catalog)
    return {"result": "updated", "workflow_id": wf_id,
            "before_hash": before_hash, "after_hash": after_hash}


# --- runs + media -----------------------------------------------------------

@app.get("/api/runbooks/{wf_id}/runs")
def list_runs(wf_id: str):
    wf = kb.find_workflow(kb.load_catalog(root()), wf_id)
    if not wf:
        raise HTTPException(404, f"workflow not found: {wf_id}")
    return {"runs": wf["runs"]}


@app.get("/api/runbooks/{wf_id}/runs/{epoch}/steps")
def get_steps(wf_id: str, epoch: int):
    run_dir = root() / wf_id / "runs" / str(epoch)
    if not run_dir.is_dir():
        raise HTTPException(404, "run not found")
    steps, transcript = [], []
    sp = run_dir / "steps.jsonl"
    if sp.is_file():
        steps = [json.loads(l) for l in sp.read_text().splitlines() if l.strip()]
    tp = run_dir / "transcript.jsonl"
    if tp.is_file():
        transcript = [json.loads(l) for l in tp.read_text().splitlines() if l.strip()]
    return {"steps": steps, "transcript": transcript}


ALLOWED_MEDIA = re.compile(r"^(recording\.mov|audio\.wav|frames/[^/]+\.png)$")

@app.get("/api/runbooks/{wf_id}/runs/{epoch}/media/{name:path}")
def get_media(wf_id: str, epoch: int, name: str):
    if not ALLOWED_MEDIA.match(name) or ".." in name:
        raise HTTPException(400, "invalid media path")
    path = root() / wf_id / "runs" / str(epoch) / name
    if not path.is_file():
        raise HTTPException(404, "media not found")
    return FileResponse(path)


# --- edits ------------------------------------------------------------------

@app.get("/api/runbooks/{wf_id}/edits")
def get_edits(wf_id: str):
    wf = kb.find_workflow(kb.load_catalog(root()), wf_id)
    if not wf:
        raise HTTPException(404, f"workflow not found: {wf_id}")
    path = root() / wf_id / "edits.jsonl"
    if not path.is_file():
        return {"edits": []}
    edits = [json.loads(l) for l in path.read_text().splitlines() if l.strip()]
    return {"edits": edits}


# --- merges -----------------------------------------------------------------

@app.get("/api/merges")
def list_merges():
    return {"pending_merges": kb.load_catalog(root())["pending_merges"]}


@app.get("/api/merges/{merge_id}")
def get_merge(merge_id: str):
    r = root()
    catalog = kb.load_catalog(r)
    entry = kb.find_merge(catalog, merge_id)
    if not entry:
        raise HTTPException(404, f"merge not found: {merge_id}")
    wf_dir = r / entry["workflow_id"]
    canonical = wf_dir / "runbook.md"
    current = canonical.read_text() if canonical.is_file() else ""
    merged = None
    merged_path = wf_dir / "pending" / merge_id / "merged_runbook.md"
    if entry["draft"] and merged_path.is_file():
        merged = merged_path.read_text()
    diff = ""
    if merged is not None:
        diff = "".join(difflib.unified_diff(
            current.splitlines(keepends=True),
            merged.splitlines(keepends=True),
            fromfile="current/runbook.md", tofile="merged/runbook.md"))
    return {**entry, "current_runbook": current, "merged_runbook": merged,
            "unified_diff": diff}


def _run_kb_cli(*args) -> JSONResponse:
    if not KB_CLI:
        raise HTTPException(500, "kb.py not found")
    proc = subprocess.run(
        [sys.executable, KB_CLI, *args],
        capture_output=True, text=True,
        env={**os.environ, "KB_DIR": str(root())})
    code_map = {0: 200, 3: 404, 4: 409}
    status = code_map.get(proc.returncode, 500)
    try:
        body = json.loads(proc.stdout)
    except json.JSONDecodeError:
        body = {"error": proc.stderr.strip() or "kb.py failed"}
    return JSONResponse(body, status_code=status)


@app.post("/api/merges/{merge_id}/accept")
async def accept_merge(merge_id: str, request: Request):
    body = await request.json() if await request.body() else {}
    editor = body.get("editor", "web-ui")
    return _run_kb_cli("accept-merge", merge_id, "--editor", editor)


@app.post("/api/merges/{merge_id}/reject")
async def reject_merge(merge_id: str, request: Request):
    body = await request.json() if await request.body() else {}
    editor = body.get("editor", "web-ui")
    return _run_kb_cli("reject-merge", merge_id, "--editor", editor)


# --- execute (deferred) ----------------------------------------------------

@app.post("/api/runbooks/{wf_id}/execute")
def execute_runbook(wf_id: str):
    raise HTTPException(501,
        "Execution via chat (runbook-runner skill) — REST proxy pending N2 wiring")


# --- static frontend --------------------------------------------------------

app.mount("/", StaticFiles(directory=str(HERE / "static"), html=True),
          name="static")
