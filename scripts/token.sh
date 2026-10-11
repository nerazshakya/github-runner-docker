#!/bin/bash
# Prints a short-lived GitHub token for runner lifecycle operations.
#
# Usage: token.sh [registration|remove|auth|check]
#   registration  (default) print a runner registration token (valid 1 hour)
#   remove        print a runner remove token (used to deregister)
#   auth          print the API credential itself: a freshly minted GitHub App
#                 installation token (valid 1 hour) or the PAT. Used by the
#                 offline-runner cleanup. Never log this value.
#   check         request a registration token, discard it, print "OK ..."
#                 (used by deploy.sh to verify credentials before deploying)
#
# Auth, in order of preference:
#   1. GitHub App : APP_ID + APP_INSTALLATION_ID + private key file
#                   (APP_KEY_FILE, default /run/secrets/gh_app_key)
#   2. PAT        : ACCESS_TOKEN
#
# Required env vars : RUNNER_SCOPE (repo | org | enterprise)
# Scope-specific    : REPO_URL (repo) | ORG_NAME (org) | ENTERPRISE_NAME (enterprise)
# Optional          : GITHUB_HOST    (default github.com; set for GHES)
#                     GITHUB_API_URL (override the API base, e.g. a proxy)
#
# Nothing is cached: every call mints fresh credentials, so a token never
# outlives the operation it was minted for. Secrets are passed to curl on
# stdin, not on the command line, so they do not show up in `ps`.

set -euo pipefail

MODE="${1:-registration}"
case "${MODE}" in
  registration|remove|auth|check) ;;
  *) echo "Usage: $0 [registration|remove|auth|check]" >&2; exit 2 ;;
esac

HOST="${GITHUB_HOST:-github.com}"

# github.com uses api.github.com; GHES uses <host>/api/v3
if [[ -n "${GITHUB_API_URL:-}" ]]; then
  API="${GITHUB_API_URL%/}"
elif [[ "${HOST}" == "github.com" ]]; then
  API="https://api.github.com"
else
  API="https://${HOST}/api/v3"
fi

# Timeouts so a hung server cannot block container start forever.
CURL=(curl -sS --connect-timeout 10 --max-time 30)

# Response body goes to a private temp file that is always removed.
BODY=$(mktemp)
trap 'rm -f "${BODY}"' EXIT

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
gh_msg() { jq -r '.message // empty' "${BODY}" 2>/dev/null || true; }

MAX_ATTEMPTS=3

# request METHOD URL AUTH_SCHEME CREDENTIAL HINT_401
# Retries only transient failures (network, 5xx). 401/403/404 are
# configuration problems and fail fast. Body is left in ${BODY}.
request() {
  local method="$1" url="$2" scheme="$3" cred="$4" hint401="$5"
  local attempt=1 code
  while (( attempt <= MAX_ATTEMPTS )); do
    code=$(printf 'header = "Authorization: %s %s"\n' "${scheme}" "${cred}" \
      | "${CURL[@]}" -K - -o "${BODY}" -w '%{http_code}' -X "${method}" \
          -H "Accept: application/vnd.github+json" \
          -H "Content-Length: 0" \
          "${url}") || code=000
    case "${code}" in
      200|201) return 0 ;;
      401) echo "ERROR: 401 Unauthorized - ${hint401} $(gh_msg)" >&2; return 1 ;;
      403) echo "ERROR: 403 Forbidden - missing permission, not an org owner, or SSO not authorized for the PAT? $(gh_msg)" >&2; return 1 ;;
      404) echo "ERROR: 404 Not Found - check RUNNER_SCOPE, ORG_NAME/REPO_URL/ENTERPRISE_NAME, GITHUB_HOST," >&2
           echo "       and that the App is installed on that org/repo. URL: ${url}  $(gh_msg)" >&2; return 1 ;;
      000) echo "WARN: network error reaching ${url} (attempt ${attempt}/${MAX_ATTEMPTS})" >&2 ;;
      *)   echo "WARN: HTTP ${code} from ${url} (attempt ${attempt}/${MAX_ATTEMPTS}). $(gh_msg)" >&2 ;;
    esac
    attempt=$(( attempt + 1 ))
    (( attempt <= MAX_ATTEMPTS )) && sleep $(( attempt * 2 ))
  done
  echo "ERROR: ${method} ${url} failed after ${MAX_ATTEMPTS} attempts." >&2
  return 1
}

# Mint a GitHub App installation token (valid 1 hour).
# The signed JWT is valid 9 minutes and is used only for this one call.
app_installation_token() {
  local key="${APP_KEY_FILE:-/run/secrets/gh_app_key}"
  [[ -r "${key}" ]] || { echo "ERROR: App private key not readable: ${key}" >&2; return 1; }
  local now header payload sig
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "${APP_ID}" | b64url)
  sig=$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -sha256 -sign "${key}" | b64url) \
    || { echo "ERROR: could not sign the App JWT - is ${key} a valid RSA private key (PEM)?" >&2; return 1; }
  request POST "${API}/app/installations/${APP_INSTALLATION_ID}/access_tokens" \
    Bearer "${header}.${payload}.${sig}" \
    "App JWT rejected: check APP_ID, the private key, and that this host's clock is correct." || return 1
  jq -r '.token // empty' "${BODY}"
}

if [[ -n "${APP_ID:-}" ]]; then
  : "${APP_INSTALLATION_ID:?ERROR: APP_INSTALLATION_ID is required when APP_ID is set}"
  AUTH_TOKEN=$(app_installation_token) || exit 1
  [[ -n "${AUTH_TOKEN}" ]] || { echo "ERROR: could not get an App installation token." >&2; exit 1; }
  AUTH_KIND="github-app"
else
  : "${ACCESS_TOKEN:?ERROR: set ACCESS_TOKEN (PAT), or APP_ID + APP_INSTALLATION_ID + key file}"
  AUTH_TOKEN="${ACCESS_TOKEN}"
  AUTH_KIND="pat"
fi

if [[ "${MODE}" == "auth" ]]; then
  printf '%s\n' "${AUTH_TOKEN}"
  exit 0
fi

case "${RUNNER_SCOPE:-repo}" in
  org*)
    : "${ORG_NAME:?ERROR: ORG_NAME is required for org scope}"
    BASE="${API}/orgs/${ORG_NAME}/actions/runners"
    ;;
  ent*)
    : "${ENTERPRISE_NAME:?ERROR: ENTERPRISE_NAME is required for enterprise scope}"
    BASE="${API}/enterprises/${ENTERPRISE_NAME}/actions/runners"
    ;;
  *)
    : "${REPO_URL:?ERROR: REPO_URL is required for repo scope}"
    path="${REPO_URL%/}"; path="${path%.git}"
    REPO=$(basename "${path}"); OWNER=$(basename "$(dirname "${path}")")
    BASE="${API}/repos/${OWNER}/${REPO}/actions/runners"
    ;;
esac

case "${MODE}" in
  remove) ENDPOINT="${BASE}/remove-token" ;;
  *)      ENDPOINT="${BASE}/registration-token" ;;
esac

request POST "${ENDPOINT}" token "${AUTH_TOKEN}" \
  "credential is invalid or expired (PAT expired/revoked, or App key/ID wrong)." || exit 1

TOKEN=$(jq -r '.token // empty' "${BODY}")
[[ -n "${TOKEN}" ]] || { echo "ERROR: response from ${ENDPOINT} contained no token." >&2; exit 1; }

if [[ "${MODE}" == "check" ]]; then
  echo "OK: ${AUTH_KIND} credential can create runner tokens (${RUNNER_SCOPE:-repo} scope, ${HOST})"
else
  printf '%s\n' "${TOKEN}"
fi
