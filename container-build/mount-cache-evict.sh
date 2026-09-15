#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# Keeps one mount-cache entry per cell: deletes every entry under $CACHE_STEM on this ref except $CACHE_KEY, once that key is saved.
# Never fails the job: eviction is housekeeping, and GitHub’s own LRU still bounds the repository.
set -euo pipefail

: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_REF:?}" "${CACHE_STEM:?}" "${CACHE_KEY:?}"
saved="$(gh cache list --repo "${GITHUB_REPOSITORY}" --ref "${GITHUB_REF}" --key "${CACHE_KEY}" --json id --jq length 2>&1)" \
  || { echo "::warning::mount-cache evict: cannot list caches (${saved}) — keeping every entry"; exit 0; }
if [ "${saved}" = 0 ]; then
  echo "mount-cache evict: key=${CACHE_KEY} was not saved — keeping the older entries"
  exit 0
fi
# every entry under the cell stem on this ref; the one just saved is skipped below
entries="$(gh cache list --repo "${GITHUB_REPOSITORY}" --ref "${GITHUB_REF}" --key "${CACHE_STEM}" --limit 100 \
             --json id,key --jq '.[] | [.id, .key] | @tsv' 2>&1)" \
  || { echo "::warning::mount-cache evict: cannot list stem=${CACHE_STEM} (${entries}) — keeping every entry"; exit 0; }
echo "mount-cache evict: stem=${CACHE_STEM} entries=$(printf '%s' "${entries}" | grep -c .) keep=${CACHE_KEY}"
while IFS=$'\t' read -r id key; do
  [ -n "${id}" ] && [ "${key}" != "${CACHE_KEY}" ] || continue
  if gh cache delete "${id}" --repo "${GITHUB_REPOSITORY}"; then
    echo "mount-cache evict: deleted id=${id} key=${key}"
  else
    echo "::warning::mount-cache evict: delete failed id=${id} key=${key}"
  fi
done <<<"${entries}"
