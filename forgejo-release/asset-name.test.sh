#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# asset-name.test.sh — pins asset-name.sh to the names uname prints, the same table m6e/core tests/asset-name.py checks
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
passed=0

while read -r goos goarch want; do
  got="$(env --unset=TARGET_OS --unset=TARGET_ARCH GOOS="${goos}" GOARCH="${goarch}" "${here}/asset-name.sh" dist/x 2>/dev/null)"
  if [ "${got}" = "${want}" ]; then
    passed=$((passed + 1))
    echo "asset-name-test: PASS ${goos}/${goarch} ${got}"
  else
    failed=$((failed + 1))
    echo "asset-name-test: FAIL ${goos}/${goarch} want=${want} got=${got}" >&2
  fi
done <<'TABLE'
linux amd64 dist/x-linux-x86_64
linux arm64 dist/x-linux-aarch64
linux riscv64 dist/x-linux-riscv64
linux 386 dist/x-linux-i686
darwin amd64 dist/x-darwin-x86_64
darwin arm64 dist/x-darwin-arm64
freebsd amd64 dist/x-freebsd-amd64
Linux x86_64 dist/x-linux-x86_64
TABLE

echo "asset-name-test: ${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
