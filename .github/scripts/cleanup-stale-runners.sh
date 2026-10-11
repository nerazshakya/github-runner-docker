#!/usr/bin/env bash
# Removes offline self-hosted runners from an org. Only runners whose name
# starts with one of RUNNER_NAME_PREFIXES are touched.
#
# Env: API_URL, ORG, TOKEN, RUNNER_NAME_PREFIXES (space separated),
#      DRY_RUN (true = list only)
set -euo pipefail

[[ -n "${TOKEN:-}" ]] || { echo "GH_PAT_V1 secret is not set"; exit 1; }
: "${API_URL:?}" "${ORG:?}" "${RUNNER_NAME_PREFIXES:?}"

api="${API_URL}/orgs/${ORG}/actions/runners"
found=$(mktemp); trap 'rm -f "${found}"' EXIT

# Collect first, delete afterwards, so paging is not disturbed by deletes.
page=1
while :; do
  resp=$(curl -fsS --max-time 30 \
    -H "Authorization: token ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${api}?per_page=100&page=${page}")
  [[ "$(jq '.runners | length' <<<"${resp}")" -eq 0 ]] && break
  for prefix in ${RUNNER_NAME_PREFIXES}; do
    jq -r --arg p "${prefix}" \
      '.runners[] | select(.status=="offline" and (.name|startswith($p))) | "\(.id) \(.name)"' \
      <<<"${resp}" >> "${found}"
  done
  page=$((page + 1))
done
sort -u -o "${found}" "${found}"

removed=0
while read -r id name; do
  [[ -z "${id}" ]] && continue
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo "[dry run] would remove ${name} (id ${id})"
  else
    echo "Removing ${name} (id ${id})"
    if curl -fsS --max-time 30 -X DELETE \
         -H "Authorization: token ${TOKEN}" \
         -H "Accept: application/vnd.github+json" \
         "${api}/${id}"; then
      removed=$((removed + 1))
    else
      echo "Warning: could not remove ${name}, skipping"
    fi
  fi
done < "${found}"
echo "Done. Removed ${removed} offline runner(s)."
