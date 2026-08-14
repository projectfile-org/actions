#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: run ONE registry crossing under a bounded retry with exponential
# backoff and jitter, so a registry blip (a transient 500 mid blob upload, a dropped
# connection) costs seconds instead of a whole release. skopeo ships --retry-times, but
# containers/image does NOT classify every upload 5xx as retryable, so the flag alone is
# unreliable for the failure actually seen here. Every wrapped operation is idempotent at
# the destination — re-uploading a blob the registry already has is a no-op, and a
# manifest push overwrites its own tag — so retrying after a partial attempt is safe.
#
# Each attempt is also bounded in TIME. A registry that accepts the connection and then
# stops answering does not fail — it hangs, and a hung attempt cannot be retried because
# it never ends. The cap has to clear a full layer upload of a large image, so it is
# generous by default and tunable; expiry (rc 124) is just another failed attempt.
#
# Only the mutating crossings are wrapped; a login and a read-back verify stay
# single-shot. M6E_OCI_RETRIES=1 opts out. SOURCED, not executed.

_oci_retries="${M6E_OCI_RETRIES:-3}"
_oci_backoff="${M6E_OCI_BACKOFF:-2}"
_oci_timeout="${M6E_OCI_TIMEOUT:-900}"

oci_retry() {                                # $1 label, $2… the command to run
  local _label="$1" _attempt=1 _delay _rc
  shift
  while :; do
    # set +e: a failed attempt is data for the retry test, not a script exit.
    set +e
    timeout "${_oci_timeout}" "$@"
    _rc=$?
    set -e
    [ "${_rc}" -eq 124 ] && echo "${OCI_ACTION} timed out after ${_oci_timeout}s ${_label}" >&2
    [ "${_rc}" -eq 0 ] && return 0
    if [ "${_attempt}" -ge "${_oci_retries}" ]; then
      echo "${OCI_ACTION} FAILED rc=${_rc} ${_label} attempts=${_attempt} exhausted" >&2
      return "${_rc}"
    fi
    _delay=$((_oci_backoff * (2 ** (_attempt - 1)) + RANDOM % (_oci_backoff + 1)))
    echo "${OCI_ACTION} failed rc=${_rc} ${_label} attempt=${_attempt}/${_oci_retries} — retrying in ${_delay}s" >&2
    sleep "${_delay}"
    _attempt=$((_attempt + 1))
  done
}
