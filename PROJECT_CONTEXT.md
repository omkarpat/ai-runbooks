# Project Context: Screen-Recording → Workflow Runbook App

> **Purpose of this file.** This is a complete handoff briefing. It captures the project
> goal, all research done on the H Company + NVIDIA NemoClaw stack, the confirmed product
> decisions, the recommended architecture, and the open questions. A model reading this
> should be able to continue the work with no prior conversation.

---

## 1. The Goal

Build an app that:
1. **Records the screen** of a user.
2. **Identifies the exact steps** the user takes in the recording.
3. **Produces a textual representation** of the workflow (a "runbook").

The working repo is `ai-runbooks`, described as: *"A repo to use SST and computer use agents
to generate dynamic replayable runbooks."*

### Reference material (from the repo README)
- **H Company Computer-Use Agents — docs:** https://hub.hcompany.ai/computer-use-agents/introduction
- **H Company demos repo:** https://github.com/hcompai/computer-use-agents-demos
- **NVIDIA NemoClaw:** https://github.com/NVIDIA/NemoClaw

---

## 2. Confirmed Product Decisions

These were explicitly chosen by the project owner and constrain the design:

| Dimension            | Decision                        | Implication |
|----------------------|---------------------------------|-------------|
| **Capture surface**  | **Full desktop** (native apps + browser, whole OS) | Browser-only H tooling is insufficient; need OS-level capture. |
| **Input type**       | **Pre-recorded video file** (user uploads .mp4/.mov) | No live event instrumentation; actions are *inferred* from frames. |
| **Output goal**      | **Textual runbook only** (human-readable steps) | No replay/execution required in v1. |
| **Data sensitivity** | **No PHI / internal-only** (synthetic or test recordings) | No sandboxing/compliance layer needed for v1. |

> Note: The owner is at `lana.health` (healthcare). PHI is out of scope *for now* but likely
> relevant later if real patient screens get recorded — revisit sandboxing at that point.

---

## 3. The H Company Stack — What Each Piece Does

H Company's headline product *drives* UIs (sees screen → clicks/types). This project does the
**inverse**: *observe* a user and *describe* what they did. Both are powered by the same
**Holo family of Vision-Language Models (VLMs)** — but they use different parts of the stack.

### 3.1 Models API (⭐ the core engine for this project)
OpenAI-compatible access to the raw Holo VLMs. This is what turns pixels into meaning.
Relevant primitives:
- **Element localization** — find/point to the UI element at a coordinate, or locate a named element.
- **Document OCR** — read on-screen text (window titles, menu labels, field contents).
- **Chat completions over screenshots** — describe what a frame shows / infer what happened.

Docs:
- Models API overview: https://hub.hcompany.ai/about-the-models-api.md
- Models list & pricing: https://hub.hcompany.ai/models.md
- Chat completions: https://hub.hcompany.ai/models-api/chat-completions.md
- Element localization: https://hub.hcompany.ai/element-localization.md
- Document OCR: https://hub.hcompany.ai/document-ocr.md

### 3.2 Computer-Use Agents / Sessions API (action-oriented, NOT needed for v1)
Drives a **cloud browser** (browser today; remote desktop VMs on roadmap). One `POST /sessions`
call spins up a browser and runs a plain-language task. This is the natural way to **replay** a
runbook later — matches the "dynamic replayable runbooks" phrasing — but is not needed for
textual-output v1.
- Endpoint (EU): `https://agp.eu.hcompany.ai/api/v2/sessions` (US: `agp.hcompany.ai`)
- SDKs: `hai-agents` (Python: `pip install hai-agents`; TypeScript: `npm install hai-agents`)
- Pre-built agent example: `h/web-surfer-flash`
- Docs: https://hub.hcompany.ai/computer-use-agents/introduction

### 3.3 HoloDesktop CLI (local desktop control, NOT needed for v1)
Runs Holo against the **local desktop** (native apps, not just browser) — perceive + act.
Relevant only if v1 later needs to drive/replay on a real desktop.
- Docs: https://hub.hcompany.ai/holo-desktop-cli/index.md

### 3.4 Auth
- API key env var: `HAI_API_KEY` (format `hk-...`)
- Create key: https://platform.hcompany.ai/settings/api-keys
- `hai login` can set it up automatically.

---

## 4. Recommended Architecture (for the confirmed v1 scope)

**Pipeline:** `video file → frames → Holo VLM → LLM synthesis → runbook`

Only one H piece is required: the **Models API**. No H infrastructure to provision — just API calls.

1. **Ingest & sample frames.** Use `ffmpeg` scene-change detection to pull keyframes only where
   the screen actually changes, plus a light periodic sample (e.g. 1 fps floor) so slow
   interactions aren't missed. *This frame-sampling strategy is the single biggest cost/quality lever.*
2. **Read each keyframe with Holo.** Use **document OCR** (extract on-screen text) and
   **chat completions over the screenshot** (describe UI state, e.g. "Gmail compose window open,
   To field focused"). **Element localization** helps name *what* is where.
3. **Infer the action between frames.** Feed consecutive frame *pairs* (before → after) to the VLM
   and ask what the user did to get from one state to the next ("opened File menu", "typed subject",
   "clicked Send"). This is where steps are derived.
4. **Synthesize the runbook.** Pass ordered per-step observations to an LLM that merges duplicates,
   drops noise (spinners, cursor jitter), and writes a clean numbered workflow.
5. **Output** as markdown/text.

### Key technical risk (a consequence of the video-only decision)
There is **no ground-truth click/keystroke stream** — every action is *inferred* from frame
differences. That sets the accuracy ceiling. Failure cases: clicks that don't visibly change the
screen, fast keystrokes, precise coordinates.

**Mitigations:**
- Aggressive scene sampling so no transition is skipped.
- Before/after frame pairing (step 3).
- Recordings that show the cursor / click-highlights improve action detection significantly.
- **Upgrade path if accuracy is insufficient:** add lightweight event capture (clicks/keystrokes +
  a screenshot per event). This is far more accurate but requires recording through a purpose-built
  tool rather than accepting arbitrary uploaded video.

---

## 5. NVIDIA NemoClaw — What It Is and Where It Fits

**NemoClaw is a security runtime, not a screen-understanding tool and not a workflow database.**
It builds an **NVIDIA OpenShell sandbox** (isolated container: Landlock, seccomp, network-namespace
isolation) and runs an agent — **Hermes** or **OpenClaw** — *inside* it. A gateway routes the
agent's inference to a chosen provider and enforces a **declarative egress network policy**.

Core design principle: the sandboxed agent has **no direct access to the host**. It sees only
`/sandbox` and `/tmp`, and can only reach network hosts explicitly allowlisted.

Docs:
- Overview: https://docs.nvidia.com/nemoclaw/latest/about/overview.html
- Architecture: https://docs.nvidia.com/nemoclaw/latest/about/how-it-works.html
- H's NemoClaw deployment demo: https://github.com/hcompai/computer-use-agents-demos/blob/main/nemoclaw/README.md

### Two questions that were asked about NemoClaw, and the answers:

**Q: Can NemoClaw store workflows for long-term automation?**
*Partially — not as a workflow database.* It provides persistent **workspace files** (`/sandbox`),
**backup/restore**, and **state migration across machines**, so generated runbooks can be kept and
moved with the sandbox, and the always-on agent (skills, MCP, sub-agents, heartbeats) can re-run one
later. But it is **not** a runbook catalog, versioning system, or scheduler — those you build
around it. NemoClaw is *the secure box where a stored workflow gets replayed*, not the
system-of-record. For a product-grade workflow library, use your own DB.

**Q: Can NemoClaw run the agent to capture data from the target PC and send it to Holo servers?**
Split answer:
- **Capture from the target PC — NO.** This contradicts the sandbox model. The agent is walled off
  from the host by design; it cannot grab the host's screen/files/apps. **Screen capture must happen
  on the host, in a separate recorder outside NemoClaw**, which then drops video/frames into the
  sandbox workspace.
- **Send to H's servers — YES, that's the supported pattern.** Once data is in the sandbox, the
  agent reaches H's hosted endpoint via an **allowlisted egress rule**. H's own demo adds an egress
  policy for `agp.eu.hcompany.ai` and registers H's platform as an MCP server. Without that policy
  line, OpenShell blocks the call.

Two nuances:
- H's demo points at the **Computer-Use Agents platform** (`agp` — agent/session API), *not* the raw
  **Holo Models API**. Both are H endpoints; allowlist whichever you call.
- NemoClaw's **inference routing** (the agent's own brain → NVIDIA/OpenAI/Anthropic/etc.) is separate
  from calling Holo as an **external tool**. Holo is OpenAI-compatible, so it can be wired as a custom
  inference endpoint *or* reached as an egress-allowed HTTP/MCP tool (the demo's approach).

### Net position on NemoClaw for this project
- **Overkill for the v1 analysis pipeline** (pre-recorded video in, textual runbook out, no PHI).
  v1 is just: host recorder + Holo Models API calls. No sandbox needed.
- **Earns its place only in a later automation/replay phase** — a secure, egress-controlled box to
  run a Hermes/OpenClaw agent that replays stored runbooks and calls H's servers. Even then it
  handles *safe execution + persistence*; capture-on-host and the workflow catalog remain the app's
  responsibility.

---

## 6. Component Ownership Summary

| Concern | Owner | Notes |
|---|---|---|
| Screen recording (full desktop) | **Your app (host component)** | Must live on the host; cannot be done by a NemoClaw-sandboxed agent. |
| Frame extraction / sampling | **Your app** | `ffmpeg` scene detection + periodic floor. |
| Frame understanding (OCR, describe, localize) | **H Holo Models API** | The core engine. |
| Action inference + runbook synthesis | **Your app + an LLM** | Frame-pair reasoning, dedup, prose synthesis. |
| Workflow storage / catalog / scheduling | **Your app (own DB)** | NemoClaw is not this. |
| Secure replay execution (future) | **NemoClaw sandbox + Hermes/OpenClaw** | Only for the automation phase; needs egress policy to H. |
| Replay/drive a UI (future) | **H Sessions API or HoloDesktop CLI** | Browser (Sessions) or local desktop (HoloDesktop). |

---

## 7. Open Questions / Decisions Still Needed

1. **Frame-sampling tuning** — needs a real sample recording to calibrate scene-change thresholds and
   the fps floor.
2. **Which LLM does the synthesis step** — Holo VLM handles per-frame vision; the step-stitching
   synthesis could be Holo chat-completions or a separate general LLM. (This is the "change the model"
   question this handoff is being prepared for.)
3. **Runbook output schema** — free-form markdown vs. a semi-structured template (title, preconditions,
   numbered steps, expected result).
4. **Cost controls** — VLM calls per frame add up; sampling strategy + batching are the levers.
5. **Future: replay** — if/when the runbook must become executable, decide Sessions API (browser) vs
   HoloDesktop CLI (desktop), and whether NemoClaw sandboxing is required (PHI trigger).

---

## 8. Quick-Start Facts for the Next Model

- Language/SDK: `hai-agents` available in **Python** and **TypeScript**. Demos repo is ~87% Python.
- Env var needed: `HAI_API_KEY` (`hk-...`), from https://platform.hcompany.ai/settings/api-keys
- Models API is **OpenAI-compatible** — standard chat-completions client works, pointed at H's endpoint.
- Default region in H demos is **EU** (`agp.eu.hcompany.ai`); swap to `agp.hcompany.ai` for US.
- The `/hai-agents` skill (installable Claude Code plugin) can scaffold SDK code:
  `/plugin marketplace add hcompai/computer-use-agents-demos` then `/plugin install hai-agents@hai-skills`.
- Full docs index (every page): https://hub.hcompany.ai/llms.txt
