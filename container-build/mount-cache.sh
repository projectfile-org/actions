#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# Persists a build’s BuildKit cache mounts through $MOUNT_CACHE_DIR: inject before the build, extract after.
# Sourced by a backend; each function takes the backend’s build command and flags as its arguments.

# mount_cache_dance inject|extract <build command…>: one dance build over the Dockerfile’s own mount flags
mount_cache_dance() {
  local mode="$1" dance dockerfile="${CONTEXT:-.}/Dockerfile"
  shift
  [ -n "${MOUNT_CACHE_DIR:-}" ] || { echo "mount-cache ${mode}: no cache dir — off"; return 0; }
  if [ "${mode}" = inject ] && ! ls "${MOUNT_CACHE_DIR}"/*.tar >/dev/null 2>&1; then
    echo "mount-cache inject: nothing restored under ${MOUNT_CACHE_DIR} — cold build"
    return 0
  fi
  dance="$(mktemp -d)"
  awk -v mode="${mode}" -v target="${M6E_BUILD_TARGET:-}" -v context=ci-mount-cache \
      -f "${GITHUB_ACTION_PATH}/../mount-cache.awk" "${dockerfile}" >"${dance}/Dockerfile"
  if [ ! -s "${dance}/Dockerfile" ]; then
    echo "mount-cache ${mode}: no cache mounts in ${dockerfile} — skipped"
    mkdir -p "${MOUNT_CACHE_DIR}"
    rm -rf -- "${dance}"
    return 0
  fi
  local -a out_args
  if [ "${mode}" = inject ]; then
    out_args=(--build-context "ci-mount-cache=${MOUNT_CACHE_DIR}" --output type=cacheonly)
  else
    out_args=(--output "type=local,dest=${dance}/out")
  fi
  echo "mount-cache ${mode}: dancing $(grep -c '^RUN' "${dance}/Dockerfile") run(s) dir=${MOUNT_CACHE_DIR}"
  if "$@" "${out_args[@]}" --file "${dance}/Dockerfile" "${dance}"; then
    if [ "${mode}" = extract ]; then
      rm -rf -- "${MOUNT_CACHE_DIR:?}"
      mkdir -p "$(dirname "${MOUNT_CACHE_DIR}")"
      mv "${dance}/out" "${MOUNT_CACHE_DIR}"
      mount_cache_summary
    fi
  else
    echo "::warning::mount-cache ${mode} failed — the build runs without it"
    mkdir -p "${MOUNT_CACHE_DIR}"
  fi
  rm -rf -- "${dance}"
}

# mount_cache_summary: one row per saved mount in the step summary, and the total
mount_cache_summary() {
  local total=0 size id f summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
  { printf '### Build cache mounts\n\n| mount | saved |\n|---|---|\n'; } >>"${summary}"
  for f in "${MOUNT_CACHE_DIR}"/*.tar; do
    [ -e "${f}" ] || continue
    id="$(cat "${f%.tar}.id" 2>/dev/null || basename "${f}")"
    size="$(stat --format=%s "${f}")"
    total=$((total + size))
    printf '| %s | %s |\n' "\`${id}\`" "$(numfmt --to=iec "${size}")" >>"${summary}"
    echo "mount-cache saved id=${id} bytes=${size}"
  done
  printf '| **total** | %s |\n\n' "$(numfmt --to=iec "${total}")" >>"${summary}"
  echo "mount-cache saved total bytes=${total} dir=${MOUNT_CACHE_DIR}"
}
