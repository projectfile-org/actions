#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# release.test.sh — checks release.sh titles from the tag message, roots links, targets the branch and attaches every asset
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A commit hook's GIT_DIR would point the fixture's git at the real repository.
unset "${!GIT_@}"
work="$(mktemp --directory)"
trap 'rm --recursive --force "${work}"' EXIT
mkdir --parents "${work}/bin" "${work}/repo/dist"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.org

# Stub gh: every argument is recorded NUL-separated.
printf '#!/bin/sh\nprintf "%%s\\0" "$@" >> "%s/gh.log"\n' "${work}" > "${work}/bin/gh"
chmod +x "${work}/bin/gh"

cd "${work}/repo"
git init --quiet --initial-branch=main
git commit --quiet --allow-empty --message=init
git tag --annotate 0.1.0 --message=$'Faster start\n\nSee [rules](docs/rules.md)'
for name in x-linux-x86_64 x-linux-x86_64.asc; do echo "${name}" > "dist/${name}"; done

PATH="${work}/bin:${PATH}" RELEASE_TAG=0.1.0 RELEASE_PATH=dist/x RELEASE_URL=https://github.com/o/r/blob/0.1.0 RELEASE_TARGET=main bash "${here}/release.sh"

args="$(tr '\0' '\n' < "${work}/gh.log")"
for want in "release" "create" "0.1.0" "--target" "main" "Faster start" "[rules](https://github.com/o/r/blob/0.1.0/docs/rules.md)" "dist/x-linux-x86_64" "dist/x-linux-x86_64.asc"; do
	[[ "${args}" == *"${want}"* ]] || { echo "gh-release-test: FAIL missing ${want}" >&2; echo "${args}" >&2; exit 1; }
done
echo "gh-release-test: PASS title, links, target and 2 assets"
