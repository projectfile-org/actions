#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# memory-cap.sh VALUE [MEMORY_MAX_PATH] — prints VALUE, clamped to the cgroup ceiling
set -euo pipefail

value="$1"
ceiling_path="${2:-/sys/fs/cgroup/memory.max}"

ceiling="$(cat "${ceiling_path}" 2> /dev/null)" || ceiling="max"
if [ "${ceiling}" = "max" ]; then
  echo "memory-cap value=${value} ceiling=none" >&2
  printf '%s\n' "${value}"
  exit 0
fi

if ! wanted="$(numfmt --from=iec "${value^^}" 2> /dev/null)"; then
  echo "memory-cap value=${value} unparsed, left for buildah to judge" >&2
  printf '%s\n' "${value}"
  exit 0
fi

if [ "${wanted}" -gt "${ceiling}" ]; then
  echo "::warning::memory-cap value=${value} above ceiling=${ceiling}, clamped" >&2
  printf '%s\n' "${ceiling}"
  exit 0
fi

echo "memory-cap value=${value} ceiling=${ceiling}" >&2
printf '%s\n' "${value}"
