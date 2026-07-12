# syntax=docker/dockerfile:1
#
# Custom NemoClaw Hermes sandbox image for the runbook pipeline.
#
# Why a custom image (pattern from H's demo, nemoclaw/image/Dockerfile):
# runtime installs inside the sandbox don't work — the venv is uv-managed
# (no pip), the egress policy blocks PyPI, and uv doesn't trust the image's
# patched CA bundle. Everything the pipeline needs goes in at BUILD time,
# where normal networking and cert trust apply.
#
# Pipeline needs:
#   - ffmpeg            (frame extraction, mic-track demux)
#   - requests          (Gradium STT REST + Holo Models API calls)
#
# Build and onboard:
#   export NEMOCLAW_AGENT=hermes
#   nemohermes onboard --from sandbox/image/Dockerfile --name runbooks

ARG BASE_IMAGE=ghcr.io/nvidia/nemoclaw/hermes-sandbox-base:latest
FROM ${BASE_IMAGE}

# Required by NemoClaw's tool-disclosure contract (validator regex demands
# `ARG NEMOCLAW_TOOL_DISCLOSURE\s*=` with a default, exactly once in the final
# stage, promoted to ENV). Onboarding rewrites the default with the selected
# mode via dockerfile-patch.
ARG NEMOCLAW_TOOL_DISCLOSURE=progressive
ENV NEMOCLAW_TOOL_DISCLOSURE=${NEMOCLAW_TOOL_DISCLOSURE}

# --- OS packages -------------------------------------------------------------
# ffmpeg for keyframe extraction and audio demux/downmix.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*

# --- Python packages (into the Hermes venv) ----------------------------------
# `requests` covers both Holo (OpenAI-compatible REST) and Gradium (plain REST).
# Skip heavy SDKs: the gradium SDK targets streaming; the openai SDK is
# unnecessary for two endpoints.
RUN uv pip install --python /opt/hermes/.venv/bin/python -U requests

# N2 note (verified 2026-07-11): the hosted-agent-platform executor uses the
# Streamable HTTP MCP client, but this image does NOT need to add it. The
# DEFAULT full Hermes image (what provision-sandbox.sh onboards — see that
# script's step 1) is built through NemoClaw's own hermes Dockerfile, which
# carries a build-time guard asserting `mcp._MCP_AVAILABLE` and
# `mcp_tool._MCP_HTTP_AVAILABLE`. `nemohermes <sandbox> mcp add` fails closed
# with rebuild guidance if that support is missing; ours passed (tools/list
# returned 6 tools over HTTPS), so HTTP-MCP is already present. This custom
# image remains unused by provisioning (it builds on the bare base and omits
# the agent-runtime layer — see provision-sandbox.sh header); kept only as the
# documented fallback if a future base image drops HTTP-MCP support.

# --- Fail the build early if anything is missing ------------------------------
RUN ffmpeg -version >/dev/null \
 && /opt/hermes/.venv/bin/python -c "import requests; import json, base64, wave"
