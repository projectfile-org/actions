#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# retry.test.sh — checks oci_retry runs a command, and that a shell function reaches it only through bash -c
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
passed=0

# check NAME WANT_RC — runs oci_retry with the rest of the arguments once and compares its exit code
check() {
  local name="$1" want="$2" got=0
  shift 2
  (
    export OCI_ACTION=retry-test M6E_OCI_RETRIES=1 M6E_OCI_BACKOFF=0
    # shellcheck source-path=SCRIPTDIR source=retry.sh
    source "${here}/retry.sh"
    oci_retry "${name}" "$@"
  ) > /dev/null 2>&1 || got=$?
  if [ "${got}" -eq "${want}" ]; then
    passed=$((passed + 1))
    echo "retry-test: PASS ${name} rc=${got}"
  else
    failed=$((failed + 1))
    echo "retry-test: FAIL ${name} want=${want} got=${got}" >&2
  fi
}

_listing_fn() { printf '%s' "${LISTING_TAG}"; }
export -f _listing_fn
export LISTING_TAG=ok

check "external command" 0 true
check "bare function is not an executable" 127 _listing_fn
check "function through bash -c" 0 bash -c _listing_fn
check "bash by name with no PATH" 127 env PATH=/nonexistent bash -c _listing_fn
check "bash by absolute path with no PATH" 0 env PATH=/nonexistent "${BASH}" -c _listing_fn

echo "retry-test: ${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
