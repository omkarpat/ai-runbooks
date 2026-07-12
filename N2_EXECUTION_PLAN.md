# N2 Plan — Agentic Execution (chat bar runs runbooks)

> Owner decisions (2026-07-11): **N2 lands before N1** — no `catalog.json` yet, so
> runbook lookup targets `/sandbox/runbooks/` directly with a clean seam for N1's
> catalog. **EU endpoint (`agp.eu.hcompany.ai`) locked** — this is a PoC, not going
> to prod; region choice is not revisited here.
>
> Parent: [NEXT_STEPS.md](NEXT_STEPS.md) §N2 · Wiring verified against H's demo
> (`computer-use-agents-demos/nemoclaw/README.md`, 2026-07-11).

---

## Implementation status — 2026-07-11 (E1 + E3 landed)

**E1 done and verified live** against the running `runbooks` sandbox
(NemoClaw v0.0.79):

- **Managed MCP supersedes hand-written policy+config.** NemoClaw v0.0.74+ ships
  native `nemohermes <sandbox> mcp add <server> --url <url> --env KEY`. One call
  created the OpenShell credential provider, generated the `protocol: mcp`
  egress policy for `agp.eu.hcompany.ai`, and wrote the `/sandbox/.hermes/config.yaml`
  entry — with the `hk-` key stored in OpenShell's provider store and present in
  the sandbox only as `openshell:resolve:env:HAI_AGENT_MCP_TOKEN`. This is
  strictly better than §2.2/§2.3's plan (which would have written the bearer
  token into the config as plaintext), so **§2.2 (hand-written
  `hai-agent-platform.yaml`) and §2.3 (hand-written config) are not done that way
  and should be treated as superseded.** Command folded into
  `scripts/provision-sandbox.sh` (§2.5).
- **E1.1 image fix is moot.** The default full Hermes image already carries
  HTTP-MCP support (its own Dockerfile asserts `_MCP_AVAILABLE` /
  `_MCP_HTTP_AVAILABLE` at build time). `mcp add` fails closed with rebuild
  guidance if support is missing; ours succeeded. `sandbox/image/Dockerfile`
  annotated accordingly — kept only as a documented fallback.
- **Verification (§2.4 / DoD):** `hermes mcp test hai-agent-platform` → all six
  tools discovered (`run_agent`, `wait_for_session`, `list_agents`,
  `send_message`, `cancel_session`, `share_session`). Blocked-host negative test
  recorded: `example.com` and `api.github.com` → `ProxyError`; `agp.eu.hcompany.ai`
  → HTTP 200.
- **Q1 answered:** the same `hk-` key covers the agent platform — `mcp add`'s
  on-the-wire credential-resolution probe returned **HTTP 200**. Not a separate
  credential.
- **Q2 answered (transport):** `wait_for_session(session_id, wait=true)`
  long-polls for the answer; `wait=false` returns the current snapshot — so
  streaming (§4.6) is poll-with-optional-long-poll. `run_agent` also exposes a
  native `idempotency_key` param, which backs §4-step-4's double-submission
  guard. Whether snapshots carry *observed step events* (the evidence-based
  report source of §3.4/§4.7) still needs a live E2 run to confirm.

**E3 + E4 landed as code:** `sandbox/skills/runbook-runner/SKILL.md` written
(find → plan → params → confirm → launch → stream → report, plus the E4
hardening: mid-run relay, bounded-poll timeouts, failure taxonomy, idempotence
warning). Installed into the sandbox and gateway restarted; both `runbook-builder`
and `runbook-runner` now install via the provision script (frontmatter added).

**E2 smoke test done (2026-07-11).** Trivial no-side-effect session via the MCP
tools directly: `run_agent("go to example.com and report the page title",
"h/web-surfer-flash")` → session completed in 33s, answer `"Example Domain"`.
Lifecycle observed: `run_agent` returns a `session_id` immediately (async,
`status: running`); `wait_for_session` long-polls to completion; `share_session`
returns a public URL. `h/web-surfer-flash` confirmed present in `list_agents`
(alongside `web-surfer-pro`, `web-scraper-{pro,flash}`, `deep-search-pro`).

**§3.4 report-source probe — RESOLVED.** Two sources, different reach:

- **MCP surface (in-sandbox):** `wait_for_session` returns ONLY
  `{session_id, status, answer, done}` — no step/action events. So an in-sandbox
  report is limited to the self-reported recap (§4.5). This is the accepted PoC
  source.
- **Trajectory JSON — now fetchable in-sandbox (fixed 2026-07-11):**
  `share_session` returns `https://agp.eu.hcompany.ai/share/api/v1/trajectories/<id>`
  — a public JSON document with `status`, `error`, `metrics` (steps, cost,
  duration) and a full `events[]` action log (`observation`→`policy`→
  `tool_result` cycles, `AgentCompletionEvent`). Initially blocked (MCP-scoped
  egress), so the new preset `sandbox/policies/hai-trajectory-read.yaml` grants
  GET on it; verified the sandbox now reads it (HTTP 200, 16 events). The
  runbook-runner report is therefore **recap-for-step-labels,
  trajectory-for-truth**: completion/duration/step-count come from the
  trajectory, and any recap-vs-trajectory mismatch is surfaced. F2's
  stale-detector builds on this trajectory, not the self-reported recap.
  Caveat: OpenShell v0.0.72 doesn't enforce path for `protocol: rest`, so the
  grant is effectively GET-to-`agp.eu.hcompany.ai` (still GET-only, one host,
  public data).
- **Watching a run:** the share URL is data (JSON), not a UI —
  `agp.eu.hcompany.ai` is a pure API host (root → 403). The visual Agent View
  replay is in the H portal (`portal.hcompany.ai`, EU), under the key-owner
  account.

**Still not done (needs a real side-effectful run + your go-ahead):** the
end-to-end "Run the &lt;X&gt; runbook" demo through the app chat bar (§8), and
the mid-run-question relay demo (§8). The `recording-2026-07-11_18-47-52` Google
Forms runbook is a ready 4-web-step candidate — but running it **resubmits that
form**, so it needs an explicit confirm.

---

## 0. Locked decisions

| Decision | Choice | Why |
|---|---|---|
| Executor | H hosted agent platform via MCP (`https://agp.eu.hcompany.ai/mcp`) | HTTP + key only — no repo/uv baked into the image; H's demo pattern transfers directly. |
| Agent | `h/web-surfer-flash` first | Pre-built; custom agent only if form-heavy workflows underperform (§7-Q4). |
| Trigger surface | Existing Hermes chat API (RECORDING_CONTRACT §8) | App chat bar already speaks it; "Run the <name> runbook" is just a second recognized phrasing. |
| Runbook source | Scan `/sandbox/runbooks/*/runbook.md` (interim) | N1 not built yet. Lookup isolated in one skill step so catalog.json swaps in later. |
| Scope | Web workflows only | Cloud browser. Local-app steps are flagged "manual" up front — never silently skipped. |
| Safety gate | Explicit confirm before launch + synthetic targets only | Replays have side effects (submissions). Contract §4's no-prod-credentials rule applies to execution too. |

## 1. Prerequisites

- [ ] v1 works: at least one generated runbook exists under `/sandbox/runbooks/`
- [ ] Hermes API reachable on host (`curl -sf http://127.0.0.1:8642/health`) — pending HANDOFF item
- [ ] `HAI_API_KEY` (`hk-…`, EU) valid for the **agent platform** (verify same key covers Models API + agp — §7-Q1)
- [ ] A synthetic/test web target for the demo workflow (no real logins, no PHI)
- [ ] Snapshot before touching the image: `nemohermes runbooks snapshot create --name pre-n2`

## 2. Milestone E1 — Plumbing (image + egress + MCP)

*The egress policy is the integration; the image fix is the enabler.*

1. **Image:** stock Hermes `mcp` lacks `mcp.client.streamable_http`; runtime install is
   impossible (uv-managed venv, PyPI egress scoped, CA bundle). Merge H's fix
   (`nemoclaw/image/Dockerfile` in their demo repo — includes a build-time check that
   fails if HTTP-MCP support didn't land) into our `sandbox/image/Dockerfile`, keep the
   check. Re-onboard: `nemohermes onboard --from sandbox/image/Dockerfile --name runbooks`.
2. **Egress:** add `sandbox/policies/hai-agent-platform.yaml` (adapt H's template):
   allow `agp.eu.hcompany.ai:443`, `binaries: /opt/hermes/.venv/bin/python3` (same entry
   as our Holo/Gradium policies). Apply with `policy-add`, confirm with `policy-list`.
3. **Register the MCP server** in `/sandbox/.hermes/config.yaml` (host `~/.hermes` does
   not apply):

   ```yaml
   mcp_servers:
     hai-agent-platform:
       url: https://agp.eu.hcompany.ai/mcp
       headers:
         Authorization: "Bearer hk-…"
       timeout: 420
   ```

4. **Verify:** `hermes mcp test hai-agent-platform` inside the sandbox → expect six
   tools: `run_agent`, `list_agents`, `wait_for_session`, `send_message`,
   `cancel_session`, `share_session`. Negative test: `openshell term` on the host shows
   the allowed call to `agp.eu.hcompany.ai:443`; extend
   `pipeline/smoke/test_egress_blocked.sh` to keep proving non-allowlisted hosts block.
5. **Automate:** fold 1–3 into `scripts/provision-sandbox.sh` so re-onboarding stays
   reproducible.

## 3. Milestone E2 — Hosted-agent smoke test

1. From Hermes chat: "list the available H agents" (exercises `list_agents` through the
   agent, not just the transport).
2. Trivial session: `run_agent` → "go to example.com and report the page title" with
   `h/web-surfer-flash`; `wait_for_session` to completion; get the Agent View replay
   link (`share_session`) and open it in a host browser.
3. Record wall-clock, tokens/cost, and any platform quota limits observed (§7-Q1).
4. **Probe the report sources** (decides how E3's per-step report is built):
   - Capture the exact payload shape `wait_for_session` returns while polling — does the
     platform surface intermediate step/action events, or only terminal status + final
     output?
   - Check whether the session's event log (what the Agent View replay renders) is
     programmatically accessible via the raw Sessions API / `hai-agents` SDK — the six
     MCP tools do not expose it.

Acceptance: session completes; replay link plays; egress event visible in `openshell term`;
§4-step-7 report source decided (self-reported recap vs observed events).

## 4. Milestone E3 — `runbook-runner` skill

New skill at `sandbox/skills/runbook-runner/SKILL.md`, mirroring `runbook-builder`
conventions (exact trigger phrasing = API for the app).

Trigger: "Run the <name> runbook" (with optional "using <new values>…").

1. **Find** (the N1 seam): scan `/sandbox/runbooks/*/runbook.md`, match `<name>` against
   `# Runbook: <name> — <context>` title lines. Multiple candidates → ask the user to
   pick; none → list what exists. This step is the only thing N1's `catalog.json`
   replaces.
2. **Plan:** parse steps; classify each web vs local-app (step context/app from the
   runbook + judgment). Local steps → marked **manual** in the plan. Reply with the run
   plan up front: steps to execute, steps the user must do by hand, and where the run
   pauses for them.
3. **Parameters (F1-lite):** detect concrete values in steps (emails, IDs, dates, search
   terms). Ask: "run with the recorded values or substitute new ones?" Full
   extraction-at-synthesis (`{{parameters}}`) stays with F1/N1.
4. **Confirm gate:** "About to execute N steps in a cloud browser against <target> —
   proceed?" No launch without explicit yes.
5. **Launch:** translate web steps into one task prompt (imperative steps + preconditions
   + expected results as verification hints) → `run_agent` (`h/web-surfer-flash`).
   The task prompt MUST frame the steps as a numbered checklist and require, as the
   agent's final output, a structured recap — one line per step:
   `{"step": n, "status": "done|failed|skipped", "evidence": "<one line>"}` (JSON lines
   or a markdown table; pick in E3 and keep it stable — the runner parses it).
6. **Stream:** poll `wait_for_session`, relay progress into the chat reply; agent
   questions mid-run → surface in chat, user answers → `send_message`; user "stop" →
   `cancel_session`.
7. **Report:** per-step outcome (done / manual-skipped / failed), duration, Agent View
   replay link. Failures per step recorded in the reply — F2's stale-detection hook.

   **Report-source caveat (documented decision):** the platform does not return a
   structured per-step report natively — `wait_for_session` yields the agent's final
   output plus the replay link, and the replay is a visual trace for humans, not data.
   The default source is therefore the **prompt-enforced recap from step 5, which is
   self-reported** by the same agent that did the work: it can be confidently wrong
   (a missed click reported as done). Acceptable for the PoC; the human cross-check is
   the replay link, which the report must always include. If E2's probe (§3.4) finds
   observed step/action events (via `wait_for_session` payloads or the raw Sessions
   API), switch the report source to those — evidence-based beats self-reported, and
   F2's stale detection should be built on that, not on recap claims.

## 5. Milestone E4 — Interaction & failure hardening

- **Mid-run relay loop:** demo-scripted case where the H agent asks a question and the
  answer travels chat bar → Hermes → `send_message`.
- **Timeouts:** MCP `timeout: 420` covers one call, not a long session — poll
  `wait_for_session` in bounded intervals; stuck session → `cancel_session` + report.
- **Failure taxonomy in the report:** login wall (expected — synthetic targets only),
  UI-mismatch/stale runbook (F2 later), platform rate limit (top up before demo day).
- **Idempotence warning:** if the same runbook ran in the last N minutes, say so in the
  confirm gate (double-submission guard).

## 6. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Our custom image + H's Dockerfile changes conflict | Merge into one Dockerfile; keep H's build-time HTTP-MCP check as the tripwire |
| R2 | Re-onboard loses sandbox state (runbooks, config) | `pre-n2` snapshot (§1); runbooks also live in run dirs — back up before rebuild |
| R3 | Platform quotas/pricing unknown on free tier | Measure in E2; add credits before demo day (same lesson as Holo R1) |
| R4 | Runbook prose under-specifies for the executor | Expected-result per step already in schema; if weak, tune `runbook-builder`'s synthesis prompt — fix upstream, not in the runner |
| R5 | Side-effectful replay (real submissions) | Confirm gate + synthetic targets only (§0); no prod credentials exist in scope anyway |
| R6 | `wait_for_session` semantics assumed (blocking vs poll) | Resolve in E2 before building E3's streaming loop (§7-Q2) |

## 7. Open questions

- ~~**Q1 — Key scope:**~~ **ANSWERED (2026-07-11):** one `hk-` key covers both —
  `mcp add`'s wire-level credential probe against `agp.eu.hcompany.ai` returned HTTP 200
  using the same key the pipeline uses for the Holo Models API. Quota headroom on the
  agent platform still to be measured in E2.
- ~~**Q2 — `wait_for_session`:**~~ **ANSWERED (2026-07-11):** poll-with-optional-long-poll
  — `wait=true` long-polls for the answer, `wait=false` returns the current snapshot;
  `run_agent` also has a native `idempotency_key`. The snapshot carries ONLY terminal
  status + final answer (no step events); the observed-event log lives in the
  `share_session` trajectory instead, now fetched in-sandbox via `hai-trajectory-read`
  (see §3.4 above). Report is evidence-based.
- **Q3 — Tool-call visibility:** how Hermes surfaces MCP progress inside a streamed chat
  reply — the app only renders `assistantText`, so progress must land in reply text.
- **Q4 — Agent fit:** `h/web-surfer-flash` vs custom agent for form-heavy portals.
  Evaluate after the first real runbook execution; don't pre-build.

## 8. Definition of done

- [x] `hermes mcp test hai-agent-platform` lists all six tools; blocked-host negative test recorded *(2026-07-11)*
- [ ] E2 smoke session completes with a viewable Agent View replay link
- [ ] "Run the <X> runbook" from the **app chat bar** executes a ≥2-web-step runbook on a
      synthetic site end-to-end: plan → confirm → progress → per-step report + link
- [ ] Per-step report parses from the recap contract (§4.5) — or from observed events if
      E2's probe found them — and every report includes the replay link
- [ ] A runbook containing local-app steps produces a plan with those steps flagged
      manual — and still confirms before launching the web portion
- [ ] One mid-run question relayed and answered through the chat bar
- [ ] `scripts/provision-sandbox.sh` reproduces E1 from scratch; post-E3 snapshot saved
