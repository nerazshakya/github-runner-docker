#!/bin/bash
# Prints a short-lived runner registration token.
#
# Auth, in order of preference:
#   1. GitHub App : APP_ID + APP_INSTALLATION_ID + private key file
#                   (APP_KEY_FILE, default /run/secrets/gh_app_key)
#   2. PAT        : ACCESS_TOKEN
#
# Required env vars : RUNNER_SCOPE
# Scope-specific    : REPO_URL (repo) | ORG_NAME (org) | ENTERPRISE_NAME (enterprise)
# Optional          : GITHUB_HOST (defaults to github.com; set for GHES)

set -euo pipefail

HOST="${GITHUB_HOST:-github.com}"

# github.com uses api.github.com; GHES uses <host>/api/v3
if [[ "${HOST}" == "github.com" ]]; then
  API="https://api.github.com"
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

# Timeouts so a hung GHES cannot block container start forever.
CURL=(curl -sS --connect-timeout 10 --max-time 30)

# Response body goes to a private temp file that is always removed.
BODY=$(mktemp)
trap 'rm -f "${BODY}"' EXIT

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Mint a GitHub App installation token (valid 1 hour).
app_installation_token() {
  local key="${APP_KEY_FILE:-/run/secrets/gh_app_key}"
  [[ -r "${key}" ]] || { echo "ERROR: App key not readable: ${key}" >&2; return 1; }
  local now header payload sig
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "${APP_ID}" | b64url)
  sig=$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -sha256 -sign "${key}" | b64url)
  "${CURL[@]}" -f -XPOST \
    -H "Authorization: Bearer ${header}.${payload}.${sig}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/app/installations/${APP_INSTALLATION_ID}/access_tokens" | jq -r '.token'
}

if [[ -n "${APP_ID:-}" ]]; then
  : "${APP_INSTALLATION_ID:?ERROR: APP_INSTALLATION_ID is required when APP_ID is set}"
  AUTH_TOKEN=$(app_installation_token)
  [[ -n "${AUTH_TOKEN}" && "${AUTH_TOKEN}" != "null" ]] \
    || { echo "ERROR: could not get an App installation token." >&2; exit 1; }
else
  : "${ACCESS_TOKEN:?ERROR: set ACCESS_TOKEN (PAT), or APP_ID + APP_INSTALLATION_ID + key file}"
  AUTH_TOKEN="${ACCESS_TOKEN}"
fi

gh_msg() { jq -r '.message // empty' "${BODY}" 2>/dev/null || true; }

# Retry only on transient failures (network, 5xx). 401/403/404 are config
# problems and fail fast.
MAX_ATTEMPTS=3
ATTEMPT=1

while (( ATTEMPT <= MAX_ATTEMPTS )); do
  HTTP_CODE=$("${CURL[@]}" -o "${BODY}" -w '%{http_code}' -XPOST \
    -H "Authorization: token ${AUTH_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Length: 0" \
    "${ENDPOINT}") || HTTP_CODE=000

  case "${HTTP_CODE}" in
    200|201)
      jq -r '.token' "${BODY}"
      exit 0
      ;;
    401)
      echo "ERROR: 401 Unauthorized - credential is invalid or expired. $(gh_msg)" >&2
      exit 1
      ;;
    403)
      echo "ERROR: 403 Forbidden - not an org owner / missing permission / SSO not authorized? $(gh_msg)" >&2
      exit 1
      ;;
    404)
      echo "ERROR: 404 Not Found - check RUNNER_SCOPE, ORG_NAME/REPO_URL/ENTERPRISE_NAME and GITHUB_HOST." >&2
      echo "       Endpoint tried: ${ENDPOINT}  $(gh_msg)" >&2
      exit 1
      ;;
    000)
      echo "WARN: network error reaching ${HOST} (attempt ${ATTEMPT}/${MAX_ATTEMPTS})" >&2
      ;;
    *)
      echo "WARN: HTTP ${HTTP_CODE} from GitHub API (attempt ${ATTEMPT}/${MAX_ATTEMPTS}). $(gh_msg)" >&2
      ;;
  esac

  (( ATTEMPT++ ))
  [[ ${ATTEMPT} -le ${MAX_ATTEMPTS} ]] && sleep $(( ATTEMPT * 2 ))
done

echo "ERROR: failed to get registration token after ${MAX_ATTEMPTS} attempts." >&2
exit 1