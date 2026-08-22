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
# to `tea release assets create` — so an os×arch matrix converges on ONE release
# with one asset per cell.
#
# Tunables, all optional:
#   RELEASE_TIMEOUT  seconds per tea call (default 120)
#   RELEASE_RETRIES  attach attempts before the cell fails (default 3)
#   RELEASE_BACKOFF  base seconds for the exponential backoff (default 2)
set -euo pipefail

: "${VERSION:?forgejo-release: VERSION (the git tag) is required}"
: "${RELEASE_PATH:?forgejo-release: RELEASE_PATH (the artifact binary path) is required}"
# WHICH cell this is — the pair that suffixes the asset name. TARGET_OS/TARGET_ARCH
# is the language-neutral spelling every toolchain can bind; GOOS/GOARCH remains the
# fallback so the Go projects that already name their axes that way need no edit.
target_os="${TARGET_OS:-${GOOS:-}}"
target_arch="${TARGET_ARCH:-${GOARCH:-}}"
: "${target_os:?forgejo-release: TARGET_OS (or GOOS) must be set (matrix axis)}"
: "${target_arch:?forgejo-release: TARGET_ARCH (or GOARCH) must be set (matrix axis)}"

# WHERE this cell releases. The ambient Forgejo Actions context is the default, so
# a project releasing only to the forge it runs on binds nothing. SERVER_URL/REPO
# override it, which is what lets a kiota pipeline attach the same binaries to a
# Codeberg release: Codeberg grants no build minutes, so nothing can run there.
# REPO is its own input rather than derived from SERVER_URL, because the repository
# name differs per forge — kiota holds projectfile/bridge, GitHub holds
# damian-buho/projectfile-bridge.
server_url="${SERVER_URL:-${GITHUB_SERVER_URL:-}}"
repo="${REPO:-${GITHUB_REPOSITORY:-}}"
: "${server_url:?forgejo-release: server-url (or GITHUB_SERVER_URL) must be set}"
: "${repo:?forgejo-release: repo (or GITHUB_REPOSITORY) must be set}"

# The token NAME is DERIVED from the destination: uppercase, `-` → `_`, suffix
# `_TOKEN`, so adding a destination is a data edit and never a roster edit here.
# FORGEJO_TOKEN stays the fallback — it names a PROTOCOL rather than a destination,
# and it is what every project binding no per-destination secret already uses.
token="${FORGEJO_TOKEN:-}"
if [ -n "${SINK:-}" ]; then
	_token_var="$(printf '%s' "${SINK}" | tr '[:lower:]-' '[:upper:]_')_TOKEN"
	if [ -n "${!_token_var:-}" ]; then
		echo "[forgejo-release] sink=${SINK} authenticating with ${_token_var}" >&2
		token="${!_token_var}"
	else
		echo "[forgejo-release] sink=${SINK} has no ${_token_var} — falling back to FORGEJO_TOKEN" >&2
	fi
fi
: "${token:?forgejo-release: no token bound (credentials overlay: <SINK>_TOKEN or FORGEJO_TOKEN)}"

asset="${RELEASE_PATH}-${target_os}-${target_arch}"
name="${asset##*/}"
timeout_s="${RELEASE_TIMEOUT:-120}"
retries="${RELEASE_RETRIES:-3}"
backoff="${RELEASE_BACKOFF:-2}"
log() { printf '[forgejo-release] %s\n' "$*" >&2; }

if [ ! -f "${asset}" ]; then
	log "asset not found at ${asset} — the build→consumer download edge should have restored it"
	exit 1
fi

# First output of the step. Without it a cell that dies during step setup and one
# that blocks on the first tea call look identical: both print nothing at all.
log "cell ${target_os}/${target_arch} releasing ${name} at ${VERSION} on ${server_url}"

# Isolate tea's config to a per-job tmpdir (tea resolves it via XDG_CONFIG_HOME).
# The host-mode runner persists ~/.config/tea/config.yml across jobs, so a bare
# `tea login add` collides on re-runs ("login name 'ci' has already been used")
# and races under capacity>1. A fresh empty config makes the add stateless.
export XDG_CONFIG_HOME
XDG_CONFIG_HOME="$(mktemp -d)"
# Every tea call reads stdin from /dev/null. `timeout` runs its child in a NEW
# process group, and a background-group process that touches the controlling TTY
# gets SIGTTIN and STOPS — a stopped process never handles the SIGTERM timeout
# sends at expiry, so the guard against hanging becomes an unkillable hang. The
# runner attaches a TTY, so this is not theoretical. /dev/null also turns any
# prompt into an immediate EOF failure, which is what CI wants anyway.
timeout "${timeout_s}" tea login add --name ci             \
                                     --url "${server_url}" \
                                     --token "${token}" </dev/null

# Bounded attach: the upload is a network crossing that every losing cell makes
# against the SAME release, so it gets timeout + retry + exponential backoff with
# jitter. Each attempt first drops a same-named attachment — Forgejo accepts
# DUPLICATE attachment names, so a re-run (or a retry after a partial upload)
# would otherwise stack a second pf-cli-linux-amd64 beside the first. This is the
# tea equivalent of the gh-release path's `gh release upload --clobber`.
attach() {
	local attempt=1 delay
	while :; do
		if timeout "${timeout_s}" tea release assets delete --confirm       \
		                                                    --repo "${repo}" \
		                                                    "${VERSION}" "${name}" </dev/null; then
			log "dropped stale attachment ${name} on ${VERSION}"
		else
			log "no stale attachment ${name} on ${VERSION}"
		fi
		if timeout "${timeout_s}" tea release assets create --repo "${repo}"    \
		                                                    "${VERSION}" "${asset}" </dev/null; then
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
if timeout "${timeout_s}" tea release create --repo "${repo}"                         \
                                             --tag "${VERSION}" --title "${VERSION}" \
                                             --asset "${asset}" </dev/null; then
	log "created release ${VERSION} with ${name}"
else
	log "release ${VERSION} exists, attaching ${name}"
	attach
fi
