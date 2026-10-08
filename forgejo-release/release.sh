#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# Mint the Forgejo release tagged $VERSION once and attach every PATH-* asset and swept sidecar.

# Tunables, all optional:
#   RELEASE_TIMEOUT      seconds per tea call (default 120)
#   RELEASE_RETRIES      attach attempts before the job fails (default 3)
#   RELEASE_BACKOFF      base seconds for the exponential backoff (default 2)
#   RELEASE_SIDECAR_DIR  directories swept for extra assets (default "torrents dist/torrents")
set -euo pipefail

: "${VERSION:?forgejo-release: VERSION (the git tag) is required}"

# WHERE this job releases. The ambient Forgejo Actions context is the default, so
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
sidecar_dirs="${RELEASE_SIDECAR_DIR:-torrents dist/torrents}"
log() { printf '[forgejo-release] %s\n' "$*" >&2; }

# Every platform's binary and its .asc/.torrent/.magnet; unset RELEASE_PATH is an image-only release.
assets=()
if [ -n "${RELEASE_PATH:-}" ]; then
	for _asset in "${RELEASE_PATH}"-*; do
		if [ -f "${_asset}" ]; then assets+=("${_asset}"); fi
	done
	if [ "${#assets[@]}" -eq 0 ]; then
		log "no asset matches ${RELEASE_PATH}-* — the build→consumer download edge should have restored them"
		exit 1
	fi
	log "releasing ${#assets[@]} assets matching ${RELEASE_PATH##*/}-* at ${VERSION} on ${server_url}"
else
	log "create-only: no binary declared, minting release ${VERSION} on ${server_url} for its sidecars"
fi
# shellcheck disable=SC2086 # a space-separated directory list
for _dir in ${sidecar_dirs}; do
	if [ ! -d "${_dir}" ]; then
		log "no ${_dir}/ directory, no collected sidecars there"
		continue
	fi
	for _sidecar in "${_dir}"/*; do
		if [ -f "${_sidecar}" ]; then assets+=("${_sidecar}"); fi
	done
	log "swept ${_dir}/, ${#assets[@]} assets queued"
done

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

# Title and notes from the annotated tag, refetched with the job token when checkout flattened it to lightweight
annotated() { [ "$(git cat-file -t "refs/tags/${VERSION}" 2>/dev/null || true)" = tag ]; }
for attempt in $(seq 1 "${retries}"); do
	annotated && break
	log "tag ${VERSION} is not annotated locally, fetching attempt=${attempt}/${retries}"
	GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${TAG_TOKEN:-}" | base64 | tr -d '\n')" \
		timeout "${timeout_s}" git fetch --quiet --force --no-tags origin "+refs/tags/${VERSION}:refs/tags/${VERSION}" </dev/null || sleep "$((backoff * attempt))"
done
title="${VERSION}"
notes=""
if annotated; then
	title="$(git tag --list "${VERSION}" --format='%(contents:subject)')"
	title="${title:-${VERSION}}"
	# A re-signed tag keeps its earlier signature in the body, so cut from the first armor line on
	notes="$(git tag --list "${VERSION}" --format='%(contents:body)' | sed -E -e '/^-----BEGIN [A-Z ]*SIGNATURE-----$/,$d' -e "s|\]\(([^):/#][^):]*)\)|](${server_url%/}/${repo}/src/tag/${VERSION}/\1)|g")"
	log "release ${VERSION} titled '${title}' with ${#notes} bytes of notes from the tag message"
else
	log "tag ${VERSION} carries no message, titling the release with the tag"
fi

# Created empty, titled by the tag message; a 409 means a re-run already made it.
if timeout "${timeout_s}" tea release create --repo "${repo}"                          \
                                            --tag "${VERSION}" --title "${title}" --note "${notes}" </dev/null; then
	log "created release ${VERSION}"
else
	log "release ${VERSION} already exists, attaching to it"
fi

# Each attach clobbers its namesake, so a re-run converges on the same release.
for _asset in "${assets[@]}"; do
	attach "${_asset}"
done
