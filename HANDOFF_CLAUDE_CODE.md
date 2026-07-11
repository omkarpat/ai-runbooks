# Handoff: Finish NemoClaw Sandbox Setup (for Claude Code on the Mac)

> You are Claude Code running on Aditya's Mac with full shell access. Your
> predecessor (Claude in Cowork) had no access to this machine and debugged
> blind via pasted output. Everything known is below — trust it, verify it,
> and finish the job. Read NEMOCLAW_PLAN.md for the big picture; this file is
> the tactical state.

## Mission

Get the NemoClaw sandbox `runbooks` fully onboarded and SETUP.md steps 4–8
passing: two egress policies applied, pipeline + keys uploaded, three smoke
tests green, skill installed, one end-to-end run of a recording → runbook.

## Current state (2026-07-11 ~16:30 PT)

| Thing | State |
|---|---|
| CLI | `nemoclaw`/`nemohermes` v0.0.79, installed from GitHub ref `lkg`, at `~/.local/bin/` |
| OpenShell | 0.0.72, Docker Desktop runtime |
| Docker Desktop | **7.7 GiB memory — below the 8 GiB minimum, preflight warns. Raise it first** (Settings → Resources) |
| Sandbox `runbooks` | exists, Phase Ready, custom image (ffmpeg + `requests` baked in) |
| Inference | healthy end-to-end: ollama-local, model `qwen3:latest` (host `ollama` serving on 11434, auth proxy 11435) |
| Hermes agent | v0.17.0-era after rebuild. **Gateway/API on 8642 NOT serving — this is the blocker** |
| Onboarding | incomplete, failed at step 7/8 ("Hermes Agent gateway did not respond within 90s"). Resume: `nemoclaw onboard --resume --tool-disclosure progressive` |
| Backup | `~/.nemoclaw/rebuild-backups/runbooks/2026-07-11T23-03-13-170Z` — workspace was empty; restore optional |
| Port forward | `openshell forward start --background 8642 runbooks` works, but nothing listens behind it |
| Egress policies | NOT yet applied (`Policies: none` in status) — that's SETUP.md step 4, after onboarding completes |

## Fixes already applied (don't re-litigate)

1. **Custom Dockerfile tool-disclosure contract** — validator regex is
   `/^ARG\s+NEMOCLAW_TOOL_DISCLOSURE\s*=/` (requires `=default`) plus a
   final-stage `ENV NEMOCLAW_TOOL_DISCLOSURE=${NEMOCLAW_TOOL_DISCLOSURE}`
   promotion. Both present in `sandbox/image/Dockerfile` now. Source:
   NVIDIA/NemoClaw `src/lib/onboard/dockerfile-tool-disclosure-contract.ts`.
2. **Stale Debian pin in CLI's bundled `Dockerfile.base`** —
   `curl=8.14.1-2+deb13u3` no longer in trixie; unpinned locally via sed in
   the installed CLI source (found via
   `grep -rl 'curl=8.14' ~/.local ~/.nemoclaw`). May recur for other packages
   or after a CLI update — same one-line unpin per offender.
3. **`nemoclaw-gateway-control` missing** — was CLI(0.17-era)/base-image
   (`:latest`, 0.18) version skew; the rebuild rebuilt everything from one
   release. Verify it exists now: `ls /usr/local/bin/nemoclaw-gateway-control`
   inside the sandbox.
4. **Egress policy `binaries`** — aligned to baseline:
   `/opt/hermes/.venv/bin/python` (no `3`) + `/usr/bin/python3*`.

## Key insight about the blocker

`hermes gateway run` inside the sandbox starts a **messaging gateway**
(banner: "Messaging platforms + cron scheduler") and stays up happily — but
nothing answers on 8642 inside or outside. The OpenAI-compatible API that
NemoClaw's step-7 health check polls is likely a **different subcommand**.
Nobody has run `hermes --help` yet. That's your first move.

## Task queue

1. Raise Docker Desktop memory to ≥ 8 GiB.
2. Diagnose the API service. Either upload the ready-made script:
   `openshell sandbox upload runbooks pipeline/smoke/diagnose_hermes.sh /sandbox/diag.sh`
   (upload syntax itself is unverified — if it errors, `openshell sandbox --help`
   and note the real syntax in SETUP.md), then inside
   (`nemohermes runbooks connect`): `bash /sandbox/diag.sh`.
   Or just run `hermes --help` inside and find the serve/api subcommand.
3. Start the right process; confirm `curl -sf http://127.0.0.1:8642/health`
   answers inside the sandbox, then from the host (forward already exists).
4. Check whether the supervisor can manage it now:
   `nemoclaw runbooks gateway restart` from the host. If yes, kill any manual
   foreground process and let the supervisor own it.
5. `nemoclaw onboard --resume --tool-disclosure progressive` → "ready" banner.
6. SETUP.md step 4: both `policy-add` commands; `policy-list` must show
   `api.hcompany.ai` and `api.gradium.ai`.
7. SETUP.md step 5: upload `pipeline/` and write `/sandbox/.env` with
   `HAI_API_KEY` and `GRADIUM_API_KEY`. **Ask Aditya for the key values
   interactively. Never write them to any file inside the repo, never commit
   them, never echo them into shell history if avoidable.**
8. SETUP.md step 6: three smoke tests green
   (`smoke_holo.py` → "OK … replied: red"; `smoke_gradium.py` → "OK … NDJSON";
   `test_egress_blocked.sh` → "OK … blocked").
   If a call is denied, `openshell term` on the host names the binary/host —
   fix the policy's `binaries` entry, re-`policy-add`, retry.
9. SETUP.md steps 7–8: install the skill, run one real recording end-to-end
   (recordings live in `~/Library/Application Support/ai-runbooks/recordings/`,
   only process ones whose sidecar `.json` exists).
10. Snapshot when green: `nemohermes runbooks snapshot create --name working-e2e`.
11. Update SETUP.md with every command whose real syntax differed from the
    doc, and commit (small, descriptive commits). Do not touch `app/` —
    that's another engineer's surface.

## Guardrails

- No secrets in the repo, ever. `/sandbox/.env` only.
- Keep policies least-privilege: fix denials by correcting `binaries`/paths,
  not by widening to `/**` or adding hosts.
- Prefer `nemoclaw`/`nemohermes` commands over raw `openshell`/`docker`
  surgery (docs: NemoClaw-managed environments), except where the task queue
  says otherwise.
- If you rebuild anything, snapshot first.

## Repo map

`NEMOCLAW_PLAN.md` plan · `SETUP.md` install runbook (source of the steps
above) · `RECORDING_CONTRACT.md` app↔pipeline interface · `pipeline/`
video→runbook scripts + smoke tests · `sandbox/` Dockerfile, policies, skill ·
`app/` macOS recorder (hands off) · `PROJECT_CONTEXT.md` original research.

## Reference

- NemoClaw docs: https://docs.nvidia.com/nemoclaw/latest/ (append `.md` to
  any page URL for markdown; `/llms.txt` for the index)
- NemoClaw source (for validator/contract questions):
  https://github.com/NVIDIA/NemoClaw
- H Models API: base `https://api.hcompany.ai/v1/`, auth
  `Authorization: Bearer $HAI_API_KEY`, docs https://hub.hcompany.ai/llms.txt
- Gradium STT REST: `POST https://api.gradium.ai/api/post/speech/asr`,
  headers `x-api-key` + `Content-Type: audio/wav`, NDJSON response
- Host-side NemoClaw state: `~/.nemoclaw/` (blueprints cache, sandbox
  registry, backups — see docs "Host Files and State" before deleting)

## Done =

`nemohermes runbooks status` shows agent running · policies list both API
hosts · three smoke tests green · one runbook.md generated from a real app
recording · snapshot `working-e2e` exists · SETUP.md corrections committed.
