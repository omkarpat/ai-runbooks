# ai-runbooks
A repo to use SST and computer use agents to generate dynamic replayable runbooks

## References

- [H Company Computer Use Agents — Introduction](https://hub.hcompany.ai/computer-use-agents/introduction) — Overview and documentation for building with H Company's computer use agents.
- [hcompai/computer-use-agents-demos](https://github.com/hcompai/computer-use-agents-demos) — Example demos showing how to drive H Company's computer use agents.
- [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) — NVIDIA's NemoClaw project, referenced for related agent tooling.

## Layout

- **[`SETUP.md`](SETUP.md) — install & run the NemoClaw stack on macOS (start here)**
- `app/` — macOS menu-bar recorder + Hermes chat bar (KB-grounded)
- `pipeline/` — video → runbook stages + `kb.py` knowledge base (run inside the sandbox)
- `sandbox/` — NemoClaw artifacts: egress policies, Hermes skills, agent standing context (`SOUL.md`)
- `scripts/` — `provision-sandbox.sh` (reproduce the sandbox anywhere), `generate-runbook.sh`, `kb-context.sh`
- `docs/` — architecture ([`docs/architecture.svg`](docs/architecture.svg)) and design docs:
  - [`RECORDING_CONTRACT.md`](docs/RECORDING_CONTRACT.md) — app ↔ pipeline ↔ KB interface
  - [`NEXT_STEPS.md`](docs/NEXT_STEPS.md) — v2 roadmap (N1 ✅ · N2 ✅ · N3 ✅ · N4 planned)
  - [`N2_EXECUTION_PLAN.md`](docs/N2_EXECUTION_PLAN.md) — agentic execution deep-dive
  - [`NEMOCLAW_PLAN.md`](docs/NEMOCLAW_PLAN.md) — original v1 implementation plan
  - [`PROJECT_CONTEXT.md`](docs/PROJECT_CONTEXT.md) · [`desktop-ui-plan.md`](docs/desktop-ui-plan.md)
