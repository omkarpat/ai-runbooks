# ai-runbooks — v1 Build Plan

Minimal macOS menu-bar app: a screen-record start/stop button + a chat bar that triggers a NemoClaw agent run. Recording (screen + system audio + mic) feeds the SST → runbook pipeline; the agent runtime connection is abstracted so a real NemoClaw/OpenShell instance can be plugged in after v1.

## Stack

- Swift 5.10+, SwiftUI, macOS 14+ (Sonoma) — required for modern ScreenCaptureKit recording APIs
- `MenuBarExtra` (window style) for the menu-bar panel
- ScreenCaptureKit for capture, AVFoundation (`AVAssetWriter`) for encoding
- No third-party dependencies in v1

## Architecture

```
┌─────────────────────────────────────────────┐
│ RunbooksApp (MenuBarExtra)                  │
│                                             │
│  ┌────────────┐   ┌──────────────────────┐  │
│  │ RecordView │   │ ChatView             │  │
│  │ ●/■ button │   │ prompt bar + run log │  │
│  └─────┬──────┘   └──────────┬───────────┘  │
│        │                     │              │
│  ┌─────▼──────────┐  ┌───────▼───────────┐  │
│  │ RecorderService│  │ AgentRunService   │  │
│  │ ScreenCaptureKit│ │ (session state)   │  │
│  │ + AVAssetWriter│  └───────┬───────────┘  │
│  └─────┬──────────┘          │              │
│        ▼              ┌──────▼────────────┐ │
│  ~/Recordings/*.mov   │ AgentRuntime      │ │
│                       │ (protocol)        │ │
│                       ├───────────────────┤ │
│                       │ MockRuntime  (v1) │ │
│                       │ GatewayRuntime(v2)│ │
│                       └───────────────────┘ │
└─────────────────────────────────────────────┘
```

Three layers, strictly separated:

1. **UI** — SwiftUI views, no business logic.
2. **Services** — `RecorderService` (capture lifecycle) and `AgentRunService` (run lifecycle, transcript state). Both are `@Observable` actors/classes.
3. **Runtime adapter** — `AgentRuntime` protocol; v1 ships `MockRuntime`, the real NemoClaw connection is a drop-in later.

## Repo layout

```
ai-runbooks/
├── app/                        # Xcode project
│   └── Runbooks/
│       ├── RunbooksApp.swift           # @main, MenuBarExtra
│       ├── UI/
│       │   ├── PanelView.swift         # record button + chat bar container
│       │   ├── RecordButton.swift
│       │   ├── ChatBar.swift
│       │   └── RunLogView.swift
│       ├── Recording/
│       │   ├── RecorderService.swift   # start/stop, state machine
│       │   ├── CaptureEngine.swift     # SCStream + AVAssetWriter
│       │   └── RecordingStore.swift    # file naming, metadata JSON
│       ├── Agent/
│       │   ├── AgentRuntime.swift      # protocol + event types
│       │   ├── MockRuntime.swift       # v1 stub
│       │   └── AgentRunService.swift   # session/transcript state
│       └── Support/
│           └── Permissions.swift       # screen/mic permission helpers
├── PLAN.md
└── README.md
```

## Core interfaces

### AgentRuntime protocol

The one contract that matters — everything downstream (NemoClaw gateway, HoloDesktop MCP, local CLI) hides behind it:

```swift
protocol AgentRuntime {
    /// Start a run from a chat prompt. Streams events until terminal state.
    func startRun(prompt: String, context: RunContext) -> AsyncThrowingStream<AgentEvent, Error>
    func cancelRun(id: RunID) async throws
    var status: RuntimeStatus { get }   // .disconnected / .connecting / .ready
}

enum AgentEvent {
    case runStarted(RunID)
    case assistantText(String)          // streamed tokens/messages
    case toolCall(name: String, detail: String)
    case runCompleted(RunID)
    case runFailed(RunID, Error)
}

struct RunContext {
    var latestRecordingURL: URL?        // hand the last recording to the agent
    var workspacePath: String?
}
```

`MockRuntime` streams canned events with delays so the full UI loop (send → streaming transcript → completion) is exercisable without any backend.

### RecorderService state machine

`idle → requestingPermission → recording → stopping → idle`, with `failed(Error)` reachable from any state. UI binds directly to this state (button shows ●, ■, or spinner).

## Recording pipeline (screen + system audio + mic)

1. `SCShareableContent.current` → pick main display (v1: whole main display, no window picker).
2. `SCStreamConfiguration`: display resolution, 30 fps, `capturesAudio = true` (system audio), `captureMicrophone = true` + `microphoneCaptureDeviceID` (macOS 15 API; on macOS 14 fall back to a parallel `AVCaptureSession` for mic).
3. Three `SCStream` outputs → `AVAssetWriter` with one video input (H.264) and two audio inputs (AAC): system audio + mic on separate tracks — separate tracks matter later so SST transcribes narration cleanly.
4. Stop → finalize writer → write sidecar JSON (`started_at`, `duration`, `display`, `app_versions`) next to the `.mov` in `~/Library/Application Support/ai-runbooks/recordings/` (also symlink/copy into repo `recordings/` if desired for the runbook pipeline).
5. `RecordingStore.latest` feeds `RunContext.latestRecordingURL`.

Permissions: Screen Recording + Microphone (TCC). `Permissions.swift` checks `CGPreflightScreenCaptureAccess()` / requests, deep-links to System Settings on denial. App must be signed (dev cert fine) or TCC grants won't stick between launches.

## UI spec

Single panel (~360×480) from the menu-bar icon:

- **Top**: record button (red dot ↔ stop square) + elapsed timer while recording + subtle "REC" state in the menu-bar icon itself.
- **Middle**: run log — scrolling transcript of `AgentEvent`s (assistant text, tool-call chips, status lines).
- **Bottom**: chat bar — single-line `TextField` + send. Enter triggers `AgentRunService.start(prompt:)`. Disabled while a run is active; a Cancel button appears instead.
- Runtime status dot (gray/amber/green) in the panel header, driven by `AgentRuntime.status`.

## Milestones

**M1 — Shell (day 1)**
Xcode project, MenuBarExtra, panel with static record button + chat bar. App launches, icon in menu bar.

**M2 — Recording (days 2–3)**
RecorderService + CaptureEngine end-to-end: permission flow, start/stop, `.mov` with 3 tracks lands on disk, timer + icon state. Acceptance: record 30s of screen with narration, play it back in QuickTime, both audio tracks present.

**M3 — Chat loop with mock runtime (day 4)**
AgentRuntime protocol, MockRuntime, AgentRunService, run log UI streaming events. Acceptance: type a prompt, watch a fake run stream to completion; cancel mid-run works.

**M4 — Wiring + polish (day 5)**
Latest recording attached to RunContext; settings popover (runtime URL field — stored for v2, recordings folder picker); error toasts; app icon.

**v1 exit criteria**: record/stop works reliably, chat triggers a full mock run, and swapping `MockRuntime` for a real implementation requires touching only one file.

## v2 — connecting the real runtime (out of scope for v1, informs the protocol)

Two integration paths, both implementable behind `AgentRuntime`:

1. **NemoClaw/OpenShell gateway** (`GatewayRuntime`): the app talks to the OpenShell gateway of a `nemoclaw`-onboarded sandbox (local or remote instance). The gateway owns sandbox lifecycle, inference routing, and network policy; the app is just a thin chat client. Settings field from M4 holds the gateway URL/token.
2. **Computer use via HoloDesktop**: the NemoClaw agent delegates GUI work to H Company's H Agent through HoloDesktop CLI's MCP/ACP surface (`holo mcp` / `holo acp`), or the app drives it directly via A2A (`holo serve`, local HTTP) — A2A is the natural fit if the app ever needs to trigger computer-use runs without going through NemoClaw. `holo_desktop.agent_client` also supports pause/resume/cancel and mid-run messages, which map cleanly onto `AgentEvent`/`cancelRun`.

Also v2: SST transcription of recordings (mic track → transcript → runbook draft), replay of runbooks as agent prompts.

## Risks

- **ScreenCaptureKit mic capture is macOS 15+**; on 14 the fallback AVCaptureSession adds sync complexity. If min target can be 15, take it.
- **TCC friction**: unsigned/ad-hoc builds lose screen-recording permission on rebuild. Use a stable signing identity from day 1.
- **Recording while the agent controls the screen** (the eventual demo loop) is fine technically, but keep recorder and runtime fully independent so one can't stall the other — hence separate services.
- NemoClaw's supported operator entry point is its CLI/gateway, not a public SDK; keep `GatewayRuntime` assumptions minimal until you stand up the instance and can probe the actual gateway API.
