#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# preflight.test.sh — runs every preflight check against a stub skopeo, a closed port and an unreachable disk floor
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp --directory)"
# shellcheck disable=SC2064 # work is fixed by now
trap "rm --recursive --force '${work}'" EXIT
mkdir --parents "${work}/bin"
failed=0
passed=0

cat >"${work}/bin/skopeo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG}"
case "$*" in
  manifest-digest*) echo "sha256:${STUB_DIGEST:-d1}" ;;
  *--raw*)
    case "${STUB_MODE:-ok}" in
      absent) echo "manifest unknown" >&2; exit 1 ;;
      private) echo "unauthorized: authentication required" >&2; exit 1 ;;
      offline) echo "dial tcp: connection refused" >&2; exit 1 ;;
      hang) exec sleep 5 ;;
      flaky) [ -f "${STUB_LOG}.flaky" ] || { : >"${STUB_LOG}.flaky"; echo "dial tcp: i/o timeout" >&2; exit 1; }; echo '{"schemaVersion":2}' ;;
      *) echo '{"schemaVersion":2}' ;;
    esac ;;
  *--config*) [ "${STUB_CONFIG_MODE:-ok}" != hang ] || exec sleep 5; printf '{"config":{"Labels":{"org.opencontainers.image.version":"%s","org.projectfile.provides":"%s"}}}\n' "${STUB_VERSION:-1.5.0}" "${STUB_PROVIDES-auto-go-test,auto-go-lint}" ;;
esac
STUB
chmod +x "${work}/bin/skopeo"

# check NAME WANT_RC VAR=VALUE… — runs preflight.sh once under the stub and compares its exit code
check() {
  local name="$1" want="$2" got=0
  shift 2
  env PATH="${work}/bin:${PATH}" XDG_CACHE_HOME="${work}/cache" STUB_LOG="${work}/log" "$@" \
    bash "${here}/preflight.sh" >"${work}/out" 2>&1 || got=$?
  if [ "${got}" -eq "${want}" ]; then
    passed=$((passed + 1))
    echo "preflight-test: PASS ${name} rc=${got}"
  else
    failed=$((failed + 1))
    echo "preflight-test: FAIL ${name} want=${want} got=${got}" >&2
    cat "${work}/out" >&2
  fi
}

# expect NAME PATTERN — asserts the last run printed PATTERN
expect() {
  if grep --quiet --fixed-strings -- "$2" "${work}/out"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "preflight-test: FAIL $1 missing [$2]" >&2
    cat "${work}/out" >&2
  fi
}

img() { printf 'kiota.ch/d9t/go-tools latest %s %s' "${1:--}" "${2:--}"; }

check "absent image" 1 PREFLIGHT_CHECK=images STUB_MODE=absent PREFLIGHT_IMAGES="$(img)"
expect "absent names ref and sink" "image=kiota.ch/d9t/go-tools:latest sink=kiota.ch verdict=ABSENT"
check "private reads as unknown" 1 PREFLIGHT_CHECK=images STUB_MODE=private PREFLIGHT_IMAGES="$(img)"
expect "unknown verdict" "verdict=UNKNOWN"
check "unset registry" 1 PREFLIGHT_CHECK=images PREFLIGHT_IMAGES="registry.invalid/d9t/go-tools latest - -"
check "bare hub name is qualified" 0 PREFLIGHT_CHECK=images PREFLIGHT_IMAGES="hadolint/hadolint v2.14.0 - -"
expect "docker.io prefix" "image=docker.io/hadolint/hadolint:v2.14.0"
check "bare tagged hub name is qualified" 1 PREFLIGHT_CHECK=images STUB_MODE=absent PREFLIGHT_IMAGES="docker:29.8.1-cli - - -"
expect "bare tagged hub sink" "image=docker.io/docker:29.8.1-cli sink=docker.io"
check "registry port kept" 0 PREFLIGHT_CHECK=images STUB_DIGEST=g1 PREFLIGHT_IMAGES="registry.local:5000/a/b:1 - - -"
expect "registry port sink" "image=registry.local:5000/a/b:1 digest="
check "timeout only warns" 0 PREFLIGHT_CHECK=images STUB_MODE=hang PREFLIGHT_TIMEOUT=1 PREFLIGHT_RETRIES=1 PREFLIGHT_IMAGES="$(img)"
expect "timeout named" "verdict=TIMEOUT attempts=1 unchecked — the job’s own pull decides :: no answer within 1s"
check "unreachable only warns" 0 PREFLIGHT_CHECK=images STUB_MODE=offline PREFLIGHT_RETRIES=2 PREFLIGHT_IMAGES="$(img)"
expect "unreachable retried" "attempt=1/2 verdict=UNREACHABLE retrying"
expect "unreachable keeps error" "verdict=UNREACHABLE attempts=2 unchecked — the job’s own pull decides :: dial tcp: connection refused"
check "config timeout only warns" 0 PREFLIGHT_CHECK=images STUB_CONFIG_MODE=hang STUB_DIGEST=c1 PREFLIGHT_TIMEOUT=1 PREFLIGHT_RETRIES=1 PREFLIGHT_IMAGES="$(img)"
expect "config timeout named" "verdict=TIMEOUT attempts=1 unchecked"
rm --force "${work}/log.flaky"
check "flaky read recovers" 0 PREFLIGHT_CHECK=images STUB_MODE=flaky STUB_DIGEST=c2 PREFLIGHT_IMAGES="$(img)"
expect "flaky read passes" "image=kiota.ch/d9t/go-tools:latest digest=c2 version=[1.5.0] verdict=ok"
check "lower edge in range" 0 PREFLIGHT_CHECK=images STUB_VERSION=1.4.0 STUB_DIGEST=e1 PREFLIGHT_IMAGES="$(img - '>=1.4.0,<2.0.0')"
check "upper edge out of range" 1 PREFLIGHT_CHECK=images STUB_VERSION=2.0.0 STUB_DIGEST=e2 PREFLIGHT_IMAGES="$(img - '>=1.4.0,<2.0.0')"
expect "range names both versions" "version=2.0.0 outside requires=>=1.4.0,<2.0.0"
check "below lower edge" 1 PREFLIGHT_CHECK=images STUB_VERSION=1.3.9 STUB_DIGEST=e3 PREFLIGHT_IMAGES="$(img - '>=1.4.0')"
check "v prefix and strict greater" 0 PREFLIGHT_CHECK=images STUB_VERSION=v1.4.1 STUB_DIGEST=e4 PREFLIGHT_IMAGES="$(img - '>1.4.0,<=1.4.1')"
check "strict greater edge" 1 PREFLIGHT_CHECK=images STUB_VERSION=1.4.0 STUB_DIGEST=e5 PREFLIGHT_IMAGES="$(img - '>1.4.0')"
check "dev version warns" 0 PREFLIGHT_CHECK=images STUB_VERSION=abc1234 STUB_DIGEST=e6 PREFLIGHT_IMAGES="$(img - '>=1.4.0')"
expect "dev version unchecked" "is not a release version"
check "missing command warns" 0 PREFLIGHT_CHECK=images STUB_DIGEST=e7 PREFLIGHT_IMAGES="$(img auto-go-test,auto-gremlins)"
expect "missing command named" "lists no command=auto-gremlins"
check "warned verdict is not cached" 0 PREFLIGHT_CHECK=images STUB_DIGEST=e7 PREFLIGHT_IMAGES="$(img auto-go-test,auto-gremlins)"
expect "warning repeats" "lists no command=auto-gremlins"
check "no provides label warns" 0 PREFLIGHT_CHECK=images STUB_PROVIDES= STUB_DIGEST=e8 PREFLIGHT_IMAGES="$(img auto-go-test)"
expect "no provides unchecked" "carries no org.projectfile.provides label"

: >"${work}/log"
check "cold digest" 0 PREFLIGHT_CHECK=images STUB_DIGEST=f1 PREFLIGHT_IMAGES="$(img auto-go-test)"
check "warm digest" 0 PREFLIGHT_CHECK=images STUB_DIGEST=f1 PREFLIGHT_IMAGES="$(img auto-go-test)"
expect "warm digest is cached" "verdict=ok cached"
if [ "$(grep --count -- '--config' "${work}/log")" -eq 1 ]; then passed=$((passed + 1)); else
  failed=$((failed + 1)); echo "preflight-test: FAIL a warm digest must fetch no config blob" >&2
fi

check "no color" 1 NO_COLOR=1 PREFLIGHT_CHECK=network
if grep --quiet $'\e' "${work}/out"; then failed=$((failed + 1)); echo "preflight-test: FAIL NO_COLOR printed an escape" >&2; else passed=$((passed + 1)); fi
expect "summary names failures" "  ✗ unknown check"

check "closed port" 1 PREFLIGHT_CHECK=hosts PREFLIGHT_RETRIES=1 PREFLIGHT_ENV="PREFLIGHT_HOSTS=127.0.0.1:1"
expect "closed port named" "host=127.0.0.1:1 verdict=UNREACHABLE"
check "fallback port used" 1 PREFLIGHT_CHECK=hosts PREFLIGHT_RETRIES=1 PREFLIGHT_ENV="PREFLIGHT_HOSTS=127.0.0.1::1"
check "unset host skipped" 0 PREFLIGHT_CHECK=hosts PREFLIGHT_ENV="PREFLIGHT_HOSTS=: host: :3142"
check "foreign env refused" 0 PREFLIGHT_CHECK=hosts PREFLIGHT_ENV="PATH=/nonexistent"
expect "foreign env named" "env pair ignored name=[PATH]"
check "disk floor" 1 PREFLIGHT_CHECK=disk GITHUB_WORKSPACE="${work}" PREFLIGHT_ENV="PREFLIGHT_MIN_FREE_GIB=999999999"
check "disk ok" 0 PREFLIGHT_CHECK=disk GITHUB_WORKSPACE="${work}" PREFLIGHT_ENV="PREFLIGHT_MIN_FREE_GIB=0"
check "unknown check" 1 PREFLIGHT_CHECK=network

echo "preflight-test: ${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
