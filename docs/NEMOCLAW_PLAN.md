# NemoClaw Plan — Sandbox Session + Runbook Pipeline (v1)

> Scope confirmed with project owner (2026-07-11): **Hermes** runtime, **local Mac** host,
> **OpenRouter** as the agent's inference provider, **sandbox + full pipeline** (video in →
> runbook.md out). Phase-2 replay (Sessions API / agp MCP) is out of scope here but the
> design leaves the door open.
>
> **Update (2026-07-11):** recordings now include an **audio track with user narration**.
> STT via **Gradium**, called from inside the sandbox (owner decision). Narration becomes a
> second evidence channel for synthesis. Recording is a separate person's deliverable —
> interface defined in [RECORDING_CONTRACT.md](RECORDING_CONTRACT.md).
>
> Architecture diagram: [architecture.svg](architecture.svg)

---

## 0. Locked Decisions

| Decision | Choice | Why |
|---|---|---|
| Sandbox runtime | Hermes (`nemohermes`) | Matches H Company's own NemoClaw demo — their egress policy, custom-image pattern, and MCP steps transfer directly; phase-2 replay is pre-solved. |
| Host | Local Mac (Apple Silicon) | Tested-with-limitations platform. Needs Docker Desktop **or** Colima + Xcode CLT. |
| Agent brain | OpenRouter (via OpenShell inference routing) | One key, any synthesis model; swap models with `nemohermes inference set`, no rebuild. |
| Vision engine | H Holo Models API (`api.hcompany.ai/v1`) | Called as an egress-allowed HTTP tool from inside the sandbox, NOT via inference routing. |
| Speech engine | Gradium STT REST (`api.gradium.ai/api/post/speech/asr`) | One-shot POST fits pre-recorded audio (WebSocket API exists but is for live streams). Same pattern as Holo: egress-allowed HTTP tool, key in sandbox env. Third and final allowlisted host. |
| Pipeline location | Inside the sandbox | Input is an uploaded video file, so nothing except the file drop needs the host. |
| Recording | macOS app in `app/` (ScreenCaptureKit) | `.mov` with H.264 + 2 AAC tracks (system + mic), sidecar JSON, per RECORDING_CONTRACT.md. |

**Model plan:** `holo3-1-35b-a3b` for frame-pair action inference (structured outputs,
cheap, free tier for dev). Escalate dense/text-heavy frames to `holo3-122b-a10b` (35B's
4,096-token output cap is too small for long OCR). Synthesis model via OpenRouter —
start with `anthropic/claude-sonnet-4.5` (configurable, see §7-Q3).

---

## 1. Prerequisites (host, before anything)

- [ ] Docker Desktop or Colima **running** (start it before the installer).
- [ ] Xcode Command Line Tools: `xcode-select --install`
- [ ] Node.js ≥ 22.16, npm ≥ 10
- [ ] ≥ 8 GB free RAM, ≥ 20 GB free disk (sandbox image ~2.4 GB; first build takes minutes)
- [ ] `HAI_API_KEY` (`hk-…`) from **portal.hcompany.ai** — free tier OK for dev
      (10 RPM limit; add credits before demo day, see §6-R1)
- [ ] `OPENROUTER_API_KEY` from openrouter.ai
- [ ] `GRADIUM_API_KEY` (`gd_…`) from your Gradium account
- [ ] A sample screen recording (.mp4 **with narration audio**, per RECORDING_CONTRACT.md)
      for calibration — **blocker for §5**

---

## 2. Milestone A — Onboard the Hermes sandbox

1. Install + onboard (installer runs the guided wizard):
   ```bash
   export NEMOCLAW_AGENT=hermes
   curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
   ```
   If NemoClaw is already installed: `nemohermes onboard`
2. Wizard answers:
   - Sandbox name: `runbooks` (avoid the default `hermes` so an OpenClaw sandbox can coexist)
   - Inference provider: **OpenRouter**, supply `OPENROUTER_API_KEY` when prompted
   - Model: start with `anthropic/claude-sonnet-4.5`
3. Verify:
   ```bash
   nemohermes runbooks status
   curl -sf http://127.0.0.1:8642/health        # Hermes OpenAI-compatible API
   nemohermes runbooks connect                  # terminal into the sandbox
   ```
4. Snapshot the working baseline before customizing:
   ```bash
   nemohermes runbooks snapshot create --name clean-onboard
   ```

**Custom image checkpoint.** From inside the sandbox check what the pipeline needs:
`ffmpeg`, Python ≥3.10, an OpenAI-compatible client, and `requests` (Gradium REST needs
nothing more; skip the `gradium` SDK — it targets streaming). H's demo shows the stock
Hermes image is uv-managed (no pip) and egress blocks PyPI — runtime installs don't work.
If anything is missing, rebuild from a custom Dockerfile (H's `nemoclaw/image/Dockerfile`
is the template) and re-onboard with `nemohermes onboard --from <Dockerfile> --name runbooks`.
**Assume a custom image will be needed; budget time for it.**

## 3. Milestone B — Egress policy + Holo smoke test

*The egress policy is the integration.* Baseline Hermes policy allows Nous, PyPI,
NVIDIA — not H.

1. Write `policies/holo-models-api.yaml` (adapt H's `hai-agent-platform.yaml`):
   - allow host `api.hcompany.ai:443`
   - `binaries` must match the caller: `/opt/hermes/.venv/bin/python3`
     (verify exact path in our image; a denied call names the binary in `openshell term`)
2. Write `policies/gradium-stt.yaml` — same pattern, allow `api.gradium.ai:443`,
   same `binaries` entry.
3. Apply and confirm:
   ```bash
   nemohermes runbooks policy-add --from-file policies/holo-models-api.yaml
   nemohermes runbooks policy-add --from-file policies/gradium-stt.yaml
   nemohermes runbooks policy-list
   ```
4. Smoke tests from **inside** the sandbox:
   - Holo: one chat-completion against a test screenshot
     (base URL `https://api.hcompany.ai/v1/`, `Authorization: Bearer $HAI_API_KEY`)
   - Gradium: one-shot REST transcription of a short test .wav —
     `POST https://api.gradium.ai/api/post/speech/asr`, headers `x-api-key: $GRADIUM_API_KEY`
     + `Content-Type: audio/wav`, raw WAV body; response is NDJSON
     (`text` msgs carry `start_s`, paired `end_text` msgs carry `stop_s`)
5. Prove the boundary both ways:
   - `openshell term` on the host shows the allowed call to `api.hcompany.ai:443`
   - a call to any non-allowlisted host (e.g. example.com) is **blocked**
   — this is the demo's security money-shot; script it.

**Key handling decision (see §7-Q1):** how `HAI_API_KEY` reaches pipeline scripts.
Simplest: write it into `/sandbox/.env` at setup. It lives inside the sandbox but never
in the repo/image. (OpenShell inference routing keeps the OpenRouter key on the host;
Holo is an external tool, so it doesn't get that treatment for free.)

## 4. Milestone C — Pipeline inside the sandbox

Layout (in repo, synced into `/sandbox/pipeline/`):

```
pipeline/
  extract_frames.py      # ffmpeg scene-change keyframes + 1fps floor → frames/*.png (timestamped)
  extract_audio.py       # mic track only: ffmpeg -map 0:a:1 -ac 1 → audio.wav
                         #   (app records 2 audio tracks: a:0 system, a:1 mic —
                         #    see RECORDING_CONTRACT.md §1; mono 16-bit PCM for Gradium)
  transcribe.py          # audio.wav → Gradium STT REST (one POST, NDJSON back)
                         #   pair text.start_s with end_text.stop_s
                         #   → transcript.jsonl {t0,t1,text}
  analyze_pairs.py       # consecutive pairs → Holo 35B structured outputs
                         #   → steps.jsonl {t0,t1,action,target,evidence,confidence}
                         #   2 images/call (within H's ≤3-in-context guidance)
                         #   escalation rule: dense text → holo3-122b-a10b OCR
  synthesize.py          # steps.jsonl + transcript.jsonl → Hermes API
                         #   (127.0.0.1 inside sandbox → OpenRouter)
                         #   align narration to steps by timestamp overlap (±tolerance
                         #   window — people narrate slightly before/after acting)
                         #   narration = intent channel: names steps, explains *why*,
                         #   disambiguates actions invisible in frame diffs
                         #   dedup, drop noise, write runbook
  run.py                 # orchestrate; audio + frames branches run in parallel
                         #   video in → /sandbox/runbooks/<name>/runbook.md
```

**Graceful degradation rule:** narration is enrichment, not a dependency. Silent video
(or a failed Gradium call) must still produce a runbook from the visual channel alone —
log a warning, don't abort. Conversely, narration without visible action becomes a note,
not a step.

Runbook schema (v1, per PROJECT_CONTEXT §7-Q3 — semi-structured):
title, source-video metadata, preconditions, numbered steps
(action + target + expected result + operator note from narration where available),
artifacts (key frames referenced per step).

Ingest: recordings are `.mov` files (QuickTime, H.264 + 2×AAC) written by the app to
`~/Library/Application Support/ai-runbooks/recordings/`, sidecar JSON = completion
signal. Host side syncs finished recordings into `/sandbox/videos/` — mechanism per
NemoClaw "Workspace Files" doc (verify: file drop vs `openshell` copy).

Persistence: output stays in `/sandbox/runbooks/`; `nemohermes runbooks snapshot create`
after each successful run = v1 storage story.

**App hand-off (decided 2026-07-11):** the macOS recorder app triggers processing by
POSTing to the Hermes OpenAI-compatible API (`127.0.0.1:8642/v1/chat/completions`,
bearer auth, streaming) after dropping the .mp4 — full spec in RECORDING_CONTRACT.md §8.
This makes the Hermes **skill** registration below *required*, not optional: the chat
instruction "build a runbook from videos/x.mp4" must reliably invoke `run.py`.

Register `run.py` as a Hermes skill so the agent maps that instruction to the pipeline
deterministically; the agent replies with the finished runbook markdown.

## 5. Milestone D — End-to-end run + calibration

1. Run `run.py` on the sample recording.
2. Calibrate ffmpeg scene threshold + fps floor against ground truth (owner watches the
   video, lists true steps, compare). Iterate until steps aren't missed/duplicated.
3. Measure: frames sampled, Holo calls, tokens, wall-clock, $ per minute of video.
4. Failure-mode review: invisible clicks, fast typing — document accuracy ceiling in README.

## 6. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Free tier 10 RPM → ~150-frame video takes 15+ min | Dev on free tier with short clips; add credits before demo |
| R2 | Stock image lacks ffmpeg/deps; runtime install impossible (uv, PyPI blocked, CA bundle) | Custom Dockerfile at build time (planned, §2) |
| R3 | macOS is "tested with limitations" | Colima fallback if Docker Desktop misbehaves; Linux/Brev as escape hatch |
| R4 | Holo output cap (35B: 4,096 tok) truncates OCR | Escalation rule to 122B; keep per-call asks small |
| R5 | 8 GB RAM Macs can OOM during image push | Check free RAM first; close apps or add swap |
| R6 | Narration/action timing drift breaks alignment | Overlap window with tolerance (start ±3s, tune in §5); segment-level timestamps from Gradium are coarse but sufficient |
| R7 | Silent stretches or STT failure | Graceful degradation rule (§4): visual channel alone must suffice |
| R8 | Narration contradicts what's on screen | Visual evidence wins for *what happened*; narration wins for *why* — encode this priority in the synthesis prompt |

## 7. Open questions (answer during implementation, not blockers)

- **Q1 — Holo key transport:** `/sandbox/.env` (simple) vs mounted secret. Start simple; revisit if PHI enters.
- **Q2 — steps.jsonl → synthesis handoff:** single Hermes call with full JSONL in context vs chunked map-reduce for long recordings. Decide after seeing real token counts (§5.3).
- **Q3 — OpenRouter synthesis model:** Claude Sonnet default; try Nemotron/others via `nemohermes inference set` (no rebuild) and compare runbook quality.
- **Q4 — Workspace file-drop mechanism:** confirm exact host→`/sandbox` path from the Workspace Files doc.
- **Q5 — Language hint:** pass `json_config={"language":"en"}` to Gradium, or auto-detect? Default to explicit `en` for v1.
- **Q6 — Transcript in the runbook:** include full transcript as an appendix, or only aligned per-step notes? Decide after seeing output quality in §5.

## 8. Definition of done

- [ ] `nemohermes runbooks status` healthy on the Mac
- [ ] Policy list shows `api.hcompany.ai` **and** `api.gradium.ai`; blocked-host negative test recorded
- [ ] Holo smoke test returns a valid frame description from inside the sandbox
- [ ] Gradium smoke test returns timestamped segments from inside the sandbox
- [ ] Sample .mp4 (with narration) → `runbook.md` end-to-end, steps match ground truth
      acceptably; per-step notes reflect narration
- [ ] Degradation check: silent video still produces a runbook
- [ ] App hand-off check: a chat-completion request per RECORDING_CONTRACT.md §8
      (curl is fine as a stand-in for the app) triggers the pipeline and streams back
      the runbook
- [ ] Cost + timing numbers captured
- [ ] Snapshot of the working sandbox saved
