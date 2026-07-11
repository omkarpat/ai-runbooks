# Setup — Milestones A & B (run on the Mac)

Commands to stand up the NemoClaw sandbox and verify both API boundaries.
Everything here maps to NEMOCLAW_PLAN.md §2–§3; artifact paths are relative
to the repo root.

## 0. Prerequisites

```bash
xcode-select --install        # if not already installed
# Start Docker Desktop (or Colima), then verify:
docker info >/dev/null && echo docker-ok
node --version                # need >= 22.16
```

Keys needed (put them somewhere handy, NOT in the repo):
`HAI_API_KEY` (hk-…, portal.hcompany.ai) · `GRADIUM_API_KEY` (gd_…) ·
`OPENROUTER_API_KEY`.

## A. Onboard the sandbox (custom image)

```bash
export NEMOCLAW_AGENT=hermes
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash      # first install only
nemohermes onboard --from sandbox/image/Dockerfile --name runbooks
```

Wizard answers: sandbox name `runbooks` · provider **OpenRouter** (paste key) ·
model `anthropic/claude-sonnet-4.5`.

```bash
nemohermes runbooks status
curl -sf http://127.0.0.1:8642/health && echo hermes-api-ok
nemohermes runbooks snapshot create --name clean-onboard
```

## B. Policies, keys, pipeline, smoke tests

```bash
# 1. Egress policies (the integration!)
nemohermes runbooks policy-add --from-file sandbox/policies/holo-models-api.yaml
nemohermes runbooks policy-add --from-file sandbox/policies/gradium-stt.yaml
nemohermes runbooks policy-list        # expect api.hcompany.ai + api.gradium.ai

# 2. Push pipeline + keys into the sandbox
openshell sandbox upload runbooks pipeline /sandbox/pipeline
printf 'HAI_API_KEY=hk-...\nGRADIUM_API_KEY=gd-...\nSYNTH_TOKEN=<hermes-token>\n' > /tmp/.env
openshell sandbox upload runbooks /tmp/.env /sandbox/.env && rm /tmp/.env

# 3. Smoke tests (inside the sandbox)
nemohermes runbooks connect
#   then, in the sandbox shell:
chmod +x /sandbox/pipeline/*.sh /sandbox/pipeline/smoke/*.sh
set -a; . /sandbox/.env; set +a
python3 /sandbox/pipeline/smoke/smoke_holo.py        # expect: OK ... replied: red
python3 /sandbox/pipeline/smoke/smoke_gradium.py     # expect: OK ... NDJSON messages
bash   /sandbox/pipeline/smoke/test_egress_blocked.sh # expect: OK ... blocked
```

While the smoke tests run, `openshell term` on the host shows allowed calls to
the two APIs — and names the denied binary/host for anything else. If a smoke
test is denied: check the binary path in the policy matches what `openshell
term` reports, fix, re-add the policy.

> `openshell sandbox upload` syntax unverified against a live install — if it
> differs, `openshell sandbox --help` / the Workspace Files doc is the source
> of truth. Same for the skill install path in step C.

## C. Skill + first run

```bash
openshell sandbox upload runbooks sandbox/skills/runbook-builder /sandbox/.hermes/skills/runbook-builder
# Verify Hermes picks it up (inside sandbox): hermes, then ask
#   "what skills do you have?"
```

Sync a finished recording (sidecar JSON present!) and run end-to-end:

```bash
REC=~/Library/Application\ Support/ai-runbooks/recordings/recording-<stamp>.mov
openshell sandbox upload runbooks "$REC" /sandbox/videos/
nemohermes runbooks connect
#   inside: /sandbox/pipeline/run.sh /sandbox/videos/recording-<stamp>.mov "my workflow"
```

Or through the agent (the app's path): POST to `127.0.0.1:8642/v1/chat/completions`
per RECORDING_CONTRACT.md §8.

## Cleanup / recovery

```bash
nemohermes runbooks snapshot create --name <label>    # before risky changes
nemohermes runbooks logs --follow                     # debugging
openshell forward start --background 8642 runbooks    # if API port dies after reboot
nemohermes runbooks destroy                           # nukes sandbox + state
```
