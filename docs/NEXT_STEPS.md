# Next Steps — v2: Stateful KB, Agentic Execution, Web UI

> Decisions locked with owner (2026-07-11): replay via **H Sessions API (cloud
> browser)** · merge policy **propose + user confirms** · UI/API as **FastAPI
> inside the sandbox** (serves both REST and static UI files).
>
> Prerequisite state: v1 pipeline works end-to-end locally (video → runbook with
> per-step context + context chain); sandbox onboarded, Hermes API pending
> (HANDOFF task queue).
>
> **Update (2026-07-11):** owner flipped the order — **N2 ships first**, then N1.
> Detailed plan: [N2_EXECUTION_PLAN.md](N2_EXECUTION_PLAN.md). EU endpoint
> (`agp.eu.hcompany.ai`) is **locked** for the PoC (won't go to prod as-is);
> region is not a decision point anymore.

## N1 — Knowledge base in the sandbox (stateful) ✅ implemented

> Shipped (2026-07-11): `pipeline/kb.py` (ingest/list/show CLI, JSON stdout —
> the contract N2/N4 call) + ingest stage in `run.py` (`--skip-ingest` to opt
> out; ingest failure never fails a run). `KB_DIR` env, default `/sandbox/kb`.
> Interim behavior until N3: **every ingest creates a new workflow** — dedup +
> merge are deferred because merge confirmation happens via Hermes chat (N2).
> Catalog schema is N3-ready (`status`, empty `pending_merges`). Recording is
> **copied** into the KB, never moved. See RECORDING_CONTRACT.md §9.

The sandbox stops being a compute box and becomes the system of record.

- Layout: `/sandbox/kb/` — `catalog.json` (the index) + one directory per
  **workflow** (not per run):
  ```
  /sandbox/kb/
    catalog.json                    # [{id, title, dominant_context, created,
                                    #   updated, runs: [...], status}]
    <workflow-id>/
      runbook.md                    # current canonical version
      versions/                     # prior versions (see merge + edits)
      runs/<epoch>/                 # each contributing run: steps.jsonl,
                                    #   context_chain.json, transcript.jsonl,
                                    #   recording.mov, audio.wav, frames/
      edits.jsonl                   # manual-edit log (N5)
  ```
- `run.py` gains a final "ingest" stage: move run artifacts into the KB,
  register in `catalog.json`. Workflow identity key = `dominant_context`
  (from the context-chain work) + agent judgment (N3).
- Persistence: already solved — sandbox state volume + `nemohermes snapshot` /
  backup-restore. `catalog.json` is the thing the app/UI read; treat it as the
  API contract's source of truth.
- SQLite upgrade path when catalog.json outgrows itself; not for the hackathon.

## N2 — Agentic execution (the text box runs runbooks)

The app's chat bar already talks to Hermes (RECORDING_CONTRACT §8). Execution
adds a second skill and H's phase-2 wiring:

- **Egress + MCP:** add `agp.eu.hcompany.ai` policy (template exists in H's
  demo: `policies/hai-agent-platform.yaml`), register H's hosted MCP server in
  `/sandbox/.hermes/config.yaml`, and bake the streamable-HTTP MCP client into
  our image (H's demo Dockerfile shows the exact fix). Agent gains
  `run_agent`, `wait_for_session`, `send_message`, etc.
- **Skill `runbook-runner`:** on "run the <X> runbook" → search `catalog.json`
  (title + dominant_context match; ask user to disambiguate if >1 candidate) →
  translate runbook.md steps into a Sessions API task → launch `h/web-surfer-flash`
  (or custom agent) → stream progress back to the chat bar → report outcome +
  Agent View replay link.
- **User input mid-run:** two layers — *before* launch, the agent asks in chat
  for any `{{parameters}}` the runbook declares (see F1 below); *during* the
  run, Sessions API `send_message` / observe-and-steer relays agent questions
  to the chat bar.
- **Scope honesty:** cloud browser = web workflows only. Runbooks whose steps
  include local apps get those steps flagged "manual" in the run plan and the
  agent says so up front. (HoloDesktop CLI local replay = future option.)

### ✅ Implemented — 2026-07-11 (E1–E4; end-to-end run verified)

Full record in [N2_EXECUTION_PLAN.md](N2_EXECUTION_PLAN.md); the plan's original
E1 approach was superseded by better tooling. What actually shipped:

- **Egress + MCP — via native managed MCP, not hand-written config.** NemoClaw
  v0.0.79 ships `nemohermes <sandbox> mcp add <server> --url <url> --env KEY`.
  One command created the OpenShell credential provider, generated the
  `protocol: mcp` egress policy for `agp.eu.hcompany.ai`, and wrote
  `/sandbox/.hermes/config.yaml` — with the `hk-` key held in OpenShell's
  provider store and present in the sandbox only as an
  `openshell:resolve:env:HAI_AGENT_MCP_TOKEN` placeholder (never plaintext, as
  the original plan would have). **No custom image needed** — the default full
  Hermes image already carries HTTP-MCP support (`mcp add` fails closed with
  rebuild guidance otherwise). `hermes mcp test` discovered all six tools
  (`run_agent`, `wait_for_session`, `list_agents`, `send_message`,
  `cancel_session`, `share_session`); blocked-host egress negative test recorded.
- **Skill [`runbook-runner`](../sandbox/skills/runbook-runner/SKILL.md):** find →
  plan (web vs manual/local classification) → F1-lite params → confirm gate
  (with idempotence warning; `run_agent`'s native `idempotency_key` backs it) →
  launch `h/web-surfer-flash` → bounded-poll stream (`send_message` relay,
  `cancel_session` on stop) → **evidence-based** per-step report + replay link.
  Runbook lookup is isolated in the "find" step as the N1 `catalog.json` seam.
- **Report source — evidence-based, not self-reported.** `wait_for_session`
  returns only terminal `{status, answer, done}`, but `share_session` yields a
  public JSON trajectory (`events[]`, `status`, `metrics`). New egress preset
  [`hai-trajectory-read`](../sandbox/policies/hai-trajectory-read.yaml) lets the
  runner fetch it in-sandbox, so completion/duration/step-count come from
  observed evidence and recap-vs-trajectory mismatches are surfaced. This is
  F2's foundation.
- **End-to-end verified.** "Run the … runbook" through the chat API drove the
  4-web-step Google Forms runbook: agent showed the plan, launched the cloud
  browser, hit a Google login wall, and correctly reported step 1 done + 2–4
  **skipped** (not falsely done) — cross-checked against the trajectory
  (`completed`, 3 browser actions, no submission) — with duration and replay
  link. Failure taxonomy label applied: `blocked: login required`.
- **Automated:** all of the above folded into
  [`scripts/provision-sandbox.sh`](../scripts/provision-sandbox.sh) (MCP register +
  trajectory-read policy + skill installs), so a fresh machine reproduces it.
- **Still open:** measure platform quota/cost under load; exercise the mid-run
  question relay (the login-wall run didn't trigger an agent question); a
  synthetic target without a login wall for a clean all-steps-done demo.

## N3 — Ingest dedup + smart merge (propose → confirm) ✅ implemented

> Shipped (2026-07-11): ingest now pre-filters candidates by
> `dominant_context`, LLM-judges same-workflow-ness (`pipeline/llm.py`,
> shared with synthesize), drafts a merged runbook (union of knowledge,
> `> Alternative:` divergence notes), and queues it — `kb.py` gained
> `merges`/`show-merge`/`accept-merge`/`reject-merge`. Confirmation is via
> Hermes chat: `runbook-builder` proposes in the same turn as ingest;
> the new `runbook-merger` skill works the queue later. Reject = keep
> separate (run becomes its own workflow). Decisions logged to `edits.jsonl`
> (N5's shape). LLM failure degrades to N1 behavior (new workflow / draft-less
> queue entry). Also: `runbook-runner`'s lookup seam swapped to
> `catalog.json`, and `run.py --skip-synthesis` now implies `--skip-ingest`
> (the builder skill ingests after writing the runbook).

On every new runbook ingest:

1. Candidate match: same/similar `dominant_context` in catalog, then agent
   compares steps (an LLM judgment call, not string equality).
2. **No match →** save as new workflow, UI toast "New runbook: <title>".
3. **Match →** agent drafts a merged runbook (union of knowledge: fills gaps
   one run missed — e.g. run A caught the Submit click that run B's sampling
   missed; keeps the clearer phrasing; notes divergences as alternatives).
   Draft goes to a **pending-merge queue**; UI shows side-by-side diff
   (current vs merged) with *Accept merge* / *Keep separate*.
4. On accept: current `runbook.md` → `versions/`, merged becomes canonical,
   both runs recorded under `runs/`, catalog `updated` bumped, UI toast
   "Runbook updated: <title> (now backed by N runs)".
5. Accept/reject decisions are logged — they're training signal (pairs with N5).

## N4 — Web UI (FastAPI inside the sandbox)

One FastAPI app in `/sandbox/webui/`, serving REST + static frontend from the
same port (e.g. 8080, forwarded like 8642):

- Endpoints (this IS N6's API, so N6 comes nearly free):
  `GET /api/runbooks` (catalog) · `GET/PUT /api/runbooks/{id}` (read/edit
  runbook.md) · `GET /api/runbooks/{id}/runs` · media
  `GET /api/runs/{id}/recording.mov|audio.wav|frames/*` (range requests for
  video scrubbing) · `GET /api/merges/pending` + `POST /api/merges/{id}/accept|reject`
  · `POST /api/runbooks/{id}/execute` (proxies to N2).
- UI pages: catalog list → runbook detail (rendered md, editable; steps beside
  the recording player with timestamp-linked seeking — `t0` per step makes
  click-step-to-jump-video trivial) → runs tab (all merged source runs, each
  with its video/audio/steps) → pending merges (diff view) → edits tab (N5).
- Image impact: add `fastapi` + `uvicorn` to `sandbox/image/Dockerfile`;
  static frontend built on host, uploaded into `/sandbox/webui/static/`.
- Note: recordings currently stay on the host; N1's ingest moves them into the
  KB so the UI can serve them. Disk in the sandbox becomes a real budget —
  add recording size caps or retention to catalog config.

## N5 — Manual-edit tracking (training data)

- Every UI edit (PUT) appends to the workflow's `edits.jsonl`:
  `{ts, editor, before_hash, after_hash, unified_diff, section}` — plus full
  before/after snapshots in `versions/`.
- Merge accept/reject decisions logged in the same shape (`kind: "merge"`).
- UI: "Edits" tab per runbook + a global training-data view (filter by kind,
  export JSONL). Nothing is auto-cleaned; this corpus is the future
  fine-tuning/eval set ("what did humans fix about our generated runbooks").

## N6 — [low priority] Formal API

Mostly satisfied by N4's FastAPI. Remaining work when it matters: auth
(bearer tokens), stable versioned paths (`/v1/...`), OpenAPI docs (FastAPI
generates these already), and moving the app's recording-trigger from the
Hermes chat call to `POST /api/ingest` for structured status instead of
chat-stream parsing.

---

## Suggested additional features

- **F1 · Parameterization (recommended with N2):** at synthesis time, extract
  variables from runbooks — typed values like emails, IDs, dates become
  `{{parameters}}` with the recorded value as example default. Execution asks
  for them in chat before launch. Turns "replay exactly what I did" into
  "run my workflow with new inputs" — arguably the product's core value.
- **F2 · Replay verification + success tracking:** after each N2 run, agent
  records success/failure per step into the catalog. Repeated failures on a
  step flag the runbook **stale** (UI badge) — likely the target app's UI
  changed; prompt to re-record. Gives the KB a health signal.
- **F3 · Versioning/rollback UI:** `versions/` exists for merges/edits anyway;
  expose a history slider + one-click rollback. Cheap insurance for bad merges.
- **F4 · PHI/PII scrub pass (lana.health future):** optional pipeline stage —
  Holo already OCRs frames; flag detected emails/MRNs/names in steps + blur
  frames before KB storage. The egress allowlist story + this = the compliance
  slide.
- **F5 · Scheduled runs:** Hermes/NemoClaw already support cron + heartbeats —
  "run the eligibility-check runbook every Monday 8am" is config, not code,
  once N2 works.
- **F6 · Export:** runbook.md → .docx/PDF for human SOP distribution
  (compliance teams love paper).

## Suggested order (hackathon-aware)

**Current (owner decision 2026-07-11):** N2 (+F1-lite, see
[N2_EXECUTION_PLAN.md](N2_EXECUTION_PLAN.md)) → N1 → N4 (read-only UI: catalog +
detail + video) → N3 → N5 → F2/F3. N2's egress/MCP plumbing has the most
unknowns, so it goes first; its runbook lookup is built with a one-step seam
that N1's catalog.json replaces.

<details><summary>Original order (superseded)</summary>

N1 → N4 (read-only UI first: catalog + detail + video) → N3 → N2 (+F1) → N5 → F2/F3.
Rationale: N1+read-only N4 make the "knowledge base" demo real in a day;
N3's merge diff is a strong wow moment; N2 depends on phase-2 egress/MCP
plumbing that has the most unknowns, so start it early in parallel if two
people are free, but don't gate the demo on it.

</details>
