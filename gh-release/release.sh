#!/bin/sh

# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

set -eu

# release.sh - create the GitHub release for RELEASE_TAG from its tag message, links rooted at RELEASE_URL, attaching every RELEASE_PATH-* asset and sidecar

log() { printf '[gh-release] %s\n' "$*" >&2; }

tag=${RELEASE_TAG:?gh-release: RELEASE_TAG (the git tag) is required}
path=${RELEASE_PATH:-}
here=$(dirname "$0")

set --
if [ -n "${path}" ]; then
    # Every platform's binary and its .asc/.torrent/.magnet, since one job releases them all.
    for asset in "${path}"-*; do
        [ -f "${asset}" ] || continue
        set -- "$@" "${asset}"
        log "attaching ${asset}"
    done
    [ "$#" -gt 0 ] || { log "no asset matches ${path}-*, the build→consumer download edge should have restored them"; exit 1; }
else
    log "create-only: no binary path for tag=${tag}"
fi

title=$("${here}/tag-message.sh" "${tag}" title)
notes=$("${here}/tag-message.sh" "${tag}" body)
if [ -n "${RELEASE_URL:-}" ]; then
    notes=$(printf '%s\n' "${notes}" | sed -E "s|\]\(([^):/#][^):]*)\)|](${RELEASE_URL}/\1)|g")
    log "relative links rooted at ${RELEASE_URL}"
else
    log "no RELEASE_URL, relative links left as written"
fi
stable=${RELEASE_TARGET:-}
log "release tag=${tag} target=${stable:-<default branch>}"
if gh release create "${tag}" --verify-tag ${stable:+--target "${stable}"} --title "${title}" --notes "${notes}" "$@"; then
    log "created release tag=${tag} title=${title} assets=$#"
elif [ "$#" -gt 0 ]; then
    log "release tag=${tag} exists, uploading assets=$# first=$1 (--clobber)"
    gh release upload "${tag}" "$@" --clobber
else
    gh release view "${tag}" >/dev/null
    log "release tag=${tag} exists, nothing to attach"
fi
