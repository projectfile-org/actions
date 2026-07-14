#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: exec a command inside an already-running compose container (the
# fused live stack dc-up-d brought up), named by the resolver-derived instance. On a
# non-zero exec, run a POST-MORTEM before propagating: unlike a `--rm` tool container,
# the live container is still alive here (teardown is a later dc-down step), so it is
# inspectable. A 137 (SIGKILL) on the exec means the container went AWAY under it — and
# the prime suspect on a concurrent matrix runner is podman-compose network naming: if
# the per-cell projects share ONE network instead of one each, a sibling cell's
# `down --remove-orphans` reaps this container mid-exec. So the dump leans on NAMES —
# the global pod/container/network view — not host memory.
set -euo pipefail

: "${CONTAINER:?container-exec: container is required}"
: "${RUN:?container-exec: run is required}"

echo "container-exec container=${CONTAINER} run=[${RUN}]"
rc=0
# RUN is intentionally word-split into the exec argv; capture the code instead of
# letting `set -e` abort, so a failure is diagnosed below before we re-raise it.
# shellcheck disable=SC2086
docker exec "${CONTAINER}" ${RUN} || rc=$?

if [ "${rc}" -ne 0 ]; then
  # Decode the exit so an opaque "RUN exit status N" reads as a cause. 128+S = killed
  # by signal S; 137 (SIGKILL) is the one that bites a concurrent live stack.
  case "${rc}" in
    137) hint="SIGKILL (128+9) — container reaped UNDER the exec (shared network teardown? OOM?)" ;;
    143) hint="SIGTERM (128+15) — graceful stop" ;;
    124) hint="timeout(1) deadline exceeded" ;;
    *)   hint="exec command exit status" ;;
  esac
  echo "container-exec FAILED rc=${rc} container=${CONTAINER} :: ${hint}" >&2
  # This container's verdict: did it exit/get-OOMed, and what network is it ON?
  docker inspect "${CONTAINER}"     \
    --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} networks={{range $n, $_ := .NetworkSettings.Networks}}{{$n}} {{end}}err={{.State.Error}}' >&2 || true
  docker logs --tail 100 "${CONTAINER}" >&2 || true
  # The global NAME view: are the concurrent matrix cells one pod/network each, or do
  # they collide on a single shared compose network? podman is the forge backend; this
  # is the dump the "how does podman-compose generate the names" question needs.
  if command -v podman >/dev/null 2>&1; then
    echo "--- podman ps -a --pod ---" >&2
    podman ps -a --pod >&2 || true
    echo "--- podman network ls ---" >&2
    podman network ls >&2 || true
  fi
fi
exit "${rc}"
