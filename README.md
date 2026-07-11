# ai-runbooks
A repo to use SST and computer use agents to generate dynamic replayable runbooks

## References

- [H Company Computer Use Agents — Introduction](https://hub.hcompany.ai/computer-use-agents/introduction) — Overview and documentation for building with H Company's computer use agents.
- [hcompai/computer-use-agents-demos](https://github.com/hcompai/computer-use-agents-demos) — Example demos showing how to drive H Company's computer use agents.
- [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) — NVIDIA's NemoClaw project, referenced for related agent tooling.

## Layout

- `NEMOCLAW_PLAN.md` — implementation plan (architecture: `docs/architecture.svg`)
- **[`SETUP.md`](SETUP.md) — install & run the NemoClaw stack on macOS (start here)**
- `RECORDING_CONTRACT.md` — app ↔ pipeline interface
- `app/` — macOS menu-bar recorder
- `pipeline/` — video → runbook scripts (run inside the sandbox)
- `sandbox/` — NemoClaw artifacts: custom image, egress policies, Hermes skill
