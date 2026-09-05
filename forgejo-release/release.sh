#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are trying to do: mint the Forgejo release tagged $VERSION and attach
# what this cell produced. Create wins on the first matrix cell; the 2nd..Nth cell
# (or a re-run) hits HTTP 409 "there is already a release for this tag" and falls
# back to `tea release assets create` — so a matrix converges on ONE release
# carrying every cell's assets.
#
# TWO modes, chosen by whether RELEASE_PATH is set:
#
#   BINARY     RELEASE_PATH names the unsuffixed artifact path. The binary was
#              produced by the build-binaries cell and restored to the workspace by
#              pf-ci's download-artifact step (the build→consumer hand-off); we
#              locate it by suffixing that path with the cell axes.
#   CREATE-ONLY  RELEASE_PATH is empty, which is a project that ships no binary at
#              all — a container-only image project. It mints the release with no
#              primary asset, and needs no TARGET_OS/TARGET_ARCH: it has no cell
#              axes to suffix with. The release exists so the image's magnet has
#              somewhere to be published, which is what makes an image release
#              addressable the same way a binary one is.
#
# Sidecars ride along in both modes, and are found two ways because the two modes
# name their files differently:
#
#   beside the asset   a .torrent and .magnet written next to the binary by the
#                      torrent pipeline, and a .asc written by the signing step,
#                      found by SUFFIXING the path this action already resolved — so
#                      nothing here has to know how the seed folder spells its flat,
#                      fleet-unique name (a torrent file's own name is not the name
#                      inside its info dict). Each is independent: a project may sign
#                      without seeding, seed without signing, or do both.
#   in torrents/       every file in the sidecar directory. Create-only has no asset
#                      path to suffix, so the image half collects its pair into a
#                      directory it declares as its CI artifact instead; the download
#                      edge restores that directory here.
#
# Absent files are simply not attached, so a project that never opted into seeding
# sees no change at all.
#
# Tunables, all optional:
#   RELEASE_TIMEOUT      seconds per tea call (default 120)
#   RELEASE_RETRIES      attach attempts before the cell fails (default 3)
#   RELEASE_BACKOFF      base seconds for the exponential backoff (default 2)
#   RELEASE_SIDECAR_DIR  directory swept for extra assets (default torrents)
set -euo pipefail

: "${VERSION:?forgejo-release: VERSION (the git tag) is required}"

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

timeout_s="${RELEASE_TIMEOUT:-120}"
retries="${RELEASE_RETRIES:-3}"
backoff="${RELEASE_BACKOFF:-2}"
sidecar_dir="${RELEASE_SIDECAR_DIR:-torrents}"
log() { printf '[forgejo-release] %s\n' "$*" >&2; }

# Which mode, and the asset it names. An UNSET release-asset-path is create-only —
# the template omits the input entirely for a project declaring no kind=binary
# artifact, so an empty value here is a decision and not a missing configuration.
asset=""
if [ -n "${RELEASE_PATH:-}" ]; then
	# WHICH cell this is — the pair that suffixes the asset name. TARGET_OS/TARGET_ARCH
	# is the language-neutral spelling every toolchain can bind; GOOS/GOARCH remains the
	# fallback so the Go projects that already name their axes that way need no edit.
	# Only the binary mode asks for them: a container-only release has no axis to spend.
	target_os="${TARGET_OS:-${GOOS:-}}"
	target_arch="${TARGET_ARCH:-${GOARCH:-}}"
	: "${target_os:?forgejo-release: TARGET_OS (or GOOS) must be set (matrix axis)}"
	: "${target_arch:?forgejo-release: TARGET_ARCH (or GOARCH) must be set (matrix axis)}"
	asset="${RELEASE_PATH}-${target_os}-${target_arch}"
	if [ ! -f "${asset}" ]; then
		log "asset not found at ${asset} — the build→consumer download edge should have restored it"
		exit 1
	fi
	# First output of the step. Without it a cell that dies during step setup and one
	# that blocks on the first tea call look identical: both print nothing at all.
	log "cell ${target_os}/${target_arch} releasing ${asset##*/} at ${VERSION} on ${server_url}"
else
	log "create-only: no binary declared, minting release ${VERSION} on ${server_url} for its sidecars"
fi

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

# Bounded attach of ONE file: the upload is a network crossing that every losing
# cell makes against the SAME release, so it gets timeout + retry + exponential
# backoff with jitter. Each attempt first drops a same-named attachment — Forgejo
# accepts DUPLICATE attachment names, so a re-run (or a retry after a partial
# upload) would otherwise stack a second pf-cli-linux-amd64 beside the first. This
# is the tea equivalent of the gh-release path's `gh release upload --clobber`.
attach() {
	local file="$1" attempt=1 delay name
	name="${file##*/}"
	while :; do
		if timeout "${timeout_s}" tea release assets delete --confirm       \
		                                                    --repo "${repo}" \
		                                                    "${VERSION}" "${name}" </dev/null; then
			log "dropped stale attachment ${name} on ${VERSION}"
		else
			log "no stale attachment ${name} on ${VERSION}"
		fi
		if timeout "${timeout_s}" tea release assets create --repo "${repo}"    \
		                                                    "${VERSION}" "${file}" </dev/null; then
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
# already exists). The tag is the title (tea SDK requires non-empty). Create-only
# passes no --asset: the release is minted empty and the sidecar sweep below fills
# it, so a 409 there means another cell got in first and there is nothing to redo.
if [ -n "${asset}" ]; then
	if timeout "${timeout_s}" tea release create --repo "${repo}"                         \
	                                             --tag "${VERSION}" --title "${VERSION}" \
	                                             --asset "${asset}" </dev/null; then
		log "created release ${VERSION} with ${asset##*/}"
	else
		log "release ${VERSION} exists, attaching ${asset##*/}"
		attach "${asset}"
	fi
elif timeout "${timeout_s}" tea release create --repo "${repo}"                          \
                                               --tag "${VERSION}" --title "${VERSION}" </dev/null; then
	log "created release ${VERSION} with no primary asset"
else
	log "release ${VERSION} already exists, nothing to create"
fi

# Each sidecar goes through the same clobbering attach, and each is independent:
# one failing does not cost the release the binary that already landed. Two
# sources, because the two modes name their files differently — see the header.
if [ -n "${asset}" ]; then
	for _suffix in .torrent .magnet .asc; do
		_sidecar="${asset}${_suffix}"
		if [ -f "${_sidecar}" ]; then
			attach "${_sidecar}"
		else
			log "no ${_suffix} beside ${asset##*/}, nothing to attach"
		fi
	done
fi

# The declared sidecar directory, restored here by the download edge from whichever
# node built the torrents. Absent => this project collects none, which is every
# project that never opted into seeding.
if [ -d "${sidecar_dir}" ]; then
	for _sidecar in "${sidecar_dir}"/*; do
		[ -f "${_sidecar}" ] || continue
		attach "${_sidecar}"
	done
else
	log "no ${sidecar_dir}/ directory, no collected sidecars to attach"
fi
