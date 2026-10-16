#!/bin/sh

# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

set -eu

# tag-message.sh - print the title or body of an annotated tag, refetching the tag object a CI checkout flattened

log() { printf '[tag-message] %s\n' "$*" >&2; }
annotated() { [ "$(git cat-file -t "refs/tags/${tag}" 2>/dev/null || true)" = tag ]; }

usage="usage: tag-message.sh TAG title|body"
tag=${1:?${usage}}
part=${2:?${usage}}
case "${part}" in title) format='%(contents:subject)' ;; body) format='%(contents:body)' ;; *) log "part=${part} (${usage})"; exit 2 ;; esac
token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
retries=${TAG_MESSAGE_RETRIES:-3}
log "tag=${tag} part=${part} token=$([ -n "${token}" ] && echo set || echo none) retries=${retries}"
# header passed through the environment, never argv, the way actions/checkout authenticates
if [ -n "${token}" ]; then
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${token}" | base64 | tr -d '\n')"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0
fi

attempt=1
while ! annotated && [ "${attempt}" -le "${retries}" ]; do
    log "tag=${tag} is not annotated locally, fetching attempt=${attempt}/${retries}"
    timeout 60 git fetch --quiet --force --no-tags origin "+refs/tags/${tag}:refs/tags/${tag}" || log "fetch of tag=${tag} failed attempt=${attempt}"
    attempt=$((attempt + 1))
    annotated || [ "${attempt}" -gt "${retries}" ] || sleep $((attempt * 2))
done

if annotated; then
    # A re-signed tag keeps its earlier signature in the body, so cut from the first armor line on
    git tag --list "${tag}" --format="${format}" | sed '/^-----BEGIN [A-Z ]*SIGNATURE-----$/,$d'
    log "tag=${tag} part=${part} read from the annotated tag"
elif [ "${part}" = title ]; then
    log "tag=${tag} carries no message, title falls back to the tag"
    printf '%s\n' "${tag}"
else
    log "tag=${tag} carries no message, body is empty"
fi
