#!/usr/bin/env bash
# Works out which runner version to install and which extra image tag (if any)
# to publish. Called by release-runner.yml.
#
# Runner version, first match wins:
#   1. REQUESTED     manual dispatch input
#   2. RELEASE_TAG   when the GitHub release tag is a version like 2.338.0 or
#                    v2.338.0, that IS the runner version to build
#   3. PINNED        repo variable RUNNER_VERSION
#   4. latest        newest actions/runner release (looked up on github.com)
#
# A release tag that is not a version (e.g. "stable-1") does not select the
# runner version; it is published as an extra image tag instead.
#
# Outputs (written to $GITHUB_OUTPUT, or printed when run by hand):
#   version      runner version, e.g. 2.338.0
#   extra_tag    sanitized release tag when it differs from the version, else empty
#
# Env: REQUESTED, PINNED, RELEASE_TAG (all optional)
set -euo pipefail

out="${GITHUB_OUTPUT:-/dev/stdout}"
semver='^[0-9]+\.[0-9]+\.[0-9]+$'
tag_version="${RELEASE_TAG:-}"; tag_version="${tag_version#v}"

if   [[ -n "${REQUESTED:-}" ]];         then version="${REQUESTED}"
elif [[ "${tag_version}" =~ ${semver} ]]; then version="${tag_version}"
else                                         version="${PINNED:-latest}"
fi

if [[ "${version}" == "latest" ]]; then
  version=$(curl -fsS --max-time 30 https://api.github.com/repos/actions/runner/releases/latest \
              | jq -r '.tag_name // empty') || version=""
  version="${version#v}"
  [[ -n "${version}" ]] || {
    echo "Could not look up the latest runner release. Set the RUNNER_VERSION variable (e.g. 2.324.0)." >&2
    exit 1
  }
fi

[[ "${version}" =~ ${semver} ]] || {
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
