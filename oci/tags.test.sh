#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# tags.test.sh — checks tags.sh against the conformance/image vectors of the projectfile specification
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
passed=0

# check NAME WANT ENV… — WANT is the sorted space-joined tag set, or `reject:<reason>`
check() {
  local name="$1" want="$2" got errfile
  shift 2
  errfile="$(mktemp)"
  got="$(
    export OCI_ACTION=tags-test VERSION="" PREVIEW="" PRIMARY="" IMAGE="" HEADS="" VARIANT=""
    export VARIANT_JOIN="" VARIANT_ALIASES="" VARIANT_TAG="" VARIANT_BARE="" VARIANT_CELLS=""
    for kv in "$@"; do export "${kv?}"; done
    tags=()
    # shellcheck source-path=SCRIPTDIR source=tags.sh
    if source "${here}/tags.sh" > /dev/null 2> "${errfile}"; then
      printf '%s\n' "${tags[@]}" | sort | paste --serial --delimiters=' ' -
    else
      echo "reject:$(grep --only-matching --max-count=1 'head-is-variant\|cell-collision\|unknown-cell\|variant-tag' "${errfile}")"
    fi
  )"
  rm -f "${errfile}"
  want="$(tr ' ' '\n' <<< "${want}" | sort | paste --serial --delimiters=' ' -)"
  if [ "${got}" = "${want}" ]; then
    passed=$((passed + 1))
    echo "tags-test: PASS ${name}"
  else
    failed=$((failed + 1))
    echo "tags-test: FAIL ${name} want=[${want}] got=[${got}]" >&2
  fi
}

# sample rules, the same data the vectors declare
fleet_heads=$'release ${version} ${major}.${minor} ${major} latest\nprerelease ${version}\ntrunk edge\nbranch latest-${branch}'
rules=(HEADS="${fleet_heads}" VARIANT_JOIN=- VARIANT_ALIASES=defaults VARIANT_TAG="\${head}-\${variant}" VARIANT_BARE=latest)
ubuntu=$'resolute\nnoble'

check one-axis/resolute '0.20.0-resolute 0.20-resolute 0-resolute resolute 0.20.0 0.20 0 latest' \
  VERSION=0.20.0 "${rules[@]}" VARIANT='resolute resolute' VARIANT_CELLS="${ubuntu}"
check one-axis/noble '0.20.0-noble 0.20-noble 0-noble noble' \
  VERSION=0.20.0 "${rules[@]}" VARIANT='noble resolute' VARIANT_CELLS="${ubuntu}"

php_cells=$'8.4 cli\n8.4 fpm\n8.5 cli\n8.5 fpm'
php() { printf '%s 8.5\n%s cli\n' "$1" "$2"; }
check two-axes/8.5-cli '0.3.0-8.5-cli 0.3-8.5-cli 0-8.5-cli 8.5-cli 0.3.0-8.5 0.3-8.5 0-8.5 8.5 0.3.0-cli 0.3-cli 0-cli cli 0.3.0 0.3 0 latest' \
  VERSION=0.3.0 "${rules[@]}" VARIANT="$(php 8.5 cli)" VARIANT_CELLS="${php_cells}"
check two-axes/8.5-fpm '0.3.0-8.5-fpm 0.3-8.5-fpm 0-8.5-fpm 8.5-fpm 0.3.0-fpm 0.3-fpm 0-fpm fpm' \
  VERSION=0.3.0 "${rules[@]}" VARIANT="$(php 8.5 fpm)" VARIANT_CELLS="${php_cells}"
check two-axes/8.4-cli '0.3.0-8.4-cli 0.3-8.4-cli 0-8.4-cli 8.4-cli 0.3.0-8.4 0.3-8.4 0-8.4 8.4' \
  VERSION=0.3.0 "${rules[@]}" VARIANT="$(php 8.4 cli)" VARIANT_CELLS="${php_cells}"
check two-axes/8.4-fpm '0.3.0-8.4-fpm 0.3-8.4-fpm 0-8.4-fpm 8.4-fpm' \
  VERSION=0.3.0 "${rules[@]}" VARIANT="$(php 8.4 fpm)" VARIANT_CELLS="${php_cells}"

check non-numeric-default/gnu '0.4.0-gnu 0.4-gnu 0-gnu gnu 0.4.0 0.4 0 latest' \
  VERSION=0.4.0 "${rules[@]}" VARIANT='gnu gnu' VARIANT_CELLS=$'gnu\nmusl'
check non-numeric-default/musl '0.4.0-musl 0.4-musl 0-musl musl' \
  VERSION=0.4.0 "${rules[@]}" VARIANT='musl gnu' VARIANT_CELLS=$'gnu\nmusl'
check fixed-variant '0.20.0-resolute 0.20-resolute 0-resolute resolute 0.20.0 0.20 0 latest' \
  VERSION=0.20.0 "${rules[@]}" VARIANT='resolute resolute'
check branch-head/resolute 'latest-feature-x-resolute latest-feature-x' \
  PREVIEW=feature/x PRIMARY=main "${rules[@]}" VARIANT='resolute resolute' VARIANT_CELLS="${ubuntu}"
check branch-head/noble 'latest-feature-x-noble' \
  PREVIEW=feature/x PRIMARY=main "${rules[@]}" VARIANT='noble resolute' VARIANT_CELLS="${ubuntu}"
check other-rules/cli 'cli.8.5_0.3.0 cli.8.5_stable' VERSION=0.3.0 HEADS="release \${version} stable" \
  VARIANT_JOIN=. VARIANT_TAG="\${variant}_\${head}" VARIANT="$(printf 'cli cli\n8.5 8.5')" VARIANT_CELLS=$'cli 8.5\nfpm 8.5'
check other-rules/fpm 'fpm.8.5_0.3.0 fpm.8.5_stable' VERSION=0.3.0 HEADS="release \${version} stable" \
  VARIANT_JOIN=. VARIANT_TAG="\${variant}_\${head}" VARIANT="$(printf 'fpm cli\n8.5 8.5')" VARIANT_CELLS=$'cli 8.5\nfpm 8.5'
check no-variant '0.8.1 0.8 0 latest' VERSION=0.8.1 "${rules[@]}"
check reject-cell-collision 'reject:cell-collision' VERSION=0.1.0 "${rules[@]}" \
  VARIANT="$(printf '8 8\n9 10')" VARIANT_CELLS=$'8 9\n8 10\n9 9\n9 10'
check reject-head-is-variant 'reject:head-is-variant' VERSION=8.5.0 "${rules[@]}" \
  VARIANT='8.5 8.5' VARIANT_CELLS=$'8.4\n8.5'

check trunk-edge-variant 'edge-resolute edge' PREVIEW=main PRIMARY=main "${rules[@]}" VARIANT='resolute resolute' VARIANT_CELLS="${ubuntu}"
check pre-release-variant '1.2.3-rc1-noble' VERSION=1.2.3-rc1 "${rules[@]}" VARIANT='noble resolute' VARIANT_CELLS="${ubuntu}"
check no-default-never-dropped '0.1.0-musl 0.1-musl 0-musl musl' VERSION=0.1.0 "${rules[@]}" VARIANT='musl -'
check no-aliases '0.1.0-gnu 0.1-gnu 0-gnu gnu' VERSION=0.1.0 "${rules[@]}" VARIANT_ALIASES=none VARIANT='gnu gnu'
check load-tag-fallback 'dev-resolute dev' IMAGE=b19/ubuntu:dev "${rules[@]}" VARIANT='resolute resolute'
check undeclared-kind-keeps-cascade 'edge' PREVIEW=main PRIMARY=main HEADS="release \${version}"
check reject-unknown-cell 'reject:unknown-cell' VERSION=0.1.0 "${rules[@]}" VARIANT='jammy resolute' VARIANT_CELLS="${ubuntu}"
check reject-missing-tag-template 'reject:variant-tag' VERSION=0.1.0 VARIANT='gnu gnu'

# no rules at all: the cascade every existing workflow publishes
check trunk-edge 'edge' PREVIEW=main PRIMARY=main
check branch 'latest-feature-x' PREVIEW=feature/x PRIMARY=main
check pre-release '1.2.3-rc1' VERSION=1.2.3-rc1
check v-prefix '1.2.3 1.2 1 latest' VERSION=v1.2.3

echo "tags-test: ${passed} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
