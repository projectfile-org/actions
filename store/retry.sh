#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: run ONE containers-storage write under a bounded retry, so a
# sibling job's reap costs seconds instead of a whole pipeline. The runner executes
# CAPACITY jobs against ONE persistent graphroot shared by podman AND buildah (see
# r8e/forgejo-runner), and every store read is TWO lookups — enumerate a record, then
# resolve the layer it points at. A concurrent `buildah rmi` (end of a build) or
# `docker rmi` (docker-cleanup) landing between them leaves a record pointing at
# nothing, and the caller aborts on whatever it happened to be touching. That is why
# the victim looks random and why a restart always passes: the half-deleted record is
# gone on the next pass. ONLY this error class retries; everything else stays fatal.
# SOURCED, not executed. Callers set STORE_ACTION, STORE_ATTEMPTS and STORE_DELAY.

# Both spellings containers-storage produces for one reaped layer: `commitLayer`
# reports "layer not known", the blob-reuse path reports "layer for blob … not found".
# A regex covering only one silently declines to retry half the occurrences.
STORE_RACE='layer not known|image not known|identifier is not an image|layer for blob .*not found'

# The command is piped to tee, so it runs in a SUBSHELL: a retried callback hands its
# result back through the filesystem (buildah's --iidfile, the image store), never
# through a shell variable, which would be discarded with the subshell.
store_retry() {                              # $1 label, $2 log path, $3… the command
  local _label="$1" _log="$2" _attempt=1 _rc _delay
  shift 2
  while :; do
    echo "${STORE_ACTION} attempt=${_attempt}/${STORE_ATTEMPTS} ${_label}"
    # set +e: a failed attempt is data for the retry test, not a script exit.
    set +e
    "$@" 2>&1 | tee "${_log}"
    _rc="${PIPESTATUS[0]}"
    set -e
    [ "${_rc}" -eq 0 ] && return 0
    if [ "${_attempt}" -ge "${STORE_ATTEMPTS}" ]; then
      echo "${STORE_ACTION} FAILED rc=${_rc} ${_label} attempts=${STORE_ATTEMPTS} exhausted" >&2
      return "${_rc}"
    fi
    if ! grep --quiet --extended-regexp "${STORE_RACE}" "${_log}"; then
      echo "${STORE_ACTION} FAILED rc=${_rc} ${_label} attempt=${_attempt} — not a store race, not retrying" >&2
      return "${_rc}"
    fi
    # Jitter keeps two colliding jobs from replaying in lockstep and colliding again.
    _delay=$(( STORE_DELAY * _attempt + RANDOM % STORE_DELAY ))
    echo "${STORE_ACTION} hit the shared-store race rc=${_rc} ${_label} attempt=${_attempt}/${STORE_ATTEMPTS} — retrying in ${_delay}s" >&2
    sleep "${_delay}"
    _attempt=$(( _attempt + 1 ))
  done
}
