#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# retry.test.sh — checks which containers-storage errors STORE_RACE classifies as a retryable race
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
passed=0

# shellcheck source-path=SCRIPTDIR source=retry.sh
source "${here}/retry.sh"

# check NAME WANT LINE — WANT is race or fatal, LINE is one error line as the tool prints it
check() {
  local name="$1" want="$2" line="$3" got=fatal
  grep --quiet --extended-regexp "${STORE_RACE}" <<<"${line}" && got=race
  if [ "${got}" = "${want}" ]; then
    passed=$((passed + 1))
    echo "store-retry-test: PASS ${name} ${got}"
  else
    failed=$((failed + 1))
    echo "store-retry-test: FAIL ${name} want=${want} got=${got}" >&2
  fi
}

blob='writing blob: adding layer with blob "sha256:bdc1458"'
check "layer not known" race 'Error: layer not known'
check "layer for blob not found" race 'layer for blob "sha256:ab" not found'
check "staged rename" race "${blob}: rename /s/overlay-layers/tmp/temp-dir-636684944/0-addition /s/overlay-layers/9f.tar-split.gz: no such file or directory"
check "unpack mkdir of a top-level path" race "${blob}: unpacking failed (error: exit status 1; output: mkdir /app: no such file or directory)"
check "unpack mkdir of a nested path" fatal "${blob}: unpacking failed (error: exit status 1; output: mkdir /app/data: no such file or directory)"
check "unpack mkdir over an existing path" fatal "${blob}: unpacking failed (error: exit status 1; output: mkdir /app: file exists)"
check "unpack mkdir refused" fatal "${blob}: unpacking failed (error: exit status 1; output: mkdir /app: permission denied)"
check "unrelated failure" fatal 'Error: payload does not match any of the supported image formats'

echo "store-retry-test: ${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
