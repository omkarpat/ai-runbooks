# Recording Contract — App ↔ Pipeline Interface

> Interface contract between the **macOS recorder app** (`app/`, implemented) and the
> **analysis pipeline** (NemoClaw sandbox, see [NEMOCLAW_PLAN.md](NEMOCLAW_PLAN.md)).
> Sections 1–3 and 5 describe what the app **actually produces** (verified against
> `CaptureEngine.swift` / `RecordingStore.swift` @ b708675) — the pipeline must consume
> exactly this. Changes on either side must be agreed by both.

## 1. Deliverable (as implemented)

Per recording, the app writes **two files**:

| File | Content |
|---|---|
| `recording-<yyyy-MM-dd_HH-mm-ss>.mov` | QuickTime container: 1 H.264 video track + **2 AAC audio tracks** |
| `recording-<yyyy-MM-dd_HH-mm-ss>.json` | Sidecar metadata: `started_at` (ISO8601), `duration` (sec), `display`, `app_version`, `os_version` |

Track layout (order is fixed by the writer):

| Stream | Content | Format |
|---|---|---|
| `v:0` | Screen, full primary display | H.264, 2× Retina backing scale, up to 30 fps, cursor rendered |
| `a:0` | **System audio** | AAC stereo 48 kHz 128 kbps |
| `a:1` | **Microphone (narration)** | AAC stereo 48 kHz 128 kbps |

**Completion signal: the sidecar JSON.** The writer finalizes the .mov first and writes
the sidecar only on success — the .mov exists (and grows) during recording, so consumers
MUST NOT touch a .mov until its .json appears.

**Pipeline consequences** (encoded in NEMOCLAW_PLAN.md §4):
- STT input is the **mic track only**: `ffmpeg -map 0:a:1`, downmixed to mono WAV for Gradium.
- System audio (`a:0`) is not used in v1 (potential future signal: alert dings, etc.).
- Mic capture is **best-effort** — if the user denies mic permission the recording still
  happens and `a:1` may be silent/empty. The pipeline's graceful-degradation rule covers this.

## 2. Video properties

The implementation already satisfies the pipeline's needs: full primary display at native
2× Retina scale (small UI text survives for OCR), cursor rendered into frames
(`showsCursor`), ≤ 30 fps. Constraints that remain on the *user* of the app, not the code:

- **Single monitor:** the app captures `displays.first` (primary). Keep the workflow on it.
- No overlays occluding UI — enable Do Not Disturb before recording.
- Keep recordings ≤ 10 minutes per workflow (cost + context; split longer workflows).

## 3. Narration protocol (the human side)

The mic track is an evidence channel — the pipeline aligns spoken segments to on-screen
actions by timestamp. The person recording should:

1. **Start:** state the workflow name and goal ("This is how I file a prior-auth request for…").
2. **During:** describe intent per action, present tense, roughly synchronous with the
   action ("Now I open the patient record… I'm copying the member ID into the portal").
   Naming the *thing* acted on matters more than eloquence.
3. **Preconditions:** say setup state out loud ("I'm already logged into Epic").
4. **End:** say the outcome ("The request is submitted — that's the whole workflow").

Quality bar: quiet room, no music, one speaker, normal pace. English for v1. Silence
during stretches of pure clicking is fine. **Mute system audio sources that play speech**
(videos, calls) — they land on `a:0` but can bleed into the mic.

## 4. Content constraints

- **No PHI, no real patient data, no production credentials.** Synthetic/test
  environments only (v1 scope decision — see PROJECT_CONTEXT.md §2).
- No personal content visible (private email, chats, unrelated tabs).

## 5. Location & workflow identity

- Recordings land in `~/Library/Application Support/ai-runbooks/recordings/`
  (survives independent of the repo working tree).
- Filenames are timestamps; **workflow identity is not in the filename or sidecar yet.**
  Until a `workflow` field is added to the sidecar (recommended app change, see §9),
  the workflow name reaches the pipeline via the chat trigger message (§8).
- Per recording, supply a plain-text ground-truth step list (the steps *you* believe the
  workflow contains) — calibration reference for NEMOCLAW_PLAN.md §5.

## 6. Validation

`ffprobe <file>.mov` on a finished recording must show:

- [ ] exactly 3 streams: `v:0` h264, `a:0` aac, `a:1` aac
- [ ] video resolution = 2× the display's logical resolution
- [ ] duration ≈ sidecar `duration` (no truncation)
- [ ] mic narration audible on `a:1`: spot-check with
      `ffplay -map 0:a:1 <file>.mov` at start, middle, end
- [ ] cursor visible in playback
- [ ] no PHI on screen at any point
- [ ] sidecar `.json` present and parseable

## 7. Acceptance

A recording is accepted when the pipeline produces a runbook whose steps can be compared
against the ground-truth list. First recording is a calibration round — expect one
iteration of feedback (e.g. "narrate closer to the click").

**Out of scope for the app:** transcription (pipeline calls Gradium STT), frame
extraction, any H Company / Gradium / OpenRouter credentials.

## 8. Programmatic hand-off (app → pipeline API)

The app triggers processing via the **Hermes agent's OpenAI-compatible API** on the host.
There is no separate ingest service; the file delivers the bytes, the API call starts the
work. In the app's architecture this is the real `AgentRuntime` implementation replacing
`MockRuntime` — `RunContext.latestRecordingURL` maps to the trigger message below, and
streamed completion chunks map to `AgentEvent.assistantText`.

### Endpoint

| | |
|---|---|
| URL | `POST http://127.0.0.1:8642/v1/chat/completions` |
| Auth | `Authorization: Bearer <HERMES_API_TOKEN>` — from the Hermes environment generated at onboarding. Provided out-of-band; never commit it or bundle it in the app. |
| Precondition | Port forward active on the host: `openshell forward start --background 8642 runbooks`. Treat *connection refused* as "pipeline offline", not fatal. |

### Sequence

1. **Wait for the completion signal:** the sidecar `.json` for the recording exists
   (per §1, the .mov alone is not sufficient — it exists while recording is in progress).
2. **Make the file reachable by the sandbox** (host→`/sandbox` sync path is
   NEMOCLAW_PLAN.md §7-Q4; the app is not responsible for this step in v1 — the host
   watcher/operator is).
3. **Trigger:**

   ```json
   {
     "model": "default",
     "stream": true,
     "messages": [{
       "role": "user",
       "content": "Build a runbook from videos/recording-<stamp>.mov for workflow '<workflow name>'. Reply with the finished runbook markdown."
     }]
   }
   ```
4. **Result:** the agent's streamed reply **is** the runbook markdown (a copy persists at
   `/sandbox/runbooks/`). Use `stream: true` and a generous overall timeout — processing
   takes minutes (longer on H's free tier); a default 30–60 s HTTP timeout will cut it off.

### Failure modes the app must handle

| Symptom | Meaning | App behavior |
|---|---|---|
| connection refused | port forward not running | surface "pipeline offline"; retry after operator fixes forward |
| 401 | bad/missing bearer token | surface configuration error |
| agent replies "file not found" | recordings→sandbox sync lag | retry once after a short delay; if persistent, escalate |
| stream ends with error mid-run | pipeline failure (see NEMOCLAW_PLAN.md §6) | keep the .mov; re-trigger is safe (idempotent per file) |

> Interface stability: the endpoint shape is OpenAI-standard; the exact `model` value and
> the sandbox-visible path prefix are confirmed during Milestone A/B. Treat both as config.

## 9. Recommended app changes (non-blocking)

1. **Add `workflow` (name) to the sidecar JSON** — removes the dependence on the chat
   message for workflow identity and makes recordings self-describing.
2. **Mono mic track** (`AVNumberOfChannelsKey: 1` for `micInput`) — halves STT payload;
   Gradium wants mono anyway, and stereo narration carries no information.
3. **Surface mic-permission state in the UI** at record start — a silent `a:1` currently
   fails soft and is only discovered at pipeline time.
