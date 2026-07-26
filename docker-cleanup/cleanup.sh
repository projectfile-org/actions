#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: best-effort reap of the run-scoped artifacts a fused live job
# leaves behind — the image tag `docker load` entered and the network `compose up`
# created. Both are UNIQUE per run (the tag carries M6E_RUN_SCOPE, the network the
# run-scoped project name), so they are single-use and must NOT accumulate. The job
# is always()-guarded, so this runs whether `up`/`load` succeeded or not: a failed
# `up` is exactly the case that orphans the network (an endpoint stays attached).
#
# `set -e` is OFF for the reaps themselves: a missing image/network after `compose
# down` already removed them is the COMMON path, not an error. We surface real
# failures (docker daemon down) via the explicit rc captures, never via abort.
set -uo pipefail

echo "docker-cleanup image=[${IMAGE:-}] network=[${NETWORK:-}]"

# Reap the run-scoped image tag. `docker rmi -f` because the tag is single-use; the
# `|| true` covers the common case where the image was never loaded (a failed `load`
# ahead of us) or already gone.
if [ -n "${IMAGE:-}" ]; then
  if docker rmi --force "${IMAGE}" >/dev/null 2>&1; then
    echo "docker-cleanup: REAPED image=${IMAGE}"
  else
    echo "docker-cleanup: image=${IMAGE} already gone (or never loaded)"
  fi
fi

# Reap the live stack's network. `down` (the when:always teardown member) already
# tries, but a failed/timed-out `up` can leave an endpoint attached: compose reports
# the removal error WITHOUT failing, so the job goes green and the run-scoped network
# is orphaned forever. The `inspect` guard keeps the common path (down did remove it)
# from logging a bogus "No such network"; a real removal error still surfaces.
if [ -n "${NETWORK:-}" ]; then
  if docker network inspect "${NETWORK}" >/dev/null 2>&1; then
    if docker network rm "${NETWORK}" >/dev/null 2>&1; then
      echo "docker-cleanup: REAPED network=${NETWORK}"
    else
      # It existed but we could not remove it — surface this, it is a real problem
      # (an endpoint still attached, or a concurrent reaper raced us).
      echo "docker-cleanup: FAILED to remove network=${NETWORK} (endpoint attached? concurrent down?)" >&2
    fi
  else
    echo "docker-cleanup: network=${NETWORK} already gone (down removed it)"
  fi
fi

echo "docker-cleanup: done"
