---
name: runbook-merger
description: "Review the knowledge base's pending runbook merges: list, show diffs, and accept or reject merge proposals on the user's confirmation."
version: 1.0.0
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [runbook, merge, knowledge-base, dedup]
    related_skills: [runbook-builder, runbook-runner]
---

# Skill: runbook-merger

Review and resolve pending merge proposals in the runbook knowledge base.
Proposals are created at ingest time (see `runbook-builder` step 4) when a new
run matches an existing workflow; nothing becomes canonical without an
explicit user decision — this skill is that decision surface.

## When to use

The user asks about the merge queue or decides a proposal, e.g.
"any pending merges?", "show me the merge for `<workflow>`",
"accept the merge", "keep them separate", "reject `<merge_id>`".

## The CLI (the only way to touch the KB)

`python3 /sandbox/pipeline/pipeline/kb.py …` (if that path doesn't exist, use
`/sandbox/pipeline/kb.py`). Every command prints exactly one JSON object on
stdout; logs are on stderr. Exit codes: 0 ok, 3 not found, 4 invalid state.

| Command | Returns |
|---|---|
| `kb.py merges` | `{"pending_merges": [{merge_id, workflow_id, incoming_epoch, draft, match: {confidence, reason}, created, run}, …]}` |
| `kb.py show-merge <merge_id>` | the entry + `current_runbook`, `merged_runbook`, `unified_diff` |
| `kb.py accept-merge <merge_id>` | `{"result": "merged", "workflow_id", "runs"}` — merged draft becomes canonical; the previous version is preserved under `versions/` |
| `kb.py reject-merge <merge_id>` | `{"result": "kept_separate", "workflow_id": <new>}` — the pending run becomes its own workflow |

## Steps

1. **List:** run `kb.py merges`. Empty → say the queue is clear. Otherwise
   summarize each proposal in one line: workflow, match confidence + reason,
   when it was proposed.
2. **Show (on request or when only one is pending):** `kb.py show-merge
   <merge_id>`. Present a compact summary of `unified_diff` — the changed
   hunks and what knowledge the merge adds (steps one run missed,
   `> Alternative:` divergence notes) — not the full runbooks.
3. **Confirm gate (never skip):** accepting rewrites the workflow's canonical
   runbook. Do not run `accept-merge` without an explicit "yes"/"accept" from
   the user *for this specific merge_id*. Rejecting is also explicit — "keep
   separate" creates a new workflow entry. Frame the question as:

   > Accept the merge into **`<workflow_id>`** (old version kept under
   > `versions/`), or keep the new run as a separate workflow?

4. **Apply:** run `accept-merge` or `reject-merge` and report the JSON result
   in one line (accepted → workflow + run count; rejected → the new
   workflow id).
5. **`draft: false` entries:** the merge draft LLM call failed at ingest time.
   Say so; only `reject-merge` is available for these (a redraft flow is
   future work — F3/N5 territory).

## Rules

- Never accept without the user's explicit confirmation for that merge.
- Never edit `/sandbox/kb/` files directly — only through `kb.py`.
- Decisions are logged to the workflow's `edits.jsonl` (training signal —
  do not try to clean them up).
- If `accept-merge` returns `"stale_base": true`, mention that the canonical
  changed since the draft was made (another merge landed first) and suggest
  the user review the result with `kb.py show <workflow_id>`.
