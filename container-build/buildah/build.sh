#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: build the context DAEMONLESSLY with buildah, then export the
# image to a DOCKER-format archive named for this cell — the IDENTICAL tar the
# buildx analogue produces, so everything downstream is backend-agnostic. The
# docker-archive layout carries `manifest.json` (not OCI's `index.json`), which is
# the ONLY tar layout the daemonless scanners read (trivy `--input` / dockle
# `--input` reject an OCI archive); `docker load` accepts either, so the format
# choice is invisible to the live-stack hand-off. The shared lib parses
# $BUILD_ARGS into the build_args array; this script owns only the buildah command.
set -euo pipefail

BACKEND=buildah
# shellcheck source-path=SCRIPTDIR source=../forge.sh
source "${GITHUB_ACTION_PATH}/../forge.sh"
# shellcheck source-path=SCRIPTDIR source=../build-args.sh
source "${GITHUB_ACTION_PATH}/../build-args.sh"
# shellcheck source-path=SCRIPTDIR source=../mounts.sh
source "${GITHUB_ACTION_PATH}/../mounts.sh"
# shellcheck source-path=SCRIPTDIR source=../labels.sh
source "${GITHUB_ACTION_PATH}/../labels.sh"

# Dockerfile stage selection (mirror the make-plane buildah-build): ci-resolver
# passes org.projectfile.ci.build-target.<gha|forgejo> as M6E_BUILD_TARGET. Empty
# => no --target => last stage.
target_args=()
[ -n "${M6E_BUILD_TARGET:-}" ] && target_args+=(--target "${M6E_BUILD_TARGET}")

echo "buildah building artifact=${ARTIFACT_NAME} image=${IMAGE:-<anonymous>} context=${CONTEXT} binds=${#build_contexts[@]}"
# --format docker: buildah defaults to OCI, whose image spec has NO healthcheck
# field — it silently DROPS the Dockerfile's HEALTHCHECK (also ONBUILD/SHELL). The
# Docker v2s2 manifest preserves it, so the published image carries a real
# HEALTHCHECK in production. Independent of the docker-archive *transport* below
# (manifest format vs tar layout are orthogonal knobs); matches the local
# `buildah commit --format docker` plane.
#
# --squash: flatten the build layers into one on top of the base. Load-bearing for
# multi-stage CHILD images (b19/gcc, b19/llvm, …) that inherit /app (owned 1000:1000
# by the base) and then write into it from BOTH a root stage (build-stage base) and a
# non-root stage (build-stage user, USER 1000). buildah's LAYERED commit mis-maps such
# a cross-UID, multi-layer directory and re-owns /app to 0:0 in the assembled manifest
# — even though every in-build `stat` reads 1000:1000 and no hook ever chowns it (a
# trailing `chown 1000 /app` does NOT fix it; the corruption is below the filesystem,
# at manifest assembly). Squashing removes the per-layer diff that mis-maps the dir, so
# /app commits 1000:1000. ubuntu (a single-stage base) never hit this — it has no
# cross-UID child stages. The low-level buildah build has no layer cache to lose here.
# env -u SOURCE_DATE_EPOCH: buildah honors the SOURCE_DATE_EPOCH env var to stamp
# the image's native `created` field — an inherited value would freeze it (e.g. at
# 1970-01-01 for 0). Stripped here, buildah stamps the real build time.
# Reproducibility (clamping layer timestamps) is intentionally not applied.
# --pull=newer: the runner's podman/buildah storage persists across jobs
# (warm cache by design). Default --pull=missing reuses a locally present base
# image tag unconditionally — a freshly pushed b19/gcc, b19/llvm, … under the
# same tag would silently never be fetched. "newer" checks the registry digest
# and only re-pulls on an actual change, so unchanged bases stay cache-hits.
env -u SOURCE_DATE_EPOCH buildah build --format docker --squash --pull=newer "${build_args[@]}" "${build_contexts[@]}" "${label_args[@]+"${label_args[@]}"}" "${target_args[@]+"${target_args[@]}"}" --iidfile iid.txt "${CONTEXT}"
image="$(cat iid.txt)"
# Embed the image ref AS the docker archive's reference (docker-archive:path:reference)
# so a downstream `docker load` restores THIS tag and the compose stack finds it by tag —
# never an anonymous archive. Empty IMAGE keeps the historical bare export.
dest="docker-archive:${ARTIFACT_NAME}.tar"
if [ -n "${IMAGE}" ]; then
  dest="docker-archive:${ARTIFACT_NAME}.tar:${IMAGE}"
fi
echo "exporting image=${image} -> ${dest}"
buildah push "${image}" "${dest}"

# Self-clean the ephemeral store copy: the exported tar is the deliverable (uploaded
# as this cell's artifact — the live-stack job re-loads it, oci-push skopeo-copies it).
# This plane commits WITHOUT -t, so the result is an ANONYMOUS = dangling image; left
# behind it accretes one orphan per build on the runner's warm persistent store. Reaping
# it HERE — at the source, once the tar exists — is what lets the runner drop its
# background `image prune` loop, and with it the race where that prune deletes a live
# multi-stage build's intermediate image out from under buildah, whose own end-of-build
# cleanup then aborts "identifier is not an image". Best-effort: the artifact is already
# written, so a failed reap must never fail the build (set -e is held off by the `if`).
# rmi by ID drops only this image + its exclusively-owned top layer — the shared base
# layers (warm cache) stay. Disable with M6E_BUILDAH_RMI=N to keep the image in-store.
if [ "${M6E_BUILDAH_RMI:-Y}" != "N" ]; then
  if buildah rmi "${image}" >/dev/null; then
    echo "reaped store image=${image} (tar is the artifact)"
  else
    echo "reap best-effort: rmi failed image=${image} (already gone?); continuing" >&2
  fi
fi
