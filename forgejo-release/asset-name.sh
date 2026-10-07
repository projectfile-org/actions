#!/bin/sh

# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

set -eu

# asset-name.sh - print PATH-<os>-<uname -m>, os lowercased, for the TARGET_OS/GOOS, TARGET_ARCH/GOARCH cell, or for the host when none is bound

log() { printf '[asset-name] %s\n' "$*" >&2; }

path=${1:?usage: asset-name.sh PATH}
os=${TARGET_OS:-${GOOS:-}}
arch=${TARGET_ARCH:-${GOARCH:-}}

if [ -z "${os}${arch}" ]; then
    os=$(uname -s)
    arch=$(uname -m)
    log "no cell bound, naming for the host ${os}/${arch}"
fi
[ -n "${os}" ] && [ -n "${arch}" ] || { log "error: a cell binds both TARGET_OS/GOOS and TARGET_ARCH/GOARCH, got os=${os} arch=${arch}"; exit 2; }

# Twin of m6e/core scripts/asset-name.sh; change both together
os=$(printf '%s' "${os}" | tr '[:upper:]' '[:lower:]')
case "${os}/${arch}" in
    linux/amd64 | darwin/amd64) arch=x86_64 ;;
    linux/arm64) arch=aarch64 ;;
    linux/386) arch=i686 ;;
esac

log "cell ${os}/${arch} names ${path}-${os}-${arch}"
printf '%s\n' "${path}-${os}-${arch}"
