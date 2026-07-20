#!/bin/bash
# Removes offline self-hosted runners matching our name pattern from GHES.
# Called by entrypoint.sh before registration to clean up stale entries
# from previous sessions (e.g. after nightly server shutdown).
#
# Only removes runners whose name starts with RUNNER_NAME_BASE — so it
# never touches runners belonging to other teams or stacks.
#
# Required env vars:
#   ACCESS_TOKEN      — GitHub PAT with admin:org scope
#   GITHUB_HOST       — e.g. github.example.com
#   ORG_NAME          — e.g. your-org
#   RUNNER_NAME_BASE  — base name prefix e.g. runner-dev
#
# Standalone usage:
#   ENV_FILE=/deployment/GitHub/runner.env \
#   RUNNER_NAME_BASE=runner-dev \
#   ./cleanup-offline-runners.sh

set -euo pipefail

# Source env file only when running standalone
if [[ -z "${ACCESS_TOKEN:-}" ]]; then
  ENV_FILE="${ENV_FILE:-/deployment/GitHub/runner.env}"
  [[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; } \
    || { echo "ERROR: ACCESS_TOKEN not set and env file not found: $ENV_FILE"; exit 1; }
fi

: "${ACCESS_TOKEN:?ACCESS_TOKEN is required}"
: "${GITHUB_HOST:?GITHUB_HOST is required}"
: "${ORG_NAME:?ORG_NAME is required}"
: "${RUNNER_NAME_BASE:?RUNNER_NAME_BASE is required}"

API="https://${GITHUB_HOST}/api/v3"
PAGE=1
REMOVED=0

echo "[cleanup] Removing offline runners matching '${RUNNER_NAME_BASE}-*'..."

while true; do
  RESPONSE=$(curl -fsSL \
    -H "Authorization: token ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "${API}/orgs/${ORG_NAME}/actions/runners?per_page=100&page=${PAGE}")

  COUNT=$(echo "$RESPONSE" | jq '.runners | length')
  [[ "$COUNT" -eq 0 ]] && break

  # Only remove offline runners whose name starts with our base name.
  # This avoids touching runners from other teams or stacks.
  MATCHES=$(echo "$RESPONSE" | jq -r \
    --arg prefix "${RUNNER_NAME_BASE}-" \
    '.runners[] | select(.status=="offline" and (.name | startswith($prefix))) | "\(.id) \(.name)"')

  while IFS=' ' read -r ID NAME; do
    [[ -z "$ID" ]] && continue
    echo "[cleanup] Removing: ${NAME} (ID: ${ID})"
    curl -fsSL -XDELETE \
      -H "Authorization: token ${ACCESS_TOKEN}" \
      -H "Accept: application/vnd.github.v3+json" \
      "${API}/orgs/${ORG_NAME}/actions/runners/${ID}" || \
      echo "[cleanup] Warning: failed to remove runner ${ID}, skipping"
    REMOVED=$((REMOVED + 1))
  done <<< "$MATCHES"

  PAGE=$((PAGE + 1))
done

echo "[cleanup] Done. Removed ${REMOVED} offline runner(s) matching '${RUNNER_NAME_BASE}-*'."
