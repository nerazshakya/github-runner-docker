#!/bin/bash
# Container entrypoint:
#   1. (persistent mode only) Clean up offline runners
#   2. Get a runner registration token (GitHub App if APP_ID is set, else PAT)
#   3. Register the runner with GitHub
#   4. Run jobs: forever when EPHEMERAL!=true, one job then exit when EPHEMERAL=true
#      (the orchestrator's restart policy then starts a fresh container)
#   5. Deregister cleanly on SIGINT/SIGTERM/SIGQUIT or listener exit
#
# Token lifecycle: the registration token is fetched fresh on every container
# start and used once; deregistration fetches a fresh remove token. Nothing is
# stored on disk by this script.

set -euo pipefail

export RUNNER_ALLOW_RUNASROOT=1
export PATH="${PATH}:/actions-runner"

# Keep credentials out of child process environments
export -n ACCESS_TOKEN RUNNER_TOKEN

# GitHub App auth is used when APP_ID is set (see token.sh), otherwise the PAT.
# The App private key is read from a file (secret / read-only mount), never from env.
HAVE_API_AUTH=false
[[ -n "${ACCESS_TOKEN:-}" || -n "${APP_ID:-}" ]] && HAVE_API_AUTH=true

# ---------------------------------------------------------------------------
# Config - read from env with sensible defaults
# ---------------------------------------------------------------------------
GITHUB_HOST="${GITHUB_HOST:-github.com}"
GITHUB_HOST="${GITHUB_HOST#*://}"   # strip any http:// or https:// prefix
GITHUB_HOST="${GITHUB_HOST%%/}"     # strip trailing slash
export GITHUB_HOST

RUNNER_SCOPE="${RUNNER_SCOPE:-repo}"
RUNNER_SCOPE="${RUNNER_SCOPE,,}"    # lowercase
export RUNNER_SCOPE

RUNNER_NAME_BASE="${RUNNER_NAME:-runner}"
RUNNER_NAME="${RUNNER_NAME_BASE}-$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/_work}"
LABELS="${LABELS:-default}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
EPHEMERAL="${EPHEMERAL:-false}"

# Resolve the GitHub URL the runner registers against
case "${RUNNER_SCOPE}" in
  org*)
    [[ -z "${ORG_NAME:-}" ]] && { echo "ERROR: ORG_NAME required for org scope"; exit 1; }
    GITHUB_URL="https://${GITHUB_HOST}/${ORG_NAME}"
    ;;
  ent*)
    [[ -z "${ENTERPRISE_NAME:-}" ]] && { echo "ERROR: ENTERPRISE_NAME required for enterprise scope"; exit 1; }
    GITHUB_URL="https://${GITHUB_HOST}/enterprises/${ENTERPRISE_NAME}"
    ;;
  *)
    [[ -z "${REPO_URL:-}" ]] && { echo "ERROR: REPO_URL required for repo scope"; exit 1; }
    GITHUB_URL="${REPO_URL}"
    ;;
esac

# token.sh needs the credentials, which were un-exported above, so pass them
# explicitly for each call.
token() {
  ACCESS_TOKEN="${ACCESS_TOKEN:-}" bash /token.sh "$@"
}

# ---------------------------------------------------------------------------
# Deregister runner (clean shutdown). Runs at most once.
# ---------------------------------------------------------------------------
REGISTERED=false
DEREGISTERED=false
CHILD=""

deregister() {
  [[ "${REGISTERED}" == "true" && "${DEREGISTERED}" == "false" ]] || return 0
  DEREGISTERED=true
  echo "[runner] Deregistering..."
  local tok=""
  if [[ "${HAVE_API_AUTH}" == "true" ]]; then
    # A failed token fetch must not abort the handler under set -e
    tok=$(token remove) || tok=""
  fi
  [[ -z "${tok}" ]] && tok="${RUNNER_TOKEN:-}"
  if [[ -z "${tok}" ]]; then
    echo "[runner] No token available to deregister; remove the runner in GitHub if it lingers."
    return 0
  fi
  (cd /actions-runner && ./config.sh remove --token "${tok}") || true
}

on_signal() {
  trap '' INT TERM QUIT
  echo "[runner] Signal received, stopping listener..."
  if [[ -n "${CHILD}" ]]; then
    kill -TERM "${CHILD}" 2>/dev/null || true
    wait "${CHILD}" 2>/dev/null || true
  fi
  deregister
  exit 143
}
trap on_signal INT TERM QUIT

# ---------------------------------------------------------------------------
# Cleanup offline runners before registering (PERSISTENT MODE, ORG SCOPE ONLY)
# Prevents ghost entries accumulating after abrupt kills / host restarts.
# Works with a PAT or a GitHub App (cleanup-offline-runners.sh calls token.sh auth).
# Skipped for ephemeral runners: they deregister themselves, GitHub removes
# stale ones, and a sibling replica that has registered but not yet connected
# looks "offline", so this cleanup could delete a healthy runner.
# Failures are non-fatal - a cleanup error should never block registration.
# ---------------------------------------------------------------------------
if [[ "${EPHEMERAL}" != "true" \
   && "${HAVE_API_AUTH}" == "true" && "${RUNNER_SCOPE}" == org* && -n "${ORG_NAME:-}" ]]; then
  echo "[runner] Cleaning up offline runners matching '${RUNNER_NAME_BASE}-*'..."
  ACCESS_TOKEN="${ACCESS_TOKEN:-}" \
  ORG_NAME="${ORG_NAME}" \
  RUNNER_NAME_BASE="${RUNNER_NAME_BASE}" \
  bash /cleanup-offline-runners.sh || echo "[runner] Cleanup failed (non-fatal), continuing..."
fi

# ---------------------------------------------------------------------------
# Get a registration token
# ---------------------------------------------------------------------------
if [[ "${HAVE_API_AUTH}" == "true" ]]; then
  echo "[runner] Fetching registration token..."
  RUNNER_TOKEN=$(token registration) || {
    echo "ERROR: could not get a registration token (see message above)."
    exit 1
  }
fi

[[ -z "${RUNNER_TOKEN:-}" ]] && {
  echo "ERROR: Set APP_ID (+ APP_INSTALLATION_ID + key file), ACCESS_TOKEN (PAT) or RUNNER_TOKEN"
  exit 1
}

# ---------------------------------------------------------------------------
# Register the runner
# ---------------------------------------------------------------------------
echo "[runner] Registering '${RUNNER_NAME}' -> ${GITHUB_URL}"

EXTRA_ARGS=()
# Only run ephemeral (exit after one job) when EPHEMERAL is explicitly "true".
# Any other value (unset, "false", empty, typo, etc.) runs the listener forever.
[[ "${EPHEMERAL}" == "true" ]] && EXTRA_ARGS+=("--ephemeral")
# Only disable auto-update when DISABLE_AUTO_UPDATE is explicitly "true".
[[ "${DISABLE_AUTO_UPDATE:-false}" == "true" ]] && EXTRA_ARGS+=("--disableupdate")
# Runner groups exist only at org/enterprise level.
[[ "${RUNNER_SCOPE}" == org* || "${RUNNER_SCOPE}" == ent* ]] && EXTRA_ARGS+=("--runnergroup" "${RUNNER_GROUP}")

mkdir -p "${RUNNER_WORKDIR}"

/actions-runner/config.sh \
  --url         "${GITHUB_URL}" \
  --token       "${RUNNER_TOKEN}" \
  --name        "${RUNNER_NAME}" \
  --work        "${RUNNER_WORKDIR}" \
  --labels      "${LABELS}" \
  --unattended \
  --replace \
  "${EXTRA_ARGS[@]}"
REGISTERED=true

echo "[runner] Registered. Starting listener..."

# ---------------------------------------------------------------------------
# Run the listener (CMD) as a child so the signal trap fires immediately and
# we can deregister after it exits.
# ---------------------------------------------------------------------------
"$@" &
CHILD=$!
RC=0
wait "${CHILD}" || RC=$?
CHILD=""

# An ephemeral runner that finished its job (exit 0) is already removed by
# GitHub. Any other exit (persistent runner stopped, crash, failure) leaves a
# registration behind, so remove it.
if [[ "${EPHEMERAL}" == "true" && "${RC}" -eq 0 ]]; then
  echo "[runner] Ephemeral job finished."
else
  deregister
fi
exit "${RC}"
