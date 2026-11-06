#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# memory-cap.test.sh — checks memory-cap.sh at the edges of the cgroup ceiling
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ceiling_file="$(mktemp)"
trap 'rm --force "${ceiling_file}"' EXIT
failed=0
passed=0

# check NAME CEILING VALUE WANT — CEILING is the memory.max content
check() {
  local name="$1" ceiling="$2" value="$3" want="$4" got
  printf '%s\n' "${ceiling}" > "${ceiling_file}"
  got="$(bash "${here}/memory-cap.sh" "${value}" "${ceiling_file}" 2> /dev/null)"
  if [ "${got}" = "${want}" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL ${name}: got=${got} want=${want}" >&2
  fi
}

check below-ceiling 25769803776 16g 16g
check equal-ceiling 25769803776 24g 24g
check one-byte-above 25769803775 24g 25769803775
check above-ceiling 25769803776 32g 25769803776
check no-ceiling max 64g 64g
check unparsed 25769803776 lots lots

if [ "$(bash "${here}/memory-cap.sh" 16g /nonexistent 2> /dev/null)" = "16g" ]; then
  passed=$((passed + 1))
else
  failed=$((failed + 1))
  echo "FAIL missing-file: value changed" >&2
fi

echo "memory-cap.test passed=${passed} failed=${failed}"
[ "${failed}" -eq 0 ]
