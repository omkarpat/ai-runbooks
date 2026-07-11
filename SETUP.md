# NemoClaw Setup — Install & Run on macOS

Step-by-step install of the full NemoClaw stack for this project: sandbox,
egress policies, pipeline, smoke tests, first run. Run each step in order and
verify its checkpoint before moving on. Maps to NEMOCLAW_PLAN.md §2–§3;
paths are relative to the repo root.

Keys needed before starting (never commit them):

| Key | Format | Source |
|---|---|---|
| `HAI_API_KEY` | `hk-…` | portal.hcompany.ai (free tier OK for dev, 10 RPM) |
| `GRADIUM_API_KEY` | `gd_…` | Gradium account |
| `OPENROUTER_API_KEY` | — | openrouter.ai |

## 1. Prerequisites (~2 min)

```bash
xcode-select --install 2>/dev/null
docker info >/dev/null && echo docker-ok     # start Docker Desktop (or Colima) first
node --version                                # need >= 22.16 (brew install node)
```

**Checkpoint:** `docker-ok` prints; Node ≥ 22.16.

RAM note: the sandbox image push can OOM on 8 GB Macs — close heavy apps
first (or add swap). Image is ~2.4 GB; first build takes several minutes.

## 2. Install NemoClaw + onboard the sandbox (~10–15 min)

```bash
cd <repo-root>
export NEMOCLAW_AGENT=hermes
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash        # first install only
nemohermes onboard --from sandbox/image/Dockerfile --name runbooks
```

Wizard answers:

| Prompt | Answer |
|---|---|
| Sandbox name | `runbooks` |
| Inference provider | **OpenRouter** (paste `OPENROUTER_API_KEY`) |
| Model | `anthropic/claude-sonnet-4.5` |

The custom image (`sandbox/image/Dockerfile`) bakes in ffmpeg + `requests` —
runtime installs don't work inside the sandbox (uv-managed venv, PyPI blocked
by egress policy). If the installer auto-onboarded with defaults, re-run the
`onboard` line to get the custom image.

**Checkpoint:** onboarding prints the "NemoHermes is ready" summary.

## 3. Verify the sandbox

```bash
nemohermes runbooks status
curl -sf http://127.0.0.1:8642/health && echo hermes-api-ok
nemohermes runbooks snapshot create --name clean-onboard
```

**Checkpoint:** status healthy, `hermes-api-ok` prints, snapshot saved
(your rollback point for everything below).

## 4. Apply the egress policies

The policies are the security integration: deny-by-default networking with
exactly two holes — Holo (vision) and Gradium (speech).

```bash
nemohermes runbooks policy-add --from-file sandbox/policies/holo-models-api.yaml
nemohermes runbooks policy-add --from-file sandbox/policies/gradium-stt.yaml
nemohermes runbooks policy-list
```

**Checkpoint:** `policy-list` shows `api.hcompany.ai` and `api.gradium.ai`.

## 5. Upload pipeline + keys into the sandbox

```bash
openshell sandbox upload runbooks pipeline /sandbox/pipeline
printf 'HAI_API_KEY=hk-...\nGRADIUM_API_KEY=gd_...\n' > /tmp/.env   # real keys
openshell sandbox upload runbooks /tmp/.env /sandbox/.env && rm /tmp/.env
```

> ⚠️ `openshell sandbox upload` syntax is from the NemoClaw Workspace Files
> doc, not verified against a live install. If it errors, check
> `openshell sandbox --help` — up/download are the documented transfer
> commands, but argument order may differ.

**Checkpoint:** `nemohermes runbooks connect` →
`ls /sandbox/pipeline && cat /sandbox/.env` shows scripts + keys.

## 6. Smoke tests (inside the sandbox)

```bash
nemohermes runbooks connect
# in the sandbox shell:
chmod +x /sandbox/pipeline/smoke/*.sh
set -a; . /sandbox/.env; set +a
python3 /sandbox/pipeline/smoke/smoke_holo.py
python3 /sandbox/pipeline/smoke/smoke_gradium.py
bash /sandbox/pipeline/smoke/test_egress_blocked.sh
```

**Checkpoint (all three):**

```
OK: Holo (holo3-1-35b-a3b) replied: red
OK: Gradium streamed N NDJSON messages (types: [...])
OK: non-allowlisted egress blocked
```

Debugging a denied call: run `openshell term` in another host terminal and
retry — it names the binary and host that got blocked. If the binary differs
from `/opt/hermes/.venv/bin/python3`, fix it in both files under
`sandbox/policies/` and re-run `policy-add`.

## 7. Install the Hermes skill

```bash
openshell sandbox upload runbooks sandbox/skills/runbook-builder /sandbox/.hermes/skills/runbook-builder
```

**Checkpoint:** inside the sandbox, start `hermes` and ask "what skills do
you have?" — expect `runbook-builder`. (Skill directory path is from docs;
verify against the Hermes skills reference if it doesn't register.)

## 8. First real run

Record a short (~1 min) narrated clip with the app (`app/`), wait for the
sidecar `.json` (completion signal — see RECORDING_CONTRACT.md §1), then:

```bash
openshell sandbox upload runbooks \
  ~/Library/Application\ Support/ai-runbooks/recordings/recording-<stamp>.mov \
  /sandbox/videos/
nemohermes runbooks connect
# inside:
python3 /sandbox/pipeline/run.py /sandbox/videos/recording-<stamp>.mov "test workflow"
```

Or through the agent (the desktop app's path — RECORDING_CONTRACT.md §8):

```bash
curl -N http://127.0.0.1:8642/v1/chat/completions \
  -H "Authorization: Bearer $HERMES_API_TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"default","stream":true,"messages":[{"role":"user","content":"Build a runbook from videos/recording-<stamp>.mov for workflow '\''test workflow'\''. Reply with the finished runbook markdown."}]}'
```

**Checkpoint:** `runbook.md` lands in `/sandbox/runbooks/<name>_<epoch>/`.
Timing: on the free Holo tier expect ~6 s per frame pair (10 RPM); a 1-minute
clip ≈ 5–10 min of analysis.

## Lifecycle & recovery

```bash
nemohermes runbooks snapshot create --name <label>   # before risky changes
nemohermes runbooks logs --follow                    # debugging
openshell forward start --background 8642 runbooks   # API port dead after reboot
nemohermes inference set --model <m> --provider <p>  # swap synthesis model, no rebuild
nemohermes runbooks destroy                          # nukes sandbox + state volume
```

## Local dev loop (no sandbox)

For fast iteration on the pipeline itself, the same scripts run directly on
macOS — point synthesis at OpenRouter and override the output dir:

```bash
brew install ffmpeg && python3 -m pip install requests
export HAI_API_KEY=hk-... GRADIUM_API_KEY=gd_...
export SYNTH_URL=https://openrouter.ai/api/v1/chat/completions
export SYNTH_TOKEN=$OPENROUTER_API_KEY
export SYNTH_MODEL=anthropic/claude-sonnet-4.5
export RUNBOOKS_DIR=./runbooks-out
python3 pipeline/run.py <recording.mov> "my workflow"
```

No egress enforcement, no agent — pipeline behavior only. Anything tuned here
(`SCENE_THRESH`, `FLOOR_SECS`, prompts) carries into the sandbox unchanged.
