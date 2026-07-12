# NemoClaw Setup — Install & Run on macOS

Set up the full NemoClaw **Hermes agent** + **runbook pipeline** for this
project. Every command here was validated on a live install (macOS, Docker
Desktop, `nemohermes v0.0.79`). Paths are relative to the repo root.

> **The fast path is one command** — [`scripts/provision-sandbox.sh`](scripts/provision-sandbox.sh)
> reproduces the entire sandbox from the repo. The manual steps below explain
> what it does (and are what you reach for when debugging). See
> [§ Portability](#portability--moving-to-another-machine) for why a script,
> not a snapshot, is the portable unit.

## Keys (never commit them — `.env` is git-ignored)

| Key (`.env`) | Format | Used for | Required |
|---|---|---|---|
| `OPENAI_API_KEY` | `sk-…` | Agent brain **and** pipeline synthesis (routed via `inference.local`) | ✅ (or local Ollama — see [Appendix](#appendix--running-on-local-ollama-no-openai-key)) |
| `H_API_KEY` | `hk-…` | Holo vision (pipeline frame analysis) — portal.hcompany.ai | ✅ for pipeline |
| `GRADIUM_API_KEY` | `gsk_…` / `gd_…` | Gradium STT (pipeline narration) | optional (visual-only without it) |

The agent's model is **`gpt-5.6-luna`** via OpenAI. `H_API_KEY` is read into the
sandbox as `HAI_API_KEY`.

## 0. Prerequisites

```bash
docker info >/dev/null && echo docker-ok     # start Docker Desktop first
```

- **Docker running.** Docker Desktop → Settings → Resources → Memory **≥ 8 GB**
  (12 GB comfortable). Set memory via the GUI, or `memoryMiB` (lowercase!) in
  `~/Library/Group Containers/group.com.docker/settings-store.json` + restart.
- **Node** is installed by the NemoClaw installer itself (it pulls Node 22 via
  nvm) — you don't need to pre-install it.

## 1. Install NemoClaw (~10 min, first time only)

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | NEMOCLAW_INSTALL_TAG=v0.0.79 bash
export PATH="$HOME/.local/bin:$PATH"      # nemohermes / openshell live here
```

Installs `nemohermes`, `nemoclaw`, `openshell` (0.0.72) into `~/.local/bin`.
Pinning `v0.0.79` (the current `lkg` "last known good") keeps it reproducible;
omit `NEMOCLAW_INSTALL_TAG` to track `lkg`, or use `latest` for the unvetted edge.

**Checkpoint:** `nemohermes --version` → `v0.0.79`.

## 2. Fast path — provision everything (~10 min)

```bash
cd <repo-root>              # with .env present (see Keys above)
./scripts/provision-sandbox.sh
```

This onboards the sandbox, sets the model, applies all egress policies, installs
ffmpeg, uploads the pipeline + keys, snapshots, and prints the app's
`HERMES_API_URL` / token. **If you just want it working, stop here** and jump to
[§ Wire the desktop app](#6-wire-the-desktop-app). The rest documents the steps.

---

## 3. Onboard the sandbox (manual)

> ⚠️ **Use the DEFAULT Hermes image — do NOT pass `--from sandbox/image/Dockerfile`.**
> That custom Dockerfile builds `FROM hermes-sandbox-base` and omits NemoClaw's
> agent-runtime layer (config generator, guard scripts, supervised init). The
> agent then never starts: `/sandbox/.hermes/config.yaml` is never generated and
> writes fail with `[SECURITY] … refuses mutation under a foreign PID 1`. The
> default image bakes all of that in. (ffmpeg, which the custom image was for, is
> handled at runtime in step 5.)

```bash
export NEMOCLAW_PROVIDER=openai NEMOCLAW_MODEL=gpt-4o-mini
export NEMOCLAW_PROVIDER_KEY="$OPENAI_API_KEY" OPENAI_API_KEY="$OPENAI_API_KEY"
export NEMOCLAW_IGNORE_RUNTIME_RESOURCES=1 NEMOCLAW_RECREATE_WITHOUT_BACKUP=1

nemohermes onboard --non-interactive --fresh --recreate-sandbox --agent hermes \
  --name runbooks --no-gpu --no-sandbox-gpu --yes --yes-i-accept-third-party-software
```

`gpt-4o-mini` is transient — it passes onboarding's inference smoke test (the
gpt-5.x family rejects the smoke probe's `max_tokens` param). Switch to the real
model next:

```bash
nemohermes inference set --provider openai-api --model gpt-5.6-luna \
  --sandbox runbooks --no-verify        # --no-verify skips the max_tokens smoke
```

**Checkpoint:** onboarding ends with **"Hermes is ready"** and
`nemohermes runbooks status` shows `Inference: healthy` on `gpt-5.6-luna`.

## 4. Apply egress policies

Deny-by-default networking with explicit holes. The pipeline needs Holo +
Gradium; the **agent + apt need GitHub + Debian** (the agent fetches from GitHub
at startup; ffmpeg installs from Debian mirrors in step 5).

```bash
for f in holo-models-api gradium-stt github-agent debian-apt openai; do
  nemohermes runbooks policy-add --from-file sandbox/policies/$f.yaml --yes
done
nemohermes runbooks policy-add github --yes      # built-in: git -> github.com
nemohermes runbooks policy-list
```

| Preset | Opens | Why |
|---|---|---|
| `holo-models-api` | `api.hcompany.ai` | Holo vision (pipeline) |
| `gradium-stt` | `api.gradium.ai` | Gradium STT (pipeline) |
| `github-agent` + `github` | `github.com`, `*.githubusercontent.com` | agent startup fetch (python + git) |
| `debian-apt` | `deb.debian.org`, `security.debian.org` | ffmpeg install (§5) |
| `openai-api-direct` | `api.openai.com` | direct OpenAI — usually unnecessary (the gateway proxies OpenAI via `inference.local`); included per project config |

**Checkpoint:** `policy-list` shows all of the above as active (●).

## 5. Install ffmpeg (runtime)

The default image has no ffmpeg, and egress blocks apt until `debian-apt` (step
4) is applied. Install it as root; Landlock being unavailable under Docker
Desktop means the `/usr` write succeeds.

```bash
CID=$(docker ps --filter "name=openshell-runbooks" --format '{{.ID}}' | head -1)
docker exec --user root "$CID" apt-get update
docker exec --user root "$CID" apt-get install -y --no-install-recommends ffmpeg
openshell sandbox exec -n runbooks -- sh -lc 'ffmpeg -version | head -1'
```

**Checkpoint:** `ffmpeg version 7.x` prints. `requests` is already in the image.

> This ffmpeg install lives in the container layer — it survives restarts but
> **not** `--recreate-sandbox`. Re-run this step (or the provision script) after
> a recreate.

## 6. Wire the desktop app

The chat bar talks to the Hermes agent's OpenAI-compatible API. Port 8642 is
auto-forwarded during onboarding (`openshell forward start --background 8642 runbooks`
if it isn't). Add to the repo-root `.env`:

```bash
{
  echo "HERMES_API_URL = http://127.0.0.1:8642/v1/chat/completions"
  echo "HERMES_API_TOKEN = $(nemohermes runbooks gateway-token --quiet)"
} >> .env
```

The app ([`app/`](app/)) reads these via `SecretsLoader`; `HermesRuntime` is
already wired in `AppModel`. Run it:

```bash
cd app && make run
```

**Checkpoint:** green "Hermes agent ready" dot; a prompt returns a real agent
reply. Verify the API directly:

```bash
TOKEN=$(nemohermes runbooks gateway-token --quiet)
curl -s http://127.0.0.1:8642/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"say hi"}]}'
# -> {"choices":[{"message":{"content":"Hi! ..."}}], ...}
```

> The gateway token rotates on gateway restart. If chat 401s, refresh
> `HERMES_API_TOKEN` in `.env`.

## 7. Run the pipeline (recording → runbook)

Upload the pipeline + keys, then a recording, then run it. `openshell upload`
nests the dir, so the entrypoint lands at `/sandbox/pipeline/pipeline/run.py`.

```bash
openshell sandbox upload runbooks pipeline /sandbox/pipeline
# /sandbox/.env with the pipeline keys (SYNTH goes through the gateway route):
printf 'HAI_API_KEY=%s\nGRADIUM_API_KEY=%s\nSYNTH_URL=https://inference.local/v1/chat/completions\nSYNTH_MODEL=gpt-5.6-luna\n' \
  "$H_API_KEY" "$GRADIUM_API_KEY" > /tmp/sb.env
openshell sandbox upload runbooks /tmp/sb.env /sandbox/.env && rm /tmp/sb.env

# a recording from the app:
openshell sandbox upload runbooks \
  ~/Library/Application\ Support/ai-runbooks/recordings/recording-<stamp>.mov \
  /sandbox/videos/recording.mov

openshell sandbox exec -n runbooks -- \
  python3 /sandbox/pipeline/pipeline/run.py /sandbox/videos/recording.mov "test workflow"
```

**Checkpoint:** `runbook.md` lands in `/sandbox/runbooks/<name>_<epoch>/`.
Holo's free tier is ~6 s/frame-pair (10 RPM) and can time out intermittently;
`analyze_pairs.py` retries and falls back to the reasoning field. Read it:

```bash
openshell sandbox exec -n runbooks -- \
  sh -lc 'cat /sandbox/runbooks/*/runbook.md'
```

## Portability — moving to another machine

**Snapshots, the running sandbox, and the apt-installed ffmpeg are machine-local
state** (`~/.local/state/nemoclaw`; no snapshot export). They do **not** move
between machines. The portable unit is **this repo**:

| Portable (git) | Machine-local (rebuilt each time) |
|---|---|
| `scripts/provision-sandbox.sh`, `sandbox/policies/*.yaml`, `pipeline/`, this file | running sandbox, Docker image, snapshots, ffmpeg install, gateway token |

On a new machine: `git clone` → install NemoClaw (§1) → create `.env` with your
keys → `./scripts/provision-sandbox.sh`. You reproduce the environment; you don't
copy it. (Optional Tier-2: push the built sandbox image to a container registry
for bit-identical, no-rebuild spin-up — only needed for that.)

## Lifecycle & recovery

```bash
nemohermes runbooks snapshot create --name <label>   # captures state + custom policies (with content)
nemohermes runbooks snapshot restore <label>         # reapplies them (incl. custom egress)
nemohermes runbooks status                           # health, model, policies
nemohermes runbooks logs --follow                    # agent runtime + audit logs
docker logs $(docker ps -qf name=openshell-runbooks) # raw sandbox logs (egress DENIED lines etc.)
openshell forward start --background 8642 runbooks   # re-forward API port after reboot
nemohermes inference set --model <m> --provider openai-api --sandbox runbooks --no-verify
```

A normal `--recreate-sandbox` restores custom egress policies **if its backup
succeeds**; if the backup fails and you force `NEMOCLAW_RECREATE_WITHOUT_BACKUP=1`,
re-run the provision script to reapply them.

> ⚠️ **`nemohermes runbooks rebuild` reuses the stored `--from` Dockerfile.**
> If the sandbox was ever onboarded with a custom `--from` image (the §3
> mistake), `rebuild` — even when the gateway itself suggests it via
> `SUPERVISOR_REBUILD_REQUIRED` — silently rebuilds the *same broken image*
> and destroys the sandbox in the process. The only fix is a **fresh onboard
> without `--from`** (§3 / the provision script), then re-apply policies,
> ffmpeg, and uploads (any recreate wipes all three).

## Gotchas we hit (so you don't have to)

- **Custom `--from` image on the bare base breaks the agent** — omits the runtime
  layer → no `config.yaml`, "foreign PID 1". Use the default image (§3).
- **`rebuild` does NOT fix a custom-image sandbox** — it reuses the stored
  `--from` config and reproduces the broken image (see Lifecycle & recovery).
  Symptoms: `gateway-token` fails, `gateway restart` errors with
  `nemoclaw-gateway-control: no such file or directory`. Fresh onboard instead.
- **RAM is not the agent-startup fix.** The agent failing at "step 7 / 90s" was
  the missing runtime layer, not memory.
- **ffmpeg needs the `debian-apt` egress** — apt is blocked (403) until then.
- **gpt-5.x rejects `max_tokens`** — use `--no-verify` on `inference set`;
  `synthesize.py`/`analyze_pairs.py` avoid it and read the reasoning field.
- **Holo is a reasoning VLM** — small `max_tokens` returns `content: null`;
  the pipeline bumps it and falls back to `reasoning`.

## Local dev loop (no sandbox)

Fast iteration on the pipeline itself, straight on macOS against OpenAI:

```bash
brew install ffmpeg && python3 -m pip install requests
export HAI_API_KEY=hk-... GRADIUM_API_KEY=gsk_...
export SYNTH_URL=https://api.openai.com/v1/chat/completions
export SYNTH_TOKEN=$OPENAI_API_KEY
export SYNTH_MODEL=gpt-5.6-luna
export RUNBOOKS_DIR=./runbooks-out
python3 pipeline/run.py <recording.mov> "my workflow"
```

No egress enforcement, no agent — pipeline behavior only. Tuning here
(`SCENE_THRESH`, `FLOOR_SECS`, prompts) carries into the sandbox unchanged.

## Appendix — running on local Ollama (no OpenAI key)

The full stack also runs with a local Ollama model as the agent brain — no
`OPENAI_API_KEY` at all. Validated with `qwen3:latest` (8B) on macOS. The
differences from the OpenAI path:

**1. Onboard with the ollama provider** (instead of §3's openai env vars):

```bash
NEMOCLAW_PROVIDER=ollama NEMOCLAW_MODEL=qwen3:latest \
NEMOCLAW_IGNORE_RUNTIME_RESOURCES=1 NEMOCLAW_RECREATE_WITHOUT_BACKUP=1 \
  nemohermes onboard --non-interactive --fresh --recreate-sandbox --agent hermes \
    --name runbooks --no-gpu --no-sandbox-gpu --yes --yes-i-accept-third-party-software
```

No `inference set` step needed afterward — Ollama passes the onboarding smoke
test directly (no gpt-5.x `max_tokens` issue).

**2. Skip `openai.yaml`** in the §4 policy loop — the gateway proxies Ollama
via `inference.local`; nothing needs `api.openai.com`.

**3. Override the agent's context-window check.** The Hermes agent refuses
models under **64K context**; qwen3 reports 40,960 (Ollama may discover as
little as 16,384). Chat requests fail with
`Model ... has a context window of N tokens, which is below the minimum 64,000`.
Fix inside the sandbox:

```bash
openshell sandbox exec -n runbooks -- sh -lc \
  'sed -i "s/^  context_length: .*/  context_length: 65536/" /sandbox/.hermes/config.yaml'
```

The override is a declared limit, not a real one — conversations beyond the
model's true window get truncated by Ollama. **NemoClaw regenerates
`config.yaml`** on `inference set` / gateway restart / rebuild, so re-apply
the sed if the 64K error returns.

**4. In-sandbox `.env` synthesis vars** (§7) point at the same gateway route,
just with the local model:

```bash
SYNTH_URL=https://inference.local/v1/chat/completions
SYNTH_MODEL=qwen3:latest        # no SYNTH_TOKEN needed
```

Provision script note: `scripts/provision-sandbox.sh` hard-fails without
`OPENAI_API_KEY` in `.env` — on the Ollama path run its steps manually
(policies → ffmpeg → upload → snapshot), or onboard as above first.

Runbook synthesis quality on an 8B local model is noticeably below
`gpt-5.6-luna`; the pipeline runs, but expect rougher step descriptions.
