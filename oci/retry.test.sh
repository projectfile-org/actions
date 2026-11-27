#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# retry.test.sh — checks oci_retry runs a command, reaches a function only through bash -c, and retries a login
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
passed=0

# check NAME WANT_RC — runs oci_retry with the rest of the arguments once and compares its exit code
check() {
  local name="$1" want="$2" got=0
  shift 2
  (
    OCI_ACTION=retry-test M6E_OCI_RETRIES=1 M6E_OCI_BACKOFF=0
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

# a command failing once with a network error, then succeeding, keyed on a state file per check
stub="$(mktemp --directory)"
trap 'rm -rf "${stub}"' EXIT
cat > "${stub}/skopeo" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *" --username ${WANT_USER} "* ]] || { echo "stub: username not passed: $*" >&2; exit 4; }
[ "$(cat)" = "${WANT_PASSWORD}" ] || { echo "stub: password not on stdin" >&2; exit 3; }
[ -f "${STUB_STATE}" ] && exit 0
: > "${STUB_STATE}"
echo 'dial tcp [2600::1]:443: connect: network is unreachable' >&2
exit 1
STUB
chmod +x "${stub}/skopeo"

# login NAME RETRIES WANT_RC — runs oci_login against the flaky stub skopeo and compares its exit code
login() {
  local name="$1" retries="$2" want="$3" got=0
  rm -f "${stub}/state"
  (
    OCI_ACTION=retry-test M6E_OCI_RETRIES="${retries}" M6E_OCI_BACKOFF=0
    export PATH="${stub}:${PATH}" STUB_STATE="${stub}/state" WANT_PASSWORD=pw WANT_USER=u REGISTRY_USERNAME=u REGISTRY_PASSWORD=pw
    # shellcheck source-path=SCRIPTDIR source=retry.sh
    source "${here}/retry.sh"
    # shellcheck source-path=SCRIPTDIR source=auth.sh
    source "${here}/auth.sh"
    sink_names=(dockerhub)
    sink_repos=(docker.io/o/r)
    oci_login "${stub}/authfile" ""
  ) > /dev/null 2>&1 || got=$?
  if [ "${got}" -eq "${want}" ]; then
    passed=$((passed + 1))
    echo "retry-test: PASS ${name} rc=${got}"
  else
    failed=$((failed + 1))
    echo "retry-test: FAIL ${name} want=${want} got=${got}" >&2
  fi
}

login "login single-shot fails on a network blip" 1 1
login "login retries past a network blip" 2 0

echo "retry-test: ${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
