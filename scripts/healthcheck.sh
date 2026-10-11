#!/bin/bash
# Health check for the GitHub Actions runner container.
# Passes if Runner.Listener is running. Used by Docker HEALTHCHECK
# and by Swarm to detect and restart dead runners automatically.

set -euo pipefail

if pgrep -f "Runner.Listener" > /dev/null 2>&1; then
  exit 0
fi

echo "[healthcheck] Runner.Listener process not found"
exit 1