#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
set -euo pipefail

: "${EVENT_GOAL:?event: goal is required}"
event="${EVENT_NAME:-}"
status=success
facts='{}'
failed=0

# Verdict mode: tally each `need=result` line into the goal’s status and event.
if [ -z "${event}" ]; then
  passed=0 skipped=0
  while IFS= read -r pair; do
    [ -n "${pair}" ] || continue
    echo "verdict need=${pair%%=*} result=${pair#*=}"
    case "${pair#*=}" in
      success) passed=$((passed + 1)) ;;
      skipped) skipped=$((skipped + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done <<<"${EVENT_NEEDS:-}"
  event=goal.succeeded
  if [ "${failed}" -gt 0 ]; then
    status=failure event=goal.failed
  elif [ "${passed}" -eq 0 ]; then
    status=skipped event=goal.skipped
  fi
  echo "verdict goal=${EVENT_GOAL} status=${status} passed=${passed} skipped=${skipped} failed=${failed}"
# Fact mode: read back the ref and tag cascade the publish wrote.
else
  ref="$(cat "${M6E_DIGEST_FILE:-image.digest}")"
  tags="$(cat "${M6E_TAGS_FILE:-image.tags}")"
  facts="$(printf '{"image":"%s","tags":%s,"digest":"%s","cell":%s}' "${ref%@*}" "${tags}" "${ref#*@}" "${EVENT_CELL:-null}")"
  echo "events emitting event=${event} ref=${ref}"
fi

if [ -z "${EVENT_WEBHOOK:-}" ]; then
  echo "event post skipped event=${event} webhook=unset"
elif ! command -v curl >/dev/null 2>&1; then
  echo "webhook degraded — curl absent (event=${event})"
else
  url="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  payload="$(printf '{"event":"%s","project":"%s","goal":"%s","status":"%s","url":"%s","ts":"%s","payload":%s}' \
    "${event}" "${GITHUB_REPOSITORY:-}" "${EVENT_GOAL}" "${status}" "${url}" "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "${facts}")"
  # Fail-soft POST with timeout and retries; the URL is never logged.
  curl --silent --show-error --location --max-time 10 --retry 3 --retry-delay 2 --fail-with-body \
    --header 'content-type: application/json' --request POST --data "${payload}" "${EVENT_WEBHOOK}" \
    || echo "event post failed event=${event} rc=$?"
fi

[ "${failed}" -eq 0 ]
