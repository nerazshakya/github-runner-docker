#!/usr/bin/env bash
# Works out which runner version to install and which extra image tag (if any)
# to publish. Called by release-runner.yml.
#
# Runner version, first match wins:
#   1. REQUESTED   manual dispatch input
#   2. PINNED      repo variable RUNNER_VERSION
#   3. latest      newest actions/runner release (looked up on github.com)
#
# RELEASE_TAG (the tag of the GitHub release that triggered the run, e.g. v1.4.0)
# is NOT the runner version: it becomes an extra image tag, so release v1.4.0
# publishes <image>:<runner-version>, :latest, :sha-<commit> and :v1.4.0.
#
# Outputs (written to $GITHUB_OUTPUT, or printed when run by hand):
#   version      runner version, e.g. 2.324.0
#   extra_tag    sanitized release tag, or empty
#
# Env: REQUESTED, PINNED, RELEASE_TAG (all optional)
set -euo pipefail

out="${GITHUB_OUTPUT:-/dev/stdout}"
version="${REQUESTED:-${PINNED:-latest}}"

if [[ "${version}" == "latest" ]]; then
  version=$(curl -fsS --max-time 30 https://api.github.com/repos/actions/runner/releases/latest \
              | jq -r '.tag_name // empty') || version=""
  version="${version#v}"
  [[ -n "${version}" ]] || {
    echo "Could not look up the latest runner release. Set the RUNNER_VERSION variable (e.g. 2.324.0)." >&2
    exit 1
  }
fi

[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Invalid runner version '${version}' (want e.g. 2.324.0)." >&2
  exit 1
}

# Docker tags: [A-Za-z0-9_.-], max 128 chars, must not start with '.' or '-'.
extra_tag="${RELEASE_TAG:-}"
extra_tag="${extra_tag//[^A-Za-z0-9_.-]/-}"
extra_tag="${extra_tag#"${extra_tag%%[!.-]*}"}"
extra_tag="${extra_tag:0:128}"
[[ "${extra_tag}" == "${version}" || "${extra_tag}" == "latest" ]] && extra_tag=""

echo "Runner version: ${version}" >&2
echo "Extra image tag: ${extra_tag:-<none>}" >&2
{
  echo "version=${version}"
  echo "extra_tag=${extra_tag}"
} >> "${out}"
