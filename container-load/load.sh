#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: enter this cell's build archive into the runner's image store so
# the fused live stack can `compose up` it. The load is the LAST remaining writer to
# the shared graphroot besides the build itself (publish jobs skopeo-copy the archive
# straight to the registry and never load), and it is the twin victim of the same
# reaper race container-build/buildah already retries — so it retries identically.
#
# On podman (the runner's `docker` is a shim) the failure is illegible: podman probes
# all four transports and prints all four errors, so the banner claims the payload
# matches no supported format while the tar is perfectly fine. Only the
# `docker-archive:` line carries the real cause. We log the archive we were handed
# before touching it, so the transcript names the victim even when podman will not.
set -euo pipefail

STORE_ACTION=container-load
STORE_ATTEMPTS="${M6E_LOAD_ATTEMPTS:-3}"
STORE_DELAY="${M6E_LOAD_RETRY_DELAY:-5}"
# shellcheck source-path=SCRIPTDIR source=../store/retry.sh
source "${GITHUB_ACTION_PATH}/../store/retry.sh"

# The resolver names the uncompressed tar; M6E_ARCHIVE_COMPRESSION=zstd makes the
# builder emit <stem>.tar.zst instead. docker load auto-detects the codec, so
# following the suffix here is all the compressed path needs to work at all.
archive_path="${ARCHIVE}"
if [ ! -f "${archive_path}" ] && [ -f "${archive_path}.zst" ]; then
  echo "container-load archive=${archive_path} absent, following compressed sibling=${archive_path}.zst"
  archive_path="${archive_path}.zst"
fi

# The log rides the job workspace, NOT $TMPDIR: /tmp is a 64m tmpfs on the runner.
load_log=".container-load-$(basename "${archive_path}").log"
trap 'rm --force "${load_log}"' EXIT

_docker_load() { docker load --input "${archive_path}"; }

echo "container-load archive=${archive_path} attempts=${STORE_ATTEMPTS}"
store_retry "archive=${archive_path}" "${load_log}" _docker_load
