#!/usr/bin/env bash
# Builds, checks and (optionally) publishes the runner image.
# Called by build-runner-image.yml. Steps, in order:
#   1. work out the image name and tags (Docker Hub by default, or a custom registry)
#   2. log in to the registry              (only when PUSH=true; always logs out)
#   3. docker build                        (GHES download token passed as a BuildKit secret)
#   4. fail if a GitHub token is in the image history
#   5. smoke test the image
#   6. docker push every tag               (only when PUSH=true)
#
# Env:
#   RUNNER_VERSION   runner version to install and tag with (required)
#   PUSH             true = log in and push, anything else = build and test only
#   EXTRA_TAG        optional extra tag, e.g. the release tag v1.4.0
#   REGISTRY         empty or docker.io = Docker Hub, else registry host
#   IMAGE_NAME       optional, e.g. myorg/github-runner (default <REGISTRY_USER>/github-runner)
#   REGISTRY_USER    registry username (required to push)
#   REGISTRY_TOKEN   registry access token (required to push)
#   GH_HOST, ORG     GHES only: host to download the runner from, and its org
#   GITHUB_PAT       GHES only: token for that download (BuildKit secret, never a build arg)
#   REQUIRE_CHECKSUM  true = fail the build if the runner download cannot be verified
#   SOURCE_URL, REVISION, GITHUB_SHA   used for image labels and the sha tag
set -euo pipefail

: "${RUNNER_VERSION:?RUNNER_VERSION is required}"
: "${GITHUB_SHA:=local}"
PUSH="${PUSH:-false}"
export DOCKER_BUILDKIT=1

# --- 1. image name and tags -------------------------------------------------
name="${IMAGE_NAME:-${REGISTRY_USER:+${REGISTRY_USER}/}github-runner}"
name="${name,,}"                                   # registries require lowercase
registry="${REGISTRY:-}"; registry="${registry#https://}"; registry="${registry%/}"
case "${registry}" in
  ""|docker.io|index.docker.io|registry-1.docker.io) image="${name}"; login_host="" ;;
  *) image="${registry}/${name}"; login_host="${registry}" ;;
esac

tags="${RUNNER_VERSION} latest sha-${GITHUB_SHA:0:7}"
[[ -n "${EXTRA_TAG:-}" ]] && tags="${tags} ${EXTRA_TAG}"
echo "Image: ${image}  Tags: ${tags}"

# --- 2. registry login (always log out afterwards) --------------------------
if [[ "${PUSH}" == "true" ]]; then
  : "${REGISTRY_USER:?DOCKER_REGISTRY_USER variable is not set (needed to push)}"
  [[ -n "${REGISTRY_TOKEN:-}" ]] || { echo "DOCKER_REGISTRY_TOKEN secret is not set." >&2; exit 1; }
  # LOGIN_HOST is unquoted on purpose: empty means no argument (Docker Hub)
  trap 'docker logout ${login_host} >/dev/null 2>&1 || true' EXIT
  echo "${REGISTRY_TOKEN}" | docker login ${login_host} -u "${REGISTRY_USER}" --password-stdin
fi

# --- 3. build ---------------------------------------------------------------
args=(--no-cache -f docker/Dockerfile
      --build-arg "GH_RUNNER_VERSION=${RUNNER_VERSION}"
      --label "org.opencontainers.image.title=github-actions-runner"
      --label "org.opencontainers.image.version=${RUNNER_VERSION}"
      --label "org.opencontainers.image.source=${SOURCE_URL:-}"
      --label "org.opencontainers.image.revision=${REVISION:-}")

[[ -n "${REQUIRE_CHECKSUM:-}" ]] && args+=(--build-arg "REQUIRE_CHECKSUM=${REQUIRE_CHECKSUM}")

if [[ -n "${GH_HOST:-}" ]]; then
  [[ -n "${ORG:-}" ]]        || { echo "org_name is required when github_host is set" >&2; exit 1; }
  [[ -n "${GITHUB_PAT:-}" ]] || { echo "GH_PAT is required for a GHES build" >&2; exit 1; }
  args+=(--build-arg "GITHUB_HOST=${GH_HOST}" --build-arg "ORG_NAME=${ORG}"
         --secret "id=gh_pat,env=GITHUB_PAT")
fi
for tag in ${tags}; do args+=(-t "${image}:${tag}"); done
docker build "${args[@]}" .

# --- 4. token must not be in the image history ------------------------------
hist=$(docker history --no-trunc "${image}:${RUNNER_VERSION}")
if [[ -n "${GITHUB_PAT:-}" ]] && grep -qF -- "${GITHUB_PAT}" <<<"${hist}"; then
  echo "FAIL: GH_PAT value found in image history. Not pushing." >&2; exit 1
fi
if grep -qE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' <<<"${hist}"; then
  echo "FAIL: something that looks like a GitHub token is in the image history." >&2; exit 1
fi
echo "OK: no token found in image history."

# --- 5. smoke test ----------------------------------------------------------
ref="${image}:${RUNNER_VERSION}"
docker run --rm --entrypoint bash "${ref}" -euc '
  /actions-runner/bin/Runner.Listener --version
  docker --version
  jq --version
  openssl version
  test -x /entrypoint.sh && test -x /token.sh && test -x /healthcheck.sh && test -x /cleanup-offline-runners.sh
  bash -n /entrypoint.sh && bash -n /token.sh && bash -n /cleanup-offline-runners.sh
'
# Misconfiguration must fail fast with a clear message, not hang.
if out=$(docker run --rm "${ref}" /entrypoint.sh true 2>&1); then
  echo "FAIL: container started without any configuration" >&2; exit 1
fi
grep -q "REPO_URL required" <<<"${out}" || { echo "unexpected entrypoint output: ${out}" >&2; exit 1; }
echo "OK: smoke test passed."

# --- 6. push ----------------------------------------------------------------
if [[ "${PUSH}" != "true" ]]; then
  echo "PUSH is not true: built and tested only, nothing pushed."
  exit 0
fi
for tag in ${tags}; do docker push "${image}:${tag}"; done
{
  echo "Published \`${image}\` with tags:"
  for tag in ${tags}; do echo "- \`${tag}\`"; done
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
