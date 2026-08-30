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
# shellcheck source-path=SCRIPTDIR source=../platform.sh
source "${GITHUB_ACTION_PATH}/../platform.sh"

# Dockerfile stage selection (mirror the make-plane buildah-build): pf-ci
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
# Layer handling: M6E_BUILDAH_LAYERS defaults to TRUE so buildah caches intermediate
# layers in the runner’s persistent graphroot and a LATER build of the same Dockerfile
# reuses them (the cross-build build-step cache — a rebuild that changes only a trailing
# line otherwise re-runs every step, e.g. a full GCC compile for b19/gcc). This is the
# inverse of buildah’s own default (false = single commit, no caching) and of the old
# --squash behaviour: both threw the build-step cache away. --squash is NOT used: under
# layers=true it would defeat the cache (flatten away the very intermediates we keep
# them for), and under layers=false it is redundant (both collapse to one layer).
#
# Why we diverge from buildah’s default toward caching: the runner’s image-store GC
# (a `podman image prune` loop) was DESIGNED to keep the warm cache bounded, but it
# reaped intermediate layers that an in-flight OR cached build still needed — it ruined
# the cache, not just disk usage — so it was REMOVED. With nothing pruning, dangling
# intermediates accumulate but are exactly the cache we want; layer reuse across builds
# is the goal. M6E_BUILDAH_LAYERS=false opts back into the uncached single-commit path
# (e.g. for a one-off build where cache churn isn’t worth the disk).
buildah_layers="${M6E_BUILDAH_LAYERS:-true}"
# env -u SOURCE_DATE_EPOCH: buildah honors the SOURCE_DATE_EPOCH env var to stamp
# the image's native `created` field — an inherited value would freeze it (e.g. at
# 1970-01-01 for 0). Stripped here, buildah stamps the real build time.
# Reproducibility (clamping layer timestamps) is intentionally not applied.
# --pull=newer: the runner's podman/buildah storage persists across jobs
# (warm cache by design). Default --pull=missing reuses a locally present base
# image tag unconditionally — a freshly pushed b19/gcc, b19/llvm, … under the
# same tag would silently never be fetched. "newer" checks the registry digest
# and only re-pulls on an actual change, so unchanged bases stay cache-hits.
#
# Shared-store race retry: what makes a BUILD a victim is the CACHE PROBE --layers runs
# before every step — it enumerates the store’s images and THEN resolves each candidate’s
# top layer, so a sibling job’s reap between those two lookups aborts the WHOLE build on
# whichever step it happened to be probing (the shared lib holds the general mechanism).
# A replay runs on cache hits, so retrying costs almost nothing. M6E_BUILDAH_ATTEMPTS=1
# opts out; container-load is the twin victim and retries the same class.
STORE_ACTION="buildah build"
STORE_ATTEMPTS="${M6E_BUILDAH_ATTEMPTS:-3}"
STORE_DELAY="${M6E_BUILDAH_RETRY_DELAY:-5}"
# shellcheck source-path=SCRIPTDIR source=../../store/retry.sh
source "${GITHUB_ACTION_PATH}/../../store/retry.sh"
# Per-build memory cap. The runner cgroup is one shared ceiling (CAPACITY × per-job
# budget — see r8e/forgejo-runner AGENTS.md); without a per-build cap every heavy RUN
# (elm --optimize, a GCC compile) fans out at full nproc inside that shared ceiling and
# the kernel OOM-killer reaps the largest allocation mid-step (exit 137, host idle).
# --memory lands a real memory.max on each RUN container: the delegate-cgroup entrypoint
# already enables the memory controller down the subtree, so buildah’s cap is honored by
# nested rootless podman. --memory-swap lets a transient peak spill to the host’s swap
# instead of dying; it is memory PLUS swap, so 4g+8g = 4g swap headroom. Both empty =>
# no cap (local `make build` stays uncapped, the graceful default).
mem_args=()
if [ -n "${M6E_BUILDAH_MEMORY:-}" ]; then
  mem_args+=(--memory "${M6E_BUILDAH_MEMORY}")
  if [ -n "${M6E_BUILDAH_MEMORY_SWAP:-}" ]; then
    mem_args+=(--memory-swap "${M6E_BUILDAH_MEMORY_SWAP}")
  fi
  echo "buildah build memory=${M6E_BUILDAH_MEMORY} swap=${M6E_BUILDAH_MEMORY_SWAP:-<none>} artifact=${ARTIFACT_NAME}"
fi
# The log rides the job workspace, NOT $TMPDIR: /tmp is a 64m tmpfs on the runner and
# a large build would fill it.
build_log=".buildah-build-${ARTIFACT_NAME}.log"
trap 'rm --force "${build_log}"' EXIT

_buildah_build() {
  # A failed attempt must not leave a stale id behind for the next one to read.
  rm --force iid.txt
  env -u SOURCE_DATE_EPOCH BUILDAH_LAYERS="${buildah_layers}" buildah build --format docker --pull=newer "${mem_args[@]+"${mem_args[@]}"}" "${platform_args[@]+"${platform_args[@]}"}" "${build_args[@]}" "${build_contexts[@]}" "${label_args[@]+"${label_args[@]}"}" "${target_args[@]+"${target_args[@]}"}" --iidfile iid.txt "${CONTEXT}"
}

store_retry "artifact=${ARTIFACT_NAME} layers=${buildah_layers}" "${build_log}" _buildah_build
image="$(cat iid.txt)"

# Layer-metadata heal (buildah --layers bug workaround, twin of the make-plane
# buildah-build block): buildah ≤1.42 omits a cache-mountpoint PARENT dir entry
# from a step's committed layer when that RUN only modified (copy-up, not create)
# a pre-existing file under it — the orphaned child materializes the parent as
# root:755 and overlay "topmost layer wins" poisons the merged image. b19 images
# hit it on every `build-stage user` (write-lineage under ${B19_HOME} with the
# download cache mounted) and lose home-dir ownership, failing test.d. Re-assert
# the declared posture (uid ${B19_UID}, gid 0, g+rwX — what 200-permissions.sh
# set) on OFFENDING dirs only, committed as a final layer that outranks the
# poisoned ones, and hand the healed ID downstream so the exported tar carries
# it. Non-b19 images (no B19_HOME env) skip. M6E_BUILDAH_HEAL=N opts out.
if [ "${M6E_BUILDAH_HEAL:-Y}" != "N" ] && [ "${buildah_layers}" = "true" ]; then
  img_env="$(buildah inspect --type image --format '{{range .OCIv1.Config.Env}}{{println .}}{{end}}' "${image}" 2>/dev/null || true)"
  b19_home="$(printf '%s\n' "${img_env}" | sed -n 's/^B19_HOME=//p' | head -1)"
  b19_uid="$(printf '%s\n' "${img_env}" | sed -n 's/^B19_UID=//p' | head -1)"
  if [ -n "${b19_home}" ] && [ -n "${b19_uid}" ]; then
    # --format docker: `buildah from` defaults to oci, whose container config
    # HAS no Healthcheck field — the parent's Docker HEALTHCHECK is dropped on
    # the from→commit round-trip (the source of the `service_healthy` hang:
    # consumers depending on a sidecar's HEALTHCHECK never see it become
    # healthy). A docker-format container carries it through to the commit.
    heal_ctr="$(buildah from --format docker "${image}")"
    heal_out="$(buildah run --user 0 "${heal_ctr}" -- sh -c "
        find '${b19_home}' -xdev -type d ! \( -uid ${b19_uid} -gid 0 \) -print -exec chown ${b19_uid}:0 {} + ;
        find '${b19_home}' -xdev -type d ! -perm -g=rwx -print -exec chmod g+rwX {} +
    ")" || { buildah rm "${heal_ctr}" >/dev/null; exit 1; }
    if [ -n "${heal_out}" ]; then
      image="$(buildah commit --format docker --rm "${heal_ctr}")"
      echo "buildah healed image=${image} home=${b19_home} dirs: $(printf '%s' "${heal_out}" | tr '\n' ' ')"
    else
      echo "buildah heal image=${image} home=${b19_home} clean, nothing to heal"
      buildah rm "${heal_ctr}" >/dev/null
    fi
  fi
fi

# Embed the image ref AS the docker archive's reference (docker-archive:path:reference)
# so a downstream `docker load` restores THIS tag and the compose stack finds it by tag —
# never an anonymous archive. Empty IMAGE keeps the historical bare export.
dest="docker-archive:${ARTIFACT_NAME}.tar"
if [ -n "${IMAGE}" ]; then
  dest="docker-archive:${ARTIFACT_NAME}.tar:${IMAGE}"
fi
echo "exporting image=${image} -> ${dest}"
buildah push "${image}" "${dest}"

# Optional whole-tar compression of the exported artifact. IO is frequently the
# bottleneck on the upload/download/publish hop, so trading CPU for a smaller tar
# wins net wall-clock. docker load AUTO-DETECTS gzip/bzip2/xz/zstd (Docker 25+), so
# the live-stack consumer needs no change; the only consumer that cares is oci-push
# (skopeo requires a seekable UNcompressed docker-archive — it decompresses to a
# temp .tar before copy, see oci-push/push.sh). Layers inside the tar are typically
# already gzip, so this squeezes mainly the manifest/config/metadata slack — modest
# ratio but cheaper bytes on every hop. Default M6E_ARCHIVE_COMPRESSION=none keeps
# today’s uncompressed behaviour byte-for-byte. zstd for its fast DEcompress (every
# consumer pays that, the builder pays compress once). Level 3 = the zstd sweet spot.
case "${M6E_ARCHIVE_COMPRESSION:-none}" in
  none)
    ;;
  zstd)
    if ! command -v zstd >/dev/null 2>&1; then
      echo "buildah compress: zstd requested but binary missing artifact=${ARTIFACT_NAME} — falling back to uncompressed" >&2
    else
      _level="${M6E_ARCHIVE_COMPRESSION_LEVEL:-3}"
      echo "buildah compressing artifact=${ARTIFACT_NAME}.tar algo=zstd level=${_level}"
      # -T0: use all cores. --rm: remove the source .tar on success (the .zst is the
      # artifact that gets uploaded). -f: overwrite any stale .zst from a prior attempt.
      zstd -T0 -"${_level}" -f --rm "${ARTIFACT_NAME}.tar"
      echo "buildah compressed artifact=${ARTIFACT_NAME}.tar.zst"
    fi
    ;;
  *)
    echo "buildah compress: unknown M6E_ARCHIVE_COMPRESSION=${M6E_ARCHIVE_COMPRESSION} (expected none|zstd) — falling back to uncompressed" >&2
    ;;
esac

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
