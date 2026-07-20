#!/bin/bash
# Downloads and installs the GitHub Actions runner binary.
#
# Usage:
#   ./install_runner.sh -v <version> [-p <platform>] [-g <github-host>] [-o <org-name>]
#
# Options:
#   -v  Runner version (required)             e.g. 2.324.0
#   -p  Platform (default: linux/amd64)       linux/amd64 | linux/arm64 | linux/arm/v7
#   -g  GitHub Enterprise hostname (optional) e.g. github.example.com
#   -o  Organization name (required with -g)
#   -h  Show this help
#
# For GHES, set GITHUB_PAT env var with a PAT that has read:org scope.
#
# Examples:
#   github.com:
#     ./install_runner.sh -v 2.324.0
#
#   GHES:
#     GITHUB_PAT=ghp_xxx ./install_runner.sh -v 2.324.0 \
#       -g github.example.com \
#       -o my-org

set -euo pipefail

usage() {
  sed -n '/^# Usage/,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
  exit 1
}

PLATFORM="linux/amd64"
VERSION=""
GITHUB_HOST=""
ORG_NAME=""

while getopts ":v:p:g:o:h" opt; do
  case "$opt" in
    v) VERSION="$OPTARG"     ;;
    p) PLATFORM="$OPTARG"    ;;
    g) GITHUB_HOST="$OPTARG" ;;
    o) ORG_NAME="$OPTARG"    ;;
    h) usage ;;
    :) echo "Option -$OPTARG requires an argument."; usage ;;
    \?) echo "Unknown option: -$OPTARG"; usage ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "Error: version (-v) is required."; usage; }

if [[ -n "$GITHUB_HOST" ]]; then
  [[ -n "$ORG_NAME" ]]  || { echo "Error: org name (-o) is required for GHES."; usage; }
  [[ -n "${GITHUB_PAT:-}" ]] || { echo "Error: GITHUB_PAT env var is required for GHES."; exit 1; }
fi

case "$PLATFORM" in
  linux/amd64)  ARCH="x64"   ;;
  linux/arm64)  ARCH="arm64" ;;
  linux/arm/v7) ARCH="arm"   ;;
  *) echo "Unsupported platform: $PLATFORM"; exit 1 ;;
esac

TAR="actions-runner-linux-${ARCH}-${VERSION}.tar.gz"

if [[ -z "$GITHUB_HOST" ]]; then
  # github.com — public, no auth needed
  DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${VERSION}/${TAR}"
  echo ">>> Downloading runner v${VERSION} (linux-${ARCH}) from github.com..."
  curl -fsSL -o "$TAR" "$DOWNLOAD_URL"

else
  # GHES — query the API to get the signed download URL and checksum
  API="https://${GITHUB_HOST}/api/v3"
  echo ">>> Querying GHES API at ${API}..."

  RESPONSE=$(curl -fsSL \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "${API}/orgs/${ORG_NAME}/actions/runners/downloads")

  # The API returns a list of runner packages per OS/arch.
  # Each entry has: os, architecture, filename, download_url,
  # temp_download_token, sha256_checksum.
  # We match on os=linux and architecture (x64/arm64/arm).
  ENTRY=$(echo "$RESPONSE" | jq -r \
    --arg arch "$ARCH" \
    '.[] | select(.os=="linux" and .architecture==$arch)')

  [[ -n "$ENTRY" ]] || { echo "Error: no runner package found for linux/${ARCH} on ${GITHUB_HOST}"; exit 1; }

  DOWNLOAD_URL=$(echo "$ENTRY"    | jq -r '.download_url')
  DOWNLOAD_TOKEN=$(echo "$ENTRY"  | jq -r '.temp_download_token')
  SHA256=$(echo "$ENTRY"          | jq -r '.sha256_checksum')

  # Verify we got a real URL, not null
  [[ "$DOWNLOAD_URL" != "null" ]] || { echo "Error: download_url is null — check runner version ${VERSION} exists on ${GITHUB_HOST}"; exit 1; }

  echo ">>> Downloading runner v${VERSION} (linux-${ARCH}) from ${GITHUB_HOST}..."

  # temp_download_token is a short-lived Bearer token embedded by GHES
  # specifically for this download. Use it if present, fall back to PAT.
  if [[ "$DOWNLOAD_TOKEN" != "null" && -n "$DOWNLOAD_TOKEN" ]]; then
    curl -fsSL -H "Authorization: Bearer ${DOWNLOAD_TOKEN}" -o "$TAR" "$DOWNLOAD_URL"
  else
    curl -fsSL -H "Authorization: token ${GITHUB_PAT}" -o "$TAR" "$DOWNLOAD_URL"
  fi

  # Verify checksum
  echo "${SHA256}  ${TAR}" | sha256sum -c -
fi

echo ">>> Extracting..."
tar xzf "$TAR" && rm -f "$TAR"

echo ">>> Installing dependencies..."
./bin/installdependencies.sh

echo ">>> Runner v${VERSION} installed successfully."

