# Runbooks — macOS floating command bar (v1)

Menu-bar app implementing [`../docs/desktop-ui-plan.md`](../docs/desktop-ui-plan.md): a
screen-record start/stop button + a chat bar that triggers an agent run. The chat
lives in a **floating command bar** — a borderless, always-on-top pill anchored to
the top-center of your screen (Spotlight/Raycast style) — while a small menu-bar
icon toggles it and mirrors recording state. It ships with a `MockRuntime` so the
whole UI loop works with no backend; swapping in a real NemoClaw/OpenShell gateway
means replacing a single file (`MockRuntime.swift`).

## Layout

Three strictly-separated layers (as in the plan):

- **UI** — `Sources/Runbooks/UI/` — `FloatingBarView` (the pill: status dot +
  record control + chat field), `RunLogView` (expands above the field during a
  run), `FloatingBarController` (the AppKit `NSPanel` that hosts + anchors it)
- **App shell** — `RunbooksApp.swift` (`MenuBarExtra` toggle menu),
  `AppDelegate.swift` (creates the panel), `AppModel.swift` (shared state)
- **Services** — `Recording/RecorderService.swift` (capture state machine),
  `Recording/CaptureEngine.swift` (SCStream + AVAssetWriter),
  `Agent/AgentRunService.swift` (run/transcript state)
- **Runtime adapter** — `Agent/AgentRuntime.swift` (protocol + event types),
  `Agent/MockRuntime.swift` (v1 stub)

Built as a Swift Package + a `Makefile` that assembles and ad-hoc-signs a proper
`Runbooks.app` bundle (needed for `LSUIElement` and TCC identity).

## Requirements

- macOS 15+ (uses ScreenCaptureKit microphone capture)
- Xcode / Swift toolchain (`swift build`)

## Build & run

```sh
cd app
make run     # builds, bundles, ad-hoc signs, runs in foreground (logs to terminal)
# or
make open    # launches detached like a normal menu-bar app
```

On launch the **floating command bar** appears at the top-center of your screen,
and a **record icon** appears in the menu bar (no dock icon — it's an accessory
app). The bar is:

- **Always on top** and visible across all Spaces / full-screen apps.
- **Draggable** — grab any empty area of the pill to move it; it remembers the spot.
- **Dismissible** with `Esc`; reopen from the menu-bar icon → **Show Command Bar**
  (or `⌘B` while the menu is open).

Quit from the menu-bar icon → **Quit ai-runbooks**, or `Ctrl-C` if you used `make run`.

`make` targets: `build`, `bundle`, `run`, `open`, `clean`.

## How to test

### 1. Chat loop (no permissions needed) — M3
1. `make run`. The floating bar appears at the top of the screen with the text
   field already focused.
2. The **green dot** on the left of the bar means "Ready (mock)" (hover for label).
3. Type a prompt (e.g. "build a runbook for onboarding") and press Enter.
4. The bar **expands downward** into a run log: your message, status line,
   assistant bubbles, blue tool-call chips (`load_recording`, `screen.analyze`,
   `runbook.write`), then **Run completed**. The bar's top edge stays anchored.
5. Start another run and hit the **stop button** (replaces Send) mid-stream —
   it stops and logs "Run cancelled."

### 2. Recording — M2
1. Click the red **record** button on the left of the bar (or the menu-bar icon →
   **Start Recording**).
2. First run triggers **Microphone** and **Screen Recording** permission prompts.
   - Screen Recording must be enabled in **System Settings ▸ Privacy & Security ▸
     Screen Recording** (the app deep-links you there and shows an inline hint if
     it's not granted). Toggle it on, then click record again.
3. While recording: the button becomes a **stop square**, an **elapsed timer**
   appears next to it in the bar, and the menu-bar icon fills in.
4. Narrate for ~30s, then click stop. The bar returns to idle.
5. Verify the file:
   ```sh
   open ~/Library/Application\ Support/ai-runbooks/recordings/
   ```
   Open the newest `.mov` in QuickTime. Confirm video + **two audio tracks**
   (system audio + mic). A `.json` sidecar sits next to it with
   `started_at` / `duration` / `display`.

### 3. Recording → agent wiring — M4
After recording at least once, send a chat prompt. The tool-call chip
`load_recording` shows the latest recording's filename, proving
`RunContext.latestRecordingURL` is threaded through.

## Permissions note (TCC)

Screen Recording grants are keyed to the code signature. This build is **ad-hoc
signed**, so a rebuild can reset the grant and re-prompt. That's expected for
local dev; use a stable Developer ID signing identity to make grants persist
(see the plan's Risks section).

## Not yet implemented (M4 stretch / v2)

- Settings popover (gateway URL field, recordings-folder picker)
- Custom app icon
- Real `GatewayRuntime` / HoloDesktop bridge, SST transcription (v2)
