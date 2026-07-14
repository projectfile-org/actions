#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are trying to do: attach this cell's built binary to the Forgejo release
# tagged $VERSION. The binary was produced by the build-binaries cell and restored
# to the workspace by ci-resolver's download-artifact step (the build→consumer
# hand-off); we locate it by suffixing the resolved artifact path with the cell
# axes. The tag is both the release tag and the title (tea's SDK requires a
# non-empty title). Create wins on the first matrix cell; the 2nd..Nth cell (or a
# re-run) hits HTTP 409 "there is already a release for this tag" and falls back
# to `tea release attachment create` — so a GOOS×GOARCH matrix converges on ONE
# release with one asset per cell.
set -euo pipefail

: "${VERSION:?forgejo-release: VERSION (the git tag) is required}"
: "${RELEASE_PATH:?forgejo-release: RELEASE_PATH (the artifact binary path) is required}"
: "${GOOS:?forgejo-release: GOOS must be set (matrix axis)}"
: "${GOARCH:?forgejo-release: GOARCH must be set (matrix axis)}"
: "${FORGEJO_TOKEN:?forgejo-release: FORGEJO_TOKEN must be bound (credentials overlay)}"
: "${GITHUB_SERVER_URL:?forgejo-release: GITHUB_SERVER_URL must be set (Forgejo context)}"
: "${GITHUB_REPOSITORY:?forgejo-release: GITHUB_REPOSITORY must be set (Forgejo context)}"

asset="${RELEASE_PATH}-${GOOS}-${GOARCH}"
log() { printf '[forgejo-release] %s\n' "$*" >&2; }

if [ ! -f "${asset}" ]; then
	log "asset not found at ${asset} — the build→consumer download edge should have restored it"
	exit 1
fi

# Isolate tea's config to a per-job tmpdir (tea resolves it via XDG_CONFIG_HOME).
# The host-mode runner persists ~/.config/tea/config.yml across jobs, so a bare
# `tea login add` collides on re-runs ("login name 'ci' has already been used")
# and races under capacity>1. A fresh empty config makes the add stateless.
export XDG_CONFIG_HOME
XDG_CONFIG_HOME="$(mktemp -d)"
tea login add --name ci                  \
              --url "${GITHUB_SERVER_URL}" \
              --token "${FORGEJO_TOKEN}"

# Create wins on the first cell; attachment-create wins on cells 2..N (HTTP 409
# — the release already exists). The tag is the title (tea SDK requires non-empty).
if tea release create --repo "${GITHUB_REPOSITORY}" \
                      --tag "${VERSION}" --title "${VERSION}" --asset "${asset}"; then
	log "created release ${VERSION} with ${asset}"
else
	log "release ${VERSION} exists, attaching ${asset}"
	tea release attachment create --repo "${GITHUB_REPOSITORY}" "${VERSION}" "${asset}"
fi
