---
name: runbook-runner
description: "Execute a saved workflow runbook in a cloud browser via the H hosted agent platform: plan, confirm, run, per-step report."
version: 1.0.0
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [runbook, execution, browser, agent-platform, mcp, replay]
    related_skills: [runbook-builder]
---

# Skill: runbook-runner

Execute a workflow runbook that `runbook-builder` produced, by driving a cloud
browser through the H hosted agent platform (MCP server `hai-agent-platform`).

## When to use

The user asks to run/execute/replay a saved runbook, e.g.
"Run the prior auth submit runbook" or "Run the contact-info runbook using
alice@example.com". Requests arriving via the API from the desktop app use this
exact phrasing:

> **Run the `<name>` runbook** _(optionally: **using `<new values>…`**)_

The trigger phrasing is the API for the app — keep it stable (mirrors
`runbook-builder` / RECORDING_CONTRACT §8). The app only renders your streamed
`assistantText`, so **everything the user must see — the plan, the confirm
question, progress, and the final report — has to be in your reply text.** There
is no side channel.

## Executor

MCP server `hai-agent-platform` (H agent platform, `agp.eu.hcompany.ai`). Six
tools, called with these exact shapes:

| Tool | Signature | Use |
|---|---|---|
| `list_agents` | `(page=1, size=20)` | enumerate runnable agents (`h/…` are public) |
| `run_agent` | `(task, agent, max_steps?, max_time_s?, idempotency_key?)` | start a session; returns the answer or a session handle |
| `wait_for_session` | `(session_id, wait=true)` | `wait=true` long-polls for the answer; `wait=false` returns the current snapshot |
| `send_message` | `(session_id, message)` | answer a mid-run question |
| `cancel_session` | `(session_id)` | stop a stuck/unwanted run (no-op if already finished) |
| `share_session` | `(session_id)` | returns the public Agent View replay URL |

Default agent: **`h/web-surfer-flash`**. Confirm it appears in `list_agents`
before the first run of a session; if the platform renamed it, pick the closest
`h/` web agent and say which you chose.

**Scope: web workflows only.** The executor is a cloud browser. Local-app steps
(native macOS/Windows apps — Finder, VS Code, Discord, a desktop mail client,
etc.) CANNOT be executed and are flagged **manual** up front — never silently
skipped.

## Steps

### 1. Find the runbook (the N1 seam)

Scan `/sandbox/runbooks/*/runbook.md`. Each starts with a title line:

```
# Runbook: <name> — <context>
```

Match `<name>` (case-insensitive, ignore surrounding whitespace) against the
requested name.

- **Exactly one match** → proceed with it.
- **Multiple matches** → list them (name + context + run-dir) and ask which.
- **No match** → reply with the names of every runbook that exists so the user
  can retry. Do not guess.

> This is the ONLY step N1's `catalog.json` will replace — keep the lookup here
> and nowhere else so the swap is a one-function change.

### 2. Plan (classify every step)

Read the whole `runbook.md`. Parse `## Steps` into an ordered list. Classify
each step using its `### In <context>` heading and target:

- **web** — a browser/page/portal/web-form context (Chrome, a site name, a
  `forms.gle`/`http(s)` target, "portal", "page").
- **local-app** — a native desktop app context (VS Code, Cursor, Discord,
  Finder, Terminal, a desktop mail/notes client). These become **manual**.

Reply with the run plan **up front**, before doing anything else:

- the ordered steps you will execute in the browser,
- the steps the user must do by hand (marked **manual**, with why),
- where the run pauses for a manual step, if interleaved.

If the runbook is entirely local-app, say so and stop — there is nothing for the
cloud browser to do.

### 3. Parameters (F1-lite)

Scan the web steps for concrete values: emails, usernames, record/order IDs,
dates, search terms, URLs. List what you found and ask:

> Run with the recorded values, or substitute new ones? (e.g. `email → …`)

If the trigger already carried "using `<new values>`", apply them and just
confirm the substitution. Full extraction-at-synthesis (`{{parameters}}`) is
F1/N1 — do not attempt it here.

### 4. Confirm gate (never skip)

Do not launch without an explicit "yes". Ask:

> About to execute **N** step(s) in a cloud browser against **`<target>`** with
> **`<recorded | substituted>`** values. Proceed?

**Idempotence warning (E4):** replays have real side effects (form submissions,
etc.). If you ran this same runbook within the last ~10 minutes (same name +
same values), say so in this gate — it may double-submit.

### 5. Launch

Translate the **web** steps into ONE task prompt for `run_agent`. The prompt
MUST:

1. Frame the steps as a **numbered checklist** (imperative), carrying each
   step's precondition and its expected result as a **verification hint**.
2. State the target URL(s) and the parameter values to use.
3. Require, as the agent's **final output**, a structured per-step recap —
   **one JSON object per line**, nothing else after it:

   ```
   {"step": 1, "status": "done", "evidence": "form loaded, title 'Contact information'"}
   {"step": 2, "status": "done", "evidence": "clicked Submit; saw 'response recorded'"}
   ```

   `status` ∈ `done | failed | skipped`. This JSON-lines contract is fixed — the
   runner parses it in step 7; do not change the shape.

Call:

```
run_agent(
  task=<the checklist prompt>,
  agent="h/web-surfer-flash",
  idempotency_key=<stable hash of runbook name + resolved values>,
)
```

Pass `idempotency_key` so a retry of the *same* run doesn't double-execute
(backs the step-4 guard). Keep the return value — it is either the final answer
or a `session_id` to wait on.

### 6. Stream & interact

If `run_agent` returned a `session_id`, poll `wait_for_session(session_id,
wait=true)` in **bounded** intervals (the MCP `timeout` covers a single call,
not the whole session — a long run needs repeated long-polls). After each poll,
relay a one-line progress update into your reply text (Q3: the app shows only
reply text).

- **Agent asks a question mid-run** → surface it verbatim in chat. When the user
  answers, forward it with `send_message(session_id, <answer>)`, then resume
  polling. (This is E4's mid-run relay loop.)
- **User says "stop"** → `cancel_session(session_id)` and report what completed.
- **Session stuck** (no progress across several bounded polls past its
  `max_time_s`) → `cancel_session` and report it as a timeout, not a success.

### 7. Report

Always produce:

First get the share link and the evidence trajectory:

1. `share_session(session_id)` → the public URL
   (`https://agp.eu.hcompany.ai/share/api/v1/trajectories/<id>`). `share_session`
   sets the trajectory public — call it before fetching.
2. **Fetch the trajectory for ground-truth evidence** (egress preset
   `hai-trajectory-read` allows this GET):

   ```python
   import requests
   traj = requests.get(share_url, timeout=15).json()
   ```

   From it, use as the **authoritative** signals:
   - `traj["status"]` (`completed` / `failed`) and `traj["error"]` — did the run
     actually finish, or error out?
   - `traj["metrics"]["steps"]`, `traj["started_at"]`/`finished_at` — real step
     count and wall-clock duration; `traj["metrics"]["total_cost"]` — cost.
   - `traj["events"]` — the action stream (`observation_event` → `policy_event` →
     `tool_result` cycles = browser actions; `answer_event`;
     `AgentCompletionEvent.reason`). Corroborates that work happened.

Then report:

- **Per-step outcome** — done / **manual-skipped** / failed. The step-5
  JSON-lines recap supplies the per-step *claims* (it is the only source keyed to
  the runbook's step numbers); the trajectory is the **cross-check**. If the
  recap claims steps done but `traj["status"]` is `failed`/errored or the event
  stream shows no successful `tool_result`s, report the discrepancy and trust the
  trajectory. Any step the plan marked manual is **manual-skipped**, never done.
- **Duration / steps / cost** — from the trajectory metrics (not the recap).
- **Share / replay link** — always include the URL. It is the human cross-check.

Record per-step failures explicitly — they are F2's stale-detection signal.

> **Report-source (settled + fixed after the E2 smoke run, 2026-07-11).** The MCP
> surface does NOT return per-step events — `wait_for_session` yields only
> `{session_id, status, answer, done}`. The evidence lives in the
> `share_session` trajectory JSON (`events[]`, `status`, `metrics`), which the
> E2 probe found and which the `hai-trajectory-read` egress preset now lets this
> skill fetch in-sandbox. So the report is **recap-for-step-labels,
> trajectory-for-truth**: the self-reported recap can be confidently wrong (a
> missed click reported as done), so completion, duration, and step count come
> from the trajectory and any recap-vs-trajectory mismatch is surfaced. F2's
> stale-detector builds on the trajectory, not the recap.
>
> Path note: OpenShell v0.0.72 enforces host+method (not path) for
> `protocol: rest`, so `hai-trajectory-read` effectively grants GET to
> `agp.eu.hcompany.ai` — still least-privilege (GET-only, one host, public data).
>
> **Watching a run live:** the share URL returns data, not a UI. The visual
> Agent View replay is in the H portal (`portal.hcompany.ai`, EU region), under
> the account that owns the `hk-` key.

## Failure taxonomy (put the label in the report)

- **login wall** — expected; targets are synthetic only, no prod credentials
  exist in scope. Report as "blocked: login required (synthetic-target rule)".
- **UI mismatch / stale runbook** — the page no longer matches the recorded
  steps. Report which step and what differed; this is the F2 hook. Fix upstream
  in `runbook-builder`'s synthesis, not by patching here.
- **platform rate limit / quota** — report it plainly so credits get topped up
  before a demo.

## Rules

- Never launch without the step-4 confirm.
- Never silently skip a local-app step — it is always reported manual.
- Never write outside `/sandbox/runbooks/` (read-only here anyway).
- Synthetic/test targets only. No real logins, no PHI (RECORDING_CONTRACT §4).
