#!/usr/bin/env bash
# Run INSIDE the sandbox (nemohermes runbooks connect). Collects everything
# needed to figure out what serves the OpenAI-compatible API on 8642.
# Paste the full output back for analysis.
set -u

section() { printf '\n===== %s =====\n' "$*"; }

section "hermes subcommands"
hermes --help 2>&1

section "gateway subcommands (if any)"
hermes gateway --help 2>&1

section "listening TCP ports inside sandbox"
(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || cat /proc/net/tcp) | head -30

section "health probe on 8642 (inside)"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:8642/health 2>&1 || echo "no listener"

section "hermes config (api/port/gateway lines)"
grep -inE 'api|port|serve|gateway|8642|9119' /sandbox/.hermes/config.yaml 2>&1 | head -30

section "hermes processes"
ps aux 2>/dev/null | grep -i hermes | grep -v grep

section "hermes version"
hermes --version 2>&1
