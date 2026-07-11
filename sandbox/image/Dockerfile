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

# Phase 2 (Sessions API replay via hosted MCP) will additionally need the
# streamable-HTTP MCP client — see H's demo Dockerfile. Not installed in v1.

# --- Fail the build early if anything is missing ------------------------------
RUN ffmpeg -version >/dev/null \
 && /opt/hermes/.venv/bin/python -c "import requests; import json, base64, wave"
