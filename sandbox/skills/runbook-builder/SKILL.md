# Skill: runbook-builder

Build a workflow runbook from a screen recording.

## When to use

The user asks to build/generate/create a runbook from a recording, e.g.
"Build a runbook from videos/recording-2026-07-11_14-02-33.mov for workflow
'prior auth submit'". Requests arriving via the API from the desktop app use
exactly this phrasing (RECORDING_CONTRACT.md §8).

## Steps

1. Confirm the video file exists under `/sandbox/videos/`. If not, reply
   exactly: `file not found: <path>` (the app retries on this).
2. Run the extraction and analysis stages (NOT synthesis — you do that
   yourself in step 3):

   ```bash
   python3 /sandbox/pipeline/run.py /sandbox/videos/<file> "<workflow name>" --skip-synthesis
   ```

   The script prints the run directory path on stdout when it finishes. It
   contains `steps.jsonl` (visual evidence from frame-pair analysis) and, if
   narration was usable, `transcript.jsonl` (timestamped speech segments).
3. Read both files and write `runbook.md` in the same run directory, following
   these rules:
   - Visual evidence is authoritative for WHAT happened; narration for WHY.
   - Merge transitions that form one logical action; drop noise (spinners,
     focus changes). Mark uncorroborated low-confidence steps "(uncertain)".
   - Narration with no visible action becomes a Note under the nearest step.
   - Structure: `# Runbook: <name>` / `## Preconditions` / `## Steps`
     (numbered, imperative, target + expected result) / `## Outcome`.
4. Reply with the full contents of `runbook.md` — the caller streams your
   reply as the result.

## Failure handling

- `run.py` exit 4: too few keyframes — tell the user the recording appears
  static/too short.
- Holo rate-limited (analyze_pairs logs 429 retries): let it finish; it
  self-paces via HOLO_RPM.
- Never write outside `/sandbox/runbooks/` and `/sandbox/videos/`.
