#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# event.test.sh — runs every verdict and fact path of event.sh against a stub curl
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp --directory)"
# shellcheck disable=SC2064 # work is fixed by now
trap "rm --recursive --force '${work}'" EXIT
mkdir --parents "${work}/bin" "${work}/nocurl"
ln --symbolic "$(command -v cat)" "${work}/nocurl/cat"
ln --symbolic "$(command -v date)" "${work}/nocurl/date"
failed=0
passed=0

cat >"${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do [ "$1" = --data ] && printf '%s\n' "$2" >>"${STUB_LOG}"; shift; done
exit "${STUB_RC:-0}"
STUB
chmod +x "${work}/bin/curl"
printf 'kiota.ch/b19/go@sha256:abc\n' >"${work}/image.digest"
printf '["1.2.3","1.2","latest"]\n' >"${work}/image.tags"

# check NAME WANT_RC VAR=VALUE… — runs event.sh once under the stub and compares its exit code
check() {
  local name="$1" want="$2" got=0
  shift 2
  : >"${work}/log"
  (cd "${work}" && env PATH="${work}/bin:${PATH}" STUB_LOG="${work}/log" EVENT_GOAL=published \
    EVENT_WEBHOOK=https://sink.invalid/hook GITHUB_REPOSITORY=b19/go "$@" \
    "${BASH}" "${here}/event.sh") >"${work}/out" 2>&1 || got=$?
  if [ "${got}" -eq "${want}" ]; then
    passed=$((passed + 1))
    echo "event-test: PASS ${name} rc=${got}"
  else
    failed=$((failed + 1))
    echo "event-test: FAIL ${name} want=${want} got=${got}" >&2
    cat "${work}/out" >&2
  fi
}

# expect NAME FILE PATTERN — asserts the last run wrote PATTERN to out or log
expect() {
  if grep --quiet --fixed-strings -- "$3" "${work}/$2"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "event-test: FAIL $1 missing [$3] in $2" >&2
    cat "${work}/out" "${work}/log" >&2
  fi
}

check "all needs pass" 0 EVENT_NEEDS=$'a=success\nb=success'
expect "succeeded posted" log '"event":"goal.succeeded","project":"b19/go","goal":"published","status":"success"'
check "one need failed" 1 EVENT_NEEDS=$'a=success\nb=failure'
expect "failed tally" out "verdict goal=published status=failure passed=1 skipped=0 failed=1"
expect "failed posted" log '"event":"goal.failed"'
check "cancelled counts as failed" 1 EVENT_NEEDS=a=cancelled
check "every need skipped" 0 EVENT_NEEDS=$'a=skipped\nb=skipped'
expect "skipped posted" log '"event":"goal.skipped","project":"b19/go","goal":"published","status":"skipped"'
check "one pass among skips" 0 EVENT_NEEDS=$'a=skipped\nb=success'
expect "one pass succeeds" out "status=success passed=1 skipped=1 failed=0"
check "no needs" 0 EVENT_NEEDS=
expect "no needs is skipped" out "status=skipped passed=0 skipped=0 failed=0"
check "no webhook" 1 EVENT_WEBHOOK= EVENT_NEEDS=a=failure
expect "post skipped" out "event post skipped event=goal.failed webhook=unset"
check "sink down stays green" 0 STUB_RC=22 EVENT_NEEDS=a=success
expect "sink failure named" out "event post failed event=goal.succeeded rc=22"
check "curl absent" 0 PATH="${work}/nocurl" EVENT_NEEDS=a=success
expect "degraded named" out "webhook degraded — curl absent (event=goal.succeeded)"
check "image fact" 0 EVENT_NAME=ci.image.published EVENT_CELL='{"series":"go1.27"}'
expect "fact payload" log '"payload":{"image":"kiota.ch/b19/go","tags":["1.2.3","1.2","latest"],"digest":"sha256:abc","cell":{"series":"go1.27"}}'
check "fact without digest" 1 EVENT_NAME=ci.image.published M6E_DIGEST_FILE=missing

echo "event-test: ${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
