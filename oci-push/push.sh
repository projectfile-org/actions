#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: take this cell's OCI archive (already pulled by ci-resolver's
# download-artifact step) and publish it DIRECTLY to the registry with skopeo —
# `skopeo copy docker-archive:<tar> docker://<ref>` copies the archive to the
# registry WITHOUT ever loading it into the daemon's image store. The previous
# load+retag+push left a tagged copy (and a dangling retag-orphan) on the shared
# forgejo runner's persistent store on EVERY release — the publish job was the
# single biggest disk-bloat source. skopeo's docker-archive transport reads the
# SAME docker-format tar buildah/buildx emit (backend-agnostic, like the old
# `docker load`), and renames it to each push ref, so only the dest tag matters.
# Log in with the credentials the job env carries (password on stdin → never in
# argv/logs), then copy the archive to every tag in the SEMVER cascade derived
# from the git VERSION (stable X.Y.Z -> X.Y.Z + X.Y + X + latest; pre-release /
# non-semver -> exact only). No build here — the image was built once upstream;
# this is the pure publish hand-off.
set -euo pipefail

archive="${ARTIFACT_NAME}.tar"
: "${IMAGE:?oci-push: IMAGE (the basename ref) is required}"
: "${REGISTRY_USERNAME:?oci-push: REGISTRY_USERNAME must be bound (credentials overlay)}"
: "${REGISTRY_PASSWORD:?oci-push: REGISTRY_PASSWORD must be bound (credentials overlay)}"

# skopeo’s docker-archive: transport requires a seekable UNcompressed file (it does
# random-access Seek on the tar, and --dest-compress is silently ignored for this
# transport). The download step may have fetched a compressed .tar.zst (when the build
# ran with M6E_ARCHIVE_COMPRESSION=zstd for smaller upload/download); decompress it to
# the plain .tar skopeo reads. Only the build→publish hop used compression; this is the
# single place that must undo it. ${decompressed} flags the temp for trap cleanup so the
# ORIGINAL downloaded .tar.zst is never deleted (only our derived .tar is).
decompressed=
if [ -f "${ARTIFACT_NAME}.tar.zst" ]; then
  echo "oci-push decompressing archive=${ARTIFACT_NAME}.tar.zst -> ${archive} (skopeo needs seekable uncompressed)"
  zstd -d "${ARTIFACT_NAME}.tar.zst" -o "${archive}" -f
  decompressed=1
fi

# skopeo holds registry creds in an auth file (Docker config format, password
# base64). mktemp on the runner's disk-backed /tmp; the EXIT trap wipes it so the
# credential never persists past the job (a load+retag left no creds behind, and
# neither does this). digestfile receives the pushed manifest digest (identical
# for every cascade tag — same content), read once after the loop.
authfile="$(mktemp)"
digestfile="$(mktemp)"
trap 'rm -f "${authfile}" "${digestfile}"${decompressed:+ "${ARTIFACT_NAME}.tar"}' EXIT

# mktemp leaves a ZERO-BYTE file; skopeo login READS the authfile (to merge the new
# entry) before writing, and empty is not valid JSON — "unexpected end of JSON input".
# Seed an empty Docker-config object so that read parses (a missing file would be fine,
# but mktemp already created it, and re-creating racily is worse than seeding).
printf '{}' > "${authfile}"

# Login target + push prefix: a bare REGISTRY (empty) means Docker Hub. skopeo
# needs an explicit server for login (docker.io), whereas docker login defaulted
# silently; image_repo is the repo half prefixed with the registry when given.
login_server="${REGISTRY:-docker.io}"
echo "oci-push logging in server=${login_server} user=${REGISTRY_USERNAME} registry=${REGISTRY:-<docker-hub>}"
printf '%s' "${REGISTRY_PASSWORD}" | skopeo login --authfile "${authfile}"      \
  --username "${REGISTRY_USERNAME}" --password-stdin "${login_server}"

# Derive the repo path every cascade tag shares: the loaded ref minus its tag
# (everything left of the LAST colon), prefixed with the registry host when one
# is given (empty => Docker Hub, no prefix).
image_repo="${IMAGE%:*}"
if [ -n "${REGISTRY}" ]; then
  image_repo="${REGISTRY}/${image_repo}"
fi

# Lower the git VERSION into the tag set to publish. A STABLE semver X.Y.Z fans out
# to the moving heads X and X.Y plus `latest`, so consumers can pin loosely (`:1`,
# `:1.0`) or float (`:latest`). A PRE-RELEASE (X.Y.Z-rc1, build metadata, …) or any
# non-semver tag publishes ONLY its exact spelling — an rc must never move `latest`
# or a release head. A leading `v` is stripped (v1.2.3 == 1.2.3). EMPTY VERSION (not
# a tag build — defensive: publish is gated tag-only) degrades to the single load-tag
# push, the historical behaviour.
ver="${VERSION#v}"
tags=()
if [ -z "${VERSION}" ]; then
  tags=("${IMAGE##*:}")                                   # load tag (no cascade)
elif [[ "${ver}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  tags=("${ver}" "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" latest)
else
  tags=("${ver}")                                         # pre-release / non-semver: exact only
fi
echo "oci-push version=${VERSION:-<none>} repo=${image_repo} tags=[${tags[*]}]"

# Copy the archive to each cascade ref. A failed copy aborts (set -e) so a
# half-published cascade surfaces immediately rather than leaving a moved
# `latest` pointing at an unpushed digest. docker-archive reads the (single)
# image in the tar regardless of its stamped name; docker:// names it at the dest.
#
# --format v2s2: the OCI image spec HAS no healthcheck field, so an OCI manifest
# at the registry DROPS the b19 HEALTHCHECK — the third and last loss point,
# AFTER the two build-plane ones. skopeo defaults to the SOURCE format, which the
# docker-archive supplies as v2s2, so this looks like a no-op — it is not. skopeo
# must RE-compress the archive’s uncompressed layers for the registry, and one
# zstd layer (from the runner containers.conf, or a zstd blob already in the
# registry that skopeo reuses) makes v2s2 unrepresentable: Docker v2s2 has no
# zstd layer media type, so the copy silently converts the manifest to OCI and
# the healthcheck goes with it. Pinning the format alone would then FAIL the
# copy ("compression using zstd required together with format …v2s2, which does
# not support it"), so gzip is forced too — the only compression v2s2 carries.
# Together they make the published manifest deterministic, healthcheck included.
for t in "${tags[@]}"; do
  ref="${image_repo}:${t}"
  echo "oci-push copying archive=${archive} -> ref=${ref} format=v2s2 compression=gzip"
  skopeo copy --format v2s2                                                   \
    --dest-compress-format gzip --dest-force-compress-format                  \
    --dest-authfile "${authfile}" --digestfile "${digestfile}"                \
    "docker-archive:${archive}" "docker://${ref}"
done

# Emit the content digest of what we just published, so a downstream signer/attester
# targets the immutable ${repo}@sha256:… instead of a mutable tag (cosign MUST sign a
# digest — a tag could move under the signature). Every cascade tag points at the SAME
# image, so the digest is tag-independent: skopeo wrote it to ${digestfile} on each
# copy (same value). Threaded THREE honest ways so the consumer plane picks whichever:
#   * stdout log      — always, for the run transcript;
#   * $GITHUB_OUTPUT   — the forge step output (`steps.<id>.outputs.digest`, bare
#                        sha256:… — the conventional shape), when set;
#   * $M6E_DIGEST_FILE — a workspace file carrying the FULL repo@sha256 ref the fused
#                        cosign sign/attest step reads in-job (default image.digest).
digest="$(cat "${digestfile}")"
ref_by_digest="${image_repo}@${digest}"
echo "oci-push published ref=${ref_by_digest}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'digest=%s\n' "${digest}" >> "${GITHUB_OUTPUT}"
fi
printf '%s\n' "${ref_by_digest}" > "${M6E_DIGEST_FILE:-image.digest}"
