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
# to `tea release assets create` — so a GOOS×GOARCH matrix converges on ONE
# release with one asset per cell.
#
# Tunables, all optional:
#   RELEASE_TIMEOUT  seconds per tea call (default 120)
#   RELEASE_RETRIES  attach attempts before the cell fails (default 3)
#   RELEASE_BACKOFF  base seconds for the exponential backoff (default 2)
set -euo pipefail

: "${VERSION:?forgejo-release: VERSION (the git tag) is required}"
: "${RELEASE_PATH:?forgejo-release: RELEASE_PATH (the artifact binary path) is required}"
: "${GOOS:?forgejo-release: GOOS must be set (matrix axis)}"
: "${GOARCH:?forgejo-release: GOARCH must be set (matrix axis)}"
: "${FORGEJO_TOKEN:?forgejo-release: FORGEJO_TOKEN must be bound (credentials overlay)}"
: "${GITHUB_SERVER_URL:?forgejo-release: GITHUB_SERVER_URL must be set (Forgejo context)}"
: "${GITHUB_REPOSITORY:?forgejo-release: GITHUB_REPOSITORY must be set (Forgejo context)}"

asset="${RELEASE_PATH}-${GOOS}-${GOARCH}"
name="${asset##*/}"
timeout_s="${RELEASE_TIMEOUT:-120}"
retries="${RELEASE_RETRIES:-3}"
backoff="${RELEASE_BACKOFF:-2}"
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
timeout "${timeout_s}" tea login add --name ci                  \
                                     --url "${GITHUB_SERVER_URL}" \
                                     --token "${FORGEJO_TOKEN}"

# Bounded attach: the upload is a network crossing that every losing cell makes
# against the SAME release, so it gets timeout + retry + exponential backoff with
# jitter. Each attempt first drops a same-named attachment — Forgejo accepts
# DUPLICATE attachment names, so a re-run (or a retry after a partial upload)
# would otherwise stack a second pf-cli-linux-amd64 beside the first. This is the
# tea equivalent of the gh-release path's `gh release upload --clobber`.
attach() {
	local attempt=1 delay
	while :; do
		if timeout "${timeout_s}" tea release assets delete --confirm                    \
		                                                    --repo "${GITHUB_REPOSITORY}" \
		                                                    "${VERSION}" "${name}"; then
			log "dropped stale attachment ${name} on ${VERSION}"
		else
			log "no stale attachment ${name} on ${VERSION}"
		fi
		if timeout "${timeout_s}" tea release assets create --repo "${GITHUB_REPOSITORY}" \
		                                                    "${VERSION}" "${asset}"; then
			log "attached ${name} to release ${VERSION} on attempt ${attempt}"
			return 0
		fi
		if [ "${attempt}" -ge "${retries}" ]; then
			log "attach of ${name} to ${VERSION} failed after ${attempt} attempts"
			return 1
		fi
		delay=$((backoff * (2 ** (attempt - 1)) + RANDOM % (backoff + 1)))
		log "retrying attach of ${name} in ${delay}s (attempt ${attempt}/${retries})"
		sleep "${delay}"
		attempt=$((attempt + 1))
	done
}

# Create wins on the first cell; attach wins on cells 2..N (HTTP 409 — the release
# already exists). The tag is the title (tea SDK requires non-empty).
if timeout "${timeout_s}" tea release create --repo "${GITHUB_REPOSITORY}" \
                                             --tag "${VERSION}" --title "${VERSION}" --asset "${asset}"; then
	log "created release ${VERSION} with ${name}"
else
	log "release ${VERSION} exists, attaching ${name}"
	attach
fi
