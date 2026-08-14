#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: turn the `platform` input (the M6E_ARCH axis value ci-resolver
# mints from org.projectfile.architecture) into the backend's --platform flag, and
# refuse a foreign arch this kernel cannot emulate BEFORE the build starts — a missing
# binfmt handler otherwise surfaces as an exec-format error deep inside a RUN step,
# naming nothing. SHARED by both container-build backends (buildx and buildah take the
# same flag spelling) so the realisation lives in one place. SOURCED, not executed: it
# populates the caller's `platform_args` array, so the caller owns `set -euo pipefail`
# and a `return 1` here aborts the caller through it.
#
# One arch per call, never a multi-platform pass: the deliverable is the single-image
# docker-archive tar every consumer downstream (both scanners, the live test, oci-push)
# is built around, and only an OCI archive can carry more than one image.

# QEMU names its binfmt handler after the KERNEL arch, not the OCI one — linux/arm64 is
# served by qemu-aarch64, so probing qemu-arm64 never matches on a correctly set-up host.
_qemu_arch() {                               # $1 oci arch → qemu arch
  case "$1" in
    amd64) printf 'x86_64' ;;
    arm64) printf 'aarch64' ;;
    386)   printf 'i386' ;;
    *)     printf '%s' "$1" ;;               # arm, riscv64, ppc64le, s390x already match
  esac
}

platform_args=()
if [ -n "${PLATFORM:-}" ]; then
  # A BARE arch (`amd64`) is what the axis carries — the same token is also a tag segment
  # and a deps-file stem, so `linux/` is composed here, the one place it is really needed.
  _ref="${PLATFORM}"
  [ "${_ref#*/}" = "${_ref}" ] && _ref="linux/${_ref}"
  _arch="${_ref##*/}"
  case "$(uname -m)" in
    x86_64)        _host=amd64 ;;
    aarch64|arm64) _host=arm64 ;;
    *)             _host="$(uname -m)" ;;    # riscv64 and friends already spell alike
  esac
  if [ "${_arch}" = "${_host}" ]; then
    echo "${BACKEND} platform: native arch=${_arch} — no emulation needed"
  else
    _qemu="$(_qemu_arch "${_arch}")"
    if [ ! -f "/proc/sys/fs/binfmt_misc/qemu-${_qemu}" ]; then
      echo "${BACKEND} platform: MISSING qemu binfmt arch=${_arch} handler=qemu-${_qemu} host=${_host}" >&2
      echo "  install with: docker run --privileged --rm tonistiigi/binfmt --install all" >&2
      return 1
    fi
    echo "${BACKEND} platform: emulated arch=${_arch} handler=qemu-${_qemu} host=${_host}"
  fi
  platform_args+=(--platform "${_ref}")
fi
echo "${BACKEND} platform: parsed platform_args=${#platform_args[@]} ref=${PLATFORM:-<host>}"
