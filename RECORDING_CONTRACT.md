# Recording Contract — Screen-Recording Deliverable

> Interface contract between the **recording component** (you) and the **analysis
> pipeline** (NemoClaw sandbox, see [NEMOCLAW_PLAN.md](NEMOCLAW_PLAN.md)). If a recording meets this
> contract, the pipeline guarantees it can be processed; if it doesn't, failures are
> on the recording side. Changes to this contract must be agreed by both sides.

## 1. Deliverable

One file per workflow recording:

| Property | Requirement |
|---|---|
| Container | `.mp4` (single file, video + audio muxed together) |
| Video codec | H.264 (AVC). H.265 acceptable if unavoidable — flag it. |
| Audio codec | AAC, **mono preferred**, ≥ 16 kHz sample rate (44.1/48 kHz fine) |
| Duration | ≤ 10 minutes per workflow (split longer workflows into parts) |
| Timebase | Video and audio from the same clock, starting at t=0. No post-hoc trimming/splicing that shifts one track relative to the other. |

Muxing both tracks in one container is what guarantees the sync the pipeline
depends on — do not deliver separate video and audio files.

## 2. Video requirements

- **Full desktop capture** (entire primary display, not a single window or browser tab).
- **Single monitor.** Multi-monitor capture is untested; if the workflow spans monitors,
  record the primary one and keep the workflow on it.
- Native display resolution, minimum 1920×1080. **No downscaling, letterboxing, or
  post-processing** — action inference reads small UI text.
- Frame rate ≥ 10 fps (30 fps preferred). Constant frame rate if the recorder offers it.
- **Cursor must be visible** in the recording. If the tool supports click highlighting /
  click sound, enable it — this measurably improves action detection.
- No overlays that occlude UI (webcam bubbles, watermarks, notification pop-ins —
  enable Do Not Disturb).

## 3. Audio requirements (narration)

The user narrates what they're doing **as they do it**. This is an evidence channel,
not decoration — the pipeline aligns spoken segments to on-screen actions by timestamp.

Narration protocol for the person being recorded:

1. **Start:** state the workflow name and goal ("This is how I file a prior-auth
   request for…").
2. **During:** describe intent per action, present tense, roughly synchronous with the
   action ("Now I open the patient record… I'm copying the member ID into the portal").
   Naming the *thing* acted on matters more than eloquence.
3. **Preconditions:** mention any setup state out loud ("I'm already logged into Epic").
4. **End:** say the outcome ("The request is submitted — that's the whole workflow").

Quality bar: quiet room, no music, one speaker, normal pace. English for v1.
Silence during stretches of pure clicking is fine — the pipeline degrades gracefully.

## 4. Content constraints

- **No PHI, no real patient data, no production credentials.** Synthetic/test
  environments only (v1 scope decision — see PROJECT_CONTEXT.md §2).
- No personal content visible (private email, chats, unrelated tabs).

## 5. Naming & delivery

- Filename: `<workflow-slug>_<yyyymmdd>_v<n>.mp4` (e.g. `prior-auth-submit_20260711_v1.mp4`)
- Deliver to the agreed drop location (currently: the `videos/` folder Aditya specifies;
  final host→sandbox path is NEMOCLAW_PLAN.md §7-Q4).
- Include a one-line ground-truth step list per recording (plain text, the steps *you*
  believe the workflow contains). This is the calibration reference for NEMOCLAW_PLAN.md §5 —
  it's how we measure the pipeline, not extra homework.

## 6. Self-validation before handoff

Run `ffprobe <file>` (ships with ffmpeg) and check:

- [ ] exactly one video stream (h264) + one audio stream (aac)
- [ ] resolution ≥ 1920×1080, fps ≥ 10
- [ ] duration matches the session (no truncation)
- [ ] audio audible and in sync at start, middle, and end (spot-check by playing)
- [ ] cursor visible in playback
- [ ] no PHI on screen at any point

## 7. Acceptance

A recording is accepted when the pipeline produces a runbook whose steps can be
compared against your ground-truth list. First recording is a calibration round —
expect one iteration of feedback (e.g. "narrate closer to the click", "raise fps").

**Out of scope for you:** transcription (pipeline calls Gradium STT), frame
extraction, any H Company / Gradium / OpenRouter credentials.
