#!/usr/bin/env python3
"""Stitch per-transition observations + narration into a runbook.

Usage:  synthesize.py <steps.jsonl> <transcript.jsonl|-> <out_runbook.md> [workflow-name]

Env:    SYNTH_URL     default http://127.0.0.1:8642/v1/chat/completions
                      (Hermes local API -> routed to OpenRouter by the gateway)
        SYNTH_TOKEN   bearer token for the Hermes API (from the generated env)
        SYNTH_MODEL   default "default"
        ALIGN_SLOP_S  narration/step alignment tolerance seconds (default 3)

Pass "-" as the transcript to synthesize from the visual channel alone
(graceful-degradation path).
"""
import json
import os
import sys

import llm

SYSTEM = """You turn screen-recording observations into a precise, reusable runbook.

Input: a JSON list of observed steps. Each has visual evidence (action, target,
details, confidence, timestamps) and possibly `narration` — what the user said
around that moment.

Rules:
- Visual evidence is authoritative for WHAT happened; narration is authoritative
  for WHY and for naming the workflow's intent. If they conflict about what
  happened, trust the visual.
- Merge steps that are one logical action (e.g. several typing transitions into
  one "enter X into Y" step). Drop noise: spinners, focus changes, redundant views.
- Low-confidence steps (< 0.4) that narration doesn't corroborate: include only
  if the surrounding flow makes them clearly necessary; mark them "(uncertain)".
- Narration with no visible action becomes a Note under the nearest step, not a step.
- Each step carries a `context` (app — window/page title), and a context chain
  is provided. Use it:
  - Title: append the DOMINANT context to the runbook name, e.g.
    "# Runbook: <workflow name> — <dominant context>".
  - If there is more than one distinct context, group steps under
    "### In <context>" subheadings, in chain order.
  - A brief context island (1-2 steps) that does not serve the workflow
    (e.g. a chat notification detour) becomes a "> Off-workflow detour:" note,
    not steps.

Output exactly this markdown structure, nothing else:

# Runbook: <workflow name> — <dominant context>

## Preconditions
- <state that must already hold, from narration/first frames>

## Steps
(### In <context> subheadings when multiple contexts)
1. **<imperative action>** — <target and specifics>. <expected result if visible>
2. ...

## Outcome
<what the workflow accomplishes, from the final state and closing narration>
"""


def attach_narration(steps, transcript, slop):
    for step in steps:
        lo, hi = step["t0"] - slop, step["t1"] + slop
        said = [seg["text"] for seg in transcript
                if seg["t1"] >= lo and seg["t0"] <= hi]
        if said:
            step["narration"] = " ".join(said)
    return steps


def main() -> int:
    if len(sys.argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        return 2
    steps_path, transcript_path, out_path = sys.argv[1:4]
    workflow = sys.argv[4] if len(sys.argv) == 5 else "(unnamed workflow)"

    slop = float(os.environ.get("ALIGN_SLOP_S", "3"))

    with open(steps_path) as f:
        steps = [json.loads(line) for line in f if line.strip()]
    if not steps:
        print("synthesize: no steps to synthesize", file=sys.stderr)
        return 3

    transcript = []
    if transcript_path != "-":
        with open(transcript_path) as f:
            transcript = [json.loads(line) for line in f if line.strip()]
    steps = attach_narration(steps, transcript, slop)

    # Context chain written by analyze_pairs.py next to steps.jsonl.
    chain = {}
    chain_path = os.path.join(os.path.dirname(os.path.abspath(steps_path)),
                              "context_chain.json")
    if os.path.isfile(chain_path):
        with open(chain_path) as f:
            chain = json.load(f)

    user_msg = (
        f"Workflow name hint: {workflow}\n"
        f"Narration available: {bool(transcript)}\n"
        f"Dominant context: {chain.get('dominant', '(unknown)')}\n"
        f"Context chain: {json.dumps(chain.get('phases', []))}\n\n"
        f"Observed steps:\n{json.dumps(steps, indent=1)}"
    )

    runbook = llm.chat(SYSTEM, user_msg)

    with open(out_path, "w") as f:
        f.write(runbook.strip() + "\n")
    print(f"synthesize: runbook -> {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
