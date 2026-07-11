#!/usr/bin/env bash
# Milestone B negative test: prove the deny-by-default boundary.
#
# Run inside the sandbox. A non-allowlisted host must be UNREACHABLE.
# This is the security demo money-shot: recordings physically cannot leave
# the box except to the allowlisted endpoints.
set -u

echo "egress negative test: attempting https://example.com (must fail)..."
if python3 - <<'EOF'
import requests, sys
try:
    requests.get("https://example.com", timeout=10)
    sys.exit(0)   # reached it -> BAD
except Exception:
    sys.exit(1)   # blocked -> GOOD
EOF
then
  echo "FAIL: sandbox reached a non-allowlisted host — egress policy is broken"
  exit 1
else
  echo "OK: non-allowlisted egress blocked (check 'openshell term' on the host for the denial log)"
fi
