#!/bin/bash
# Container entrypoint:
#   1. (persistent mode only) Clean up offline runners from GHES
#   2. Get a runner registration token (GitHub App if APP_ID is set, else PAT)
#   3. Register the runner with GitHub
#   4. Run jobs: forever when EPHEMERAL!=true, one job then exit when EPHEMERAL=true
#      (Swarm restart_policy "any" then starts a fresh container)
#   5. Deregister cleanly on SIGINT/SIGTERM/SIGQUIT

set -euo pipefail

export RUNNER_ALLOW_RUNASROOT=1
export PATH="${PATH}:/actions-runner"

# Keep credentials out of child process environments
export -n ACCESS_TOKEN RUNNER_TOKEN

# GitHub App auth is used when APP_ID is set (see token.sh), otherwise the PAT.
# The App private key is read from a file (Swarm secret), never from env.
HAVE_API_AUTH=false
[[ -n "${ACCESS_TOKEN:-}" || -n "${APP_ID:-}" ]] && HAVE_API_AUTH=true

# ---------------------------------------------------------------------------
# Config — read from env with sensible defaults
# ---------------------------------------------------------------------------
GITHUB_HOST="${GITHUB_HOST:-github.com}"
GITHUB_HOST="${GITHUB_HOST#*://}"   # strip any http:// or https:// prefix
GITHUB_HOST="${GITHUB_HOST%%/}"     # strip trailing slash

RUNNER_SCOPE="${RUNNER_SCOPE:-repo}"
RUNNER_SCOPE="${RUNNER_SCOPE,,}"    # lowercase

RUNNER_NAME_BASE="${RUNNER_NAME:-runner}"
RUNNER_NAME="${RUNNER_NAME_BASE}-$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/_work}"
LABELS="${LABELS:-default}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"

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

# ---------------------------------------------------------------------------
# Deregister runner on container exit (clean shutdown)
# ---------------------------------------------------------------------------
deregister() {
  echo "[runner] Deregistering..."
  local tok="${RUNNER_TOKEN:-}"
  if [[ "${HAVE_API_AUTH}" == "true" ]]; then
    # A failed token fetch must not abort the trap under set -e
    tok=$(ACCESS_TOKEN="${ACCESS_TOKEN:-}" bash /token.sh) || tok="${RUNNER_TOKEN:-}"
  fi
  (cd /actions-runner && ./config.sh remove --token "${tok}") || true
}
trap 'deregister' INT TERM QUIT

# ---------------------------------------------------------------------------
# Cleanup offline runners from GHES before registering (PERSISTENT MODE ONLY)
# Prevents ghost entries accumulating after nightly server restarts.
# Only runs when ACCESS_TOKEN (PAT) and ORG_NAME are available (org scope).
# Skipped for ephemeral runners: they deregister themselves, GitHub removes
# stale ones, and a sibling replica that has registered but not yet connected
# looks "offline", so this cleanup could delete a healthy runner.
# Failures are non-fatal — a cleanup error should never block registration.
# ---------------------------------------------------------------------------
if [[ "${EPHEMERAL:-false}" != "true" \
   && -n "${ACCESS_TOKEN:-}" && "${RUNNER_SCOPE}" == org* && -n "${ORG_NAME:-}" ]]; then
  echo "[runner] Cleaning up offline runners matching '${RUNNER_NAME_BASE}-*'..."
  ACCESS_TOKEN="${ACCESS_TOKEN}" \
  GITHUB_HOST="${GITHUB_HOST}" \
  ORG_NAME="${ORG_NAME}" \
  RUNNER_NAME_BASE="${RUNNER_NAME_BASE}" \
  bash /cleanup-offline-runners.sh || echo "[runner] Cleanup failed (non-fatal), continuing..."
fi

# ---------------------------------------------------------------------------
# Get a registration token
# ---------------------------------------------------------------------------
if [[ "${HAVE_API_AUTH}" == "true" ]]; then
  echo "[runner] Fetching registration token..."
  RUNNER_TOKEN=$(ACCESS_TOKEN="${ACCESS_TOKEN:-}" bash /token.sh)
fi

[[ -z "${RUNNER_TOKEN:-}" ]] && {
  echo "ERROR: Set APP_ID (+ APP_INSTALLATION_ID + key secret), ACCESS_TOKEN (PAT) or RUNNER_TOKEN"
  exit 1
}

# ---------------------------------------------------------------------------
# Register the runner
# ---------------------------------------------------------------------------
echo "[runner] Registering '${RUNNER_NAME}' → ${GITHUB_URL}"

EXTRA_ARGS=()
# Only run ephemeral (exit after one job) when EPHEMERAL is explicitly "true".
# Any other value (unset, "false", empty, typo, etc.) runs the listener forever.
[[ "${EPHEMERAL:-false}" == "true" ]] && EXTRA_ARGS+=("--ephemeral")
# Only disable auto-update when DISABLE_AUTO_UPDATE is explicitly "true".
# Any other value (unset, "false", empty, typo, etc.) leaves auto-update on.
[[ "${DISABLE_AUTO_UPDATE:-false}" == "true" ]] && EXTRA_ARGS+=("--disableupdate")

mkdir -p "${RUNNER_WORKDIR}"

/actions-runner/config.sh \
  --url         "${GITHUB_URL}" \
  --token       "${RUNNER_TOKEN}" \
  --name        "${RUNNER_NAME}" \
  --work        "${RUNNER_WORKDIR}" \
  --labels      "${LABELS}" \
  --runnergroup "${RUNNER_GROUP}" \
  --unattended \
  --replace \
  "${EXTRA_ARGS[@]}"

echo "[runner] Registered. Starting listener..."

# ---------------------------------------------------------------------------
# Hand off to CMD (Runner.Listener)
# ---------------------------------------------------------------------------
"$@"