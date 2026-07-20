#!/bin/bash
# Exchanges a GitHub PAT (ACCESS_TOKEN) for a short-lived runner registration token.
# Prints the token string directly.
#
# Required env vars : ACCESS_TOKEN, RUNNER_SCOPE
# Scope-specific    : REPO_URL (repo) | ORG_NAME (org) | ENTERPRISE_NAME (enterprise)
# Optional          : GITHUB_HOST (defaults to github.com; set for GHES)

set -euo pipefail

HOST="${GITHUB_HOST:-github.com}"

# github.com uses api.github.com; GHES uses <host>/api/v3
if [[ "${HOST}" == "github.com" ]]; then
  API="https://api.${HOST}"
else
  API="https://${HOST}/api/v3"
fi

case "${RUNNER_SCOPE:-repo}" in
  org*)
    ENDPOINT="${API}/orgs/${ORG_NAME}/actions/runners/registration-token"
    ;;
  ent*)
    ENDPOINT="${API}/enterprises/${ENTERPRISE_NAME}/actions/runners/registration-token"
    ;;
  *)
    OWNER=$(echo "${REPO_URL}" | cut -d/ -f4)
    REPO=$(echo "${REPO_URL}"  | cut -d/ -f5)
    ENDPOINT="${API}/repos/${OWNER}/${REPO}/actions/runners/registration-token"
    ;;
esac

# Retry on transient failures (network blips, GHES 5xx). 3 attempts,
# short backoff. A bad PAT or wrong org name will still fail fast since
# those return 401/404 on every attempt - no point retrying those forever.
MAX_ATTEMPTS=3
ATTEMPT=1

: "${ACCESS_TOKEN:?ERROR: ACCESS_TOKEN env var is not set. Pass it through docker-compose.yml or docker run -e ACCESS_TOKEN=...}"

while (( ATTEMPT <= MAX_ATTEMPTS )); do
  HTTP_CODE=$(curl -sS -o /tmp/token_response.json -w "%{http_code}" -XPOST \
    -H "Authorization: token ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Length: 0" \
    "${ENDPOINT}" || echo "000")

  case "${HTTP_CODE}" in
    200|201)
      jq -r '.token' /tmp/token_response.json
      exit 0
      ;;
    401)
      echo "ERROR: 401 Unauthorized - ACCESS_TOKEN is invalid or expired." >&2
      exit 1
      ;;
    404)
      echo "ERROR: 404 Not Found - check RUNNER_SCOPE, ORG_NAME/REPO_URL/ENTERPRISE_NAME, and GITHUB_HOST are correct." >&2
      echo "       Endpoint tried: ${ENDPOINT}" >&2
      exit 1
      ;;
    000)
      echo "WARN: network error reaching ${HOST} (attempt ${ATTEMPT}/${MAX_ATTEMPTS})" >&2
      ;;
    *)
      echo "WARN: unexpected HTTP ${HTTP_CODE} from GitHub API (attempt ${ATTEMPT}/${MAX_ATTEMPTS})" >&2
      ;;
  esac

  (( ATTEMPT++ ))
  [[ ${ATTEMPT} -le ${MAX_ATTEMPTS} ]] && sleep $(( ATTEMPT * 2 ))
done

echo "ERROR: failed to get registration token after ${MAX_ATTEMPTS} attempts." >&2
exit 1