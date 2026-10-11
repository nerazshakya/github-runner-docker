#!/bin/bash
# Removes offline self-hosted runners matching our name pattern from an org.
# Called by entrypoint.sh before registration (persistent mode) to clean up
# stale entries from previous sessions (e.g. after a host crash).
#
# Only removes runners whose name starts with "${RUNNER_NAME_BASE}-", so it
# never touches runners belonging to other teams or stacks.
#
# Auth comes from token.sh: a GitHub App installation token when APP_ID is set,
# otherwise ACCESS_TOKEN (needs permission to manage org runners).
#
# Required env vars:
#   ORG_NAME          e.g. your-org
#   RUNNER_NAME_BASE  base name prefix e.g. dev-runner
#   ACCESS_TOKEN or APP_ID + APP_INSTALLATION_ID (+ key file)
# Optional:
#   GITHUB_HOST       default github.com; set for GHES
#   GITHUB_API_URL    override the API base
#
# Standalone usage:
#   ENV_FILE=/etc/gh-runner/runner.env RUNNER_NAME_BASE=dev-runner ./cleanup-offline-runners.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_SH="${TOKEN_SH:-/token.sh}"
[[ -f "${TOKEN_SH}" ]] || TOKEN_SH="${HERE}/token.sh"

# Source env file only when running standalone without credentials
if [[ -z "${ACCESS_TOKEN:-}" && -z "${APP_ID:-}" ]]; then
  ENV_FILE="${ENV_FILE:-/etc/gh-runner/runner.env}"
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  else
    echo "ERROR: no credentials in env and env file not found: ${ENV_FILE}" >&2
    exit 1
  fi
fi

: "${ORG_NAME:?ORG_NAME is required}"
: "${RUNNER_NAME_BASE:?RUNNER_NAME_BASE is required}"

HOST="${GITHUB_HOST:-github.com}"
if [[ -n "${GITHUB_API_URL:-}" ]]; then
  API="${GITHUB_API_URL%/}"
elif [[ "${HOST}" == "github.com" ]]; then
  API="https://api.github.com"
else
  API="https://${HOST}/api/v3"
fi

AUTH=$(RUNNER_SCOPE=org bash "${TOKEN_SH}" auth)
CURL=(curl -fsS --connect-timeout 10 --max-time 30)
# Credentials go to curl on stdin so they do not appear in `ps`.
gh() { # METHOD URL
  printf 'header = "Authorization: token %s"\n' "${AUTH}" \
    | "${CURL[@]}" -K - -X "$1" -H "Accept: application/vnd.github+json" "$2"
}

echo "[cleanup] Removing offline runners matching '${RUNNER_NAME_BASE}-*'..."

# Collect first, delete afterwards, so paging is not disturbed by deletes.
FOUND=$(mktemp); trap 'rm -f "${FOUND}"' EXIT
PAGE=1
while true; do
  RESPONSE=$(gh GET "${API}/orgs/${ORG_NAME}/actions/runners?per_page=100&page=${PAGE}")
  [[ "$(jq '.runners | length' <<<"${RESPONSE}")" -eq 0 ]] && break
  jq -r --arg prefix "${RUNNER_NAME_BASE}-" \
    '.runners[] | select(.status=="offline" and (.name | startswith($prefix))) | "\(.id) \(.name)"' \
    <<<"${RESPONSE}" >> "${FOUND}"
  PAGE=$((PAGE + 1))
done

REMOVED=0
while read -r ID NAME; do
  [[ -z "${ID}" ]] && continue
  echo "[cleanup] Removing: ${NAME} (ID: ${ID})"
  if gh DELETE "${API}/orgs/${ORG_NAME}/actions/runners/${ID}" >/dev/null; then
    REMOVED=$((REMOVED + 1))
  else
    echo "[cleanup] Warning: failed to remove runner ${ID}, skipping"
  fi
done < "${FOUND}"

echo "[cleanup] Done. Removed ${REMOVED} offline runner(s) matching '${RUNNER_NAME_BASE}-*'."
