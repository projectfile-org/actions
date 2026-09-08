#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: take this cell's OCI archive (already pulled by pf-ci's
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
#
# With PREVIEW set the ref is a branch, not a tag: the cascade collapses to one mutable
# tag (`edge` on a trunk branch, else `latest-<branch>`) and only the PRIMARY destination
# receives it. A release moves `latest` and every semver head for every sink the route
# declares; a branch build moves nothing a consumer floats on, and stays on the one
# registry the project controls.
#
# With ARCHIVES set the cell holds one tar per DECLARED architecture and the same
# cascade is published as MANIFEST LISTS instead: buildah assembles the index locally
# and `manifest push --all` uploads members and index together, so the per-architecture
# images reach the registry carrying no tag of their own. That is the difference between
# a repository whose versions read `1.2.3` and one whose versions read `1.2.3-amd64`,
# `1.2.3-arm64`, `1.2.3-riscv64` — and the arch-suffixed spelling is unfixable after the
# fact, because most registries cannot delete a tag at all.
set -euo pipefail

# Names every shared oci/ library logs and fails under, so one transcript line always
# says WHICH action spoke.
OCI_ACTION=oci-push

# What this cell publishes, as two parallel arrays. ARCHIVES (one `<arch> <artifact-name>`
# line per DECLARED architecture) selects the manifest-list path: the tars are indexed
# into one multi-arch object per cascade tag, so the registry gains no `-<arch>` tag to
# carry forever. Empty keeps the single-image path, which is what the ~110 projects that
# declare no architecture have always taken.
arch_names=()
arch_stems=()
if [ -n "${ARCHIVES:-}" ]; then
  while read -r _arch _stem; do
    [ -n "${_stem}" ] || continue
    arch_names+=("${_arch}")
    arch_stems+=("${_stem}")
  done <<< "${ARCHIVES}"
fi
if [ "${#arch_stems[@]}" -eq 0 ]; then
  : "${ARTIFACT_NAME:?${OCI_ACTION}: artifact-name is required when archives is empty}"
  arch_names+=("")
  arch_stems+=("${ARTIFACT_NAME}")
fi

# Destinations (sink_names/sink_repos) — the route this cell publishes to.
# shellcheck source-path=SCRIPTDIR source=../oci/sinks.sh
source "${GITHUB_ACTION_PATH}/../oci/sinks.sh"

# Nothing to publish is a SUCCESS here, not a failure: on a preview the route narrowed
# every destination of this cell away (sinks.sh keeps the primary alone), and a publish
# axis renders one cell per declared sink whether or not the ref is a preview. Exit
# before mktemp and the registry login so a withheld cell costs no credential handling
# at all. sink_routed=N can never reach this — the single-destination fallback always
# yields one repo — so an empty list here is only ever the narrowing.
if [ "${#sink_repos[@]}" -eq 0 ]; then
  echo "${OCI_ACTION} preview=${PREVIEW:-<none>} sink=${SINK:-<all>} — no destination for this cell, nothing to publish"
  exit 0
fi

# skopeo holds registry creds in an auth file (Docker config format, password
# base64). mktemp on the runner's disk-backed /tmp; the EXIT trap wipes it so the
# credential never persists past the job (a load+retag left no creds behind, and
# neither does this). digestfile receives the pushed manifest digest (identical
# for every cascade tag — same content), read once after the loop.
authfile="$(mktemp)"
digestfile="$(mktemp)"
# Handed to the in-job cosign step, so it OUTLIVES this script the way the digest file does.
signer_dir="${M6E_REGISTRY_CONFIG_DIR:-.ci-secrets/registry}"
# Derived .tar files this run decompressed, so cleanup never deletes a DOWNLOADED
# artifact — only what we made from it.
derived=()
_oci_cleanup() {
  rm -f "${authfile}" "${digestfile}"
  [ "${#derived[@]}" -eq 0 ] || rm -f "${derived[@]}"
}
trap _oci_cleanup EXIT

# The docker-archive: transport requires a seekable UNcompressed file (it does
# random-access Seek on the tar, and --dest-compress is silently ignored for this
# transport). The download step may have fetched a compressed .tar.zst (when the build
# ran with M6E_ARCHIVE_COMPRESSION=zstd for smaller upload/download); decompress it to
# the plain .tar skopeo and buildah read. Only the build→publish hop used compression;
# this is the single place that must undo it. Sets `archive` rather than echoing it: a
# `$( )` capture would run the append to ${derived} in a subshell and lose every path.
oci_archive() {                              # $1 artifact stem → sets ${archive}
  archive="$1.tar"
  if [ -f "$1.tar.zst" ]; then
    echo "${OCI_ACTION} decompressing archive=$1.tar.zst -> ${archive} (docker-archive needs seekable uncompressed)"
    zstd -d "$1.tar.zst" -o "${archive}" -f
    derived+=("${archive}")
  fi
}

# One authfile holds every server, so each destination logs in once, up front.
# shellcheck source-path=SCRIPTDIR source=../oci/auth.sh
source "${GITHUB_ACTION_PATH}/../oci/auth.sh"
oci_login "${authfile}" "${signer_dir}"

# The FIRST destination is the primary: it carries the verify pass and the digest
# the signer reads. Declaration order is the route's order, so the project decides
# which registry that is.
image_repo="${sink_repos[0]}"

# The semver tag cascade (tags[]): every tag the release publishes, and — on the
# multi-arch path — every tag that must end up a manifest list, `latest` included,
# because that is the tag every child image FROMs.
# shellcheck source-path=SCRIPTDIR source=../oci/tags.sh
source "${GITHUB_ACTION_PATH}/../oci/tags.sh"
echo "oci-push repo=${image_repo} arches=[${arch_names[*]}] tags=[${tags[*]}]"

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
#
# Publish-hop verification: what the registry serves MUST be what we built. The
# push is a RE-ENCODE (layers re-compressed, manifest re-serialised), so it can
# silently downgrade the image — an OCI manifest carries no Healthcheck, OnBuild
# or Shell field and drops all three. NOTHING upstream can catch that: a linter
# or scanner run on the build artifact reads the tar, which is still correct, so
# it stays green while the published image is broken. The assertion only means
# something HERE, against the bytes the registry actually returns.
#
# Strict equality on the whole runtime config, not a healthcheck special-case:
# the publish must not alter the image AT ALL, so every dropped attribute is
# caught by the same rule and no future field needs a new check. Cost is one
# config blob (tens of KB) — `--config` fetches that descriptor alone, never the
# layers. M6E_PUBLISH_VERIFY=N opts out.
_published_config() {                       # $@ → skopeo transport + flags
  skopeo inspect --config --raw "$@" | jq --sort-keys '.config'
}

# Bounded registry copy: the publish is a network/process crossing, so a registry blip
# must not abort a whole release. ONLY the copy retries; login and verify stay
# single-shot.
# shellcheck source-path=SCRIPTDIR source=../oci/retry.sh
source "${GITHUB_ACTION_PATH}/../oci/retry.sh"

# MULTI-ARCH: assemble the index ONCE, then upload it to every destination. Assembly is
# local work that does not depend on where the result goes, so a per-destination rebuild
# would only repeat it. `manifest push --all` uploads the members AND the index together,
# which is what lets the per-architecture images reach the registry without ever holding
# a tag of their own — the whole point of this path.
arch_archives=()
if [ -n "${ARCHIVES:-}" ]; then
  # `manifest create` refuses a name already in local storage, so the list is named for
  # THIS run and reaped at the end: a re-run of a failed release must not trip over what
  # its predecessor left behind on a persistent runner.
  list="oci-push-${GITHUB_RUN_ID:-local}-$$"
  buildah manifest rm "${list}" > /dev/null 2>&1 || true
  buildah manifest create "${list}" > /dev/null
  for _i in "${!arch_stems[@]}"; do
    oci_archive "${arch_stems[_i]}"
    arch_archives+=("${archive}")
    echo "oci-push indexing arch=${arch_names[_i]} archive=${archive} list=${list}"
    buildah manifest add "${list}" "docker-archive:${archive}"
  done

  # The index must carry exactly the architectures the project declared. buildah reads
  # each member's architecture from that member's OWN config, so a build cell that
  # emitted the wrong arch (a --platform that never reached the builder, an emulation
  # misconfiguration) yields a WELL-FORMED index over the wrong images — every artifact
  # individually correct, which is precisely what no scanner or verify hop can catch.
  _want="$(printf '%s\n' "${arch_names[@]}" | sort -u | paste -sd, -)"
  _have="$(buildah manifest inspect "${list}" |
    jq --raw-output '[.manifests[].platform.architecture] | unique | join(",")')"
  if [ "${_want}" != "${_have}" ]; then
    echo "oci-push VERIFY FAILED list=${list} — the archives carry arches=[${_have}], declared=[${_want}]" >&2
    exit 1
  fi
  echo "oci-push assembled list=${list} arches=[${_have}] members=${#arch_stems[@]}"
else
  oci_archive "${arch_stems[0]}"             # the single image this cell publishes
fi

# Two dimensions, one archive: every DESTINATION the route declares, and within
# each the SEMVER cascade. The outer loop is what makes a build land nested on one
# registry and flattened on another from the same bits — the refs were composed by
# the document, so nothing here knows which is which.
#
# Verify after the very FIRST copy, before the rest: the cascade ends with `latest`
# (the tag consumers float on), so aborting here keeps a bad image off it. One
# verify covers every destination — the same archive is copied to all of them, so a
# re-encode defect shows on the first.
verified=
for _repo in "${sink_repos[@]}"; do
for t in "${tags[@]}"; do
  ref="${_repo}:${t}"
  if [ -n "${ARCHIVES:-}" ]; then
    echo "oci-push pushing list=${list} -> ref=${ref} arches=[${arch_names[*]}] format=v2s2 compression=gzip"
    oci_retry "push ref=${ref}" buildah manifest push --all --format v2s2     \
      --compression-format gzip                                               \
      --authfile "${authfile}" --digestfile "${digestfile}"                   \
      "${list}" "docker://${ref}"
  else
    echo "oci-push copying archive=${arch_stems[0]}.tar -> ref=${ref} format=v2s2 compression=gzip"
    oci_retry "copy ref=${ref}" skopeo copy --format v2s2                     \
      --dest-compress-format gzip --dest-force-compress-format                \
      --dest-authfile "${authfile}" --digestfile "${digestfile}"              \
      "docker-archive:${archive}" "docker://${ref}"
  fi

  if [ -z "${verified}" ] && [ "${M6E_PUBLISH_VERIFY:-Y}" != "N" ]; then
    verified="${_repo}@$(cat "${digestfile}")"
    echo "oci-push verifying ref=${verified} (published config vs built config)"
    if [ -n "${ARCHIVES:-}" ]; then
      # The registry is the only witness that the index IS one: a `manifest push` that
      # silently published a single image would leave every per-arch consumer pulling
      # the runner's architecture, and the local list would still inspect clean.
      _live_arches="$(skopeo inspect --raw --authfile "${authfile}" "docker://${verified}" |
        jq --raw-output '[.manifests[]?.platform.architecture] | unique | join(",")')"
      if [ "${_want}" != "${_live_arches}" ]; then
        echo "oci-push VERIFY FAILED ref=${verified} — the registry serves arches=[${_live_arches:-<not an index>}], declared=[${_want}]" >&2
        exit 1
      fi
      # Then the same strict config equality as the single-image path, per MEMBER: the
      # re-encode that drops a HEALTHCHECK does it one manifest at a time, and an index
      # whose members were downgraded is still a valid index.
      for _i in "${!arch_archives[@]}"; do
        _built="$(_published_config "docker-archive:${arch_archives[_i]}")"
        _live="$(_published_config --authfile "${authfile}"                   \
          --override-arch "${arch_names[_i]}" "docker://${verified}")"
        if [ "${_built}" != "${_live}" ]; then
          echo "oci-push VERIFY FAILED ref=${verified} arch=${arch_names[_i]} — the push altered the image config" >&2
          echo "oci-push  (< built, > published; a lost Healthcheck means the manifest was downgraded to oci)" >&2
          diff <(printf '%s\n' "${_built}") <(printf '%s\n' "${_live}") >&2 || true
          exit 1
        fi
      done
      echo "oci-push verified ref=${verified} arches=[${_live_arches}] config=identical"
    else
      _built="$(_published_config "docker-archive:${archive}")"
      _live="$(_published_config --authfile "${authfile}" "docker://${verified}")"
      if [ "${_built}" != "${_live}" ]; then
        echo "oci-push VERIFY FAILED ref=${verified} — the push altered the image config" >&2
        echo "oci-push  (< built, > published; a lost Healthcheck means the manifest was downgraded to oci)" >&2
        diff <(printf '%s\n' "${_built}") <(printf '%s\n' "${_live}") >&2 || true
        exit 1
      fi
      echo "oci-push verified ref=${verified} config=identical keys=$(printf '%s' "${_built}" | jq 'keys | length')"
    fi
  fi
done
done

# Reap the run-scoped list from local storage. Best-effort by design: a killed job leaves
# storage behind, and the name never collides with the next run's.
[ -z "${ARCHIVES:-}" ] || buildah manifest rm "${list}" > /dev/null 2>&1 || true

# Emit the content digest of what we just published, so a downstream signer/attester
# targets the immutable ${repo}@sha256:… instead of a mutable tag (cosign MUST sign a
# digest — a tag could move under the signature). Every cascade tag points at the SAME
# content, so the digest is tag-independent: skopeo (or buildah, on the multi-arch path,
# where it is the INDEX digest — what a consumer pulling the tag actually resolves, and
# a commitment to every member) wrote it to ${digestfile} on each push (same value).
# Threaded THREE honest ways so the consumer plane picks whichever:
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

# Export the tag cascade the same workspace-file way, for the events emit step
# pf-ci renders after this action (a tool declaring `emit:`). A downstream
# consumer must know WHICH tags moved — `latest` moving is a different fact from a
# patch tag appearing — and the cascade is derived HERE, from VERSION, so reading it
# back beats reimplementing the semver fan-out in the emitting step. A JSON array,
# because the envelope carries it verbatim; every element is a semver token or the
# load tag, so no element can carry a quote to escape.
tags_json="$(printf '"%s",' "${tags[@]}")"
printf '[%s]\n' "${tags_json%,}" > "${M6E_TAGS_FILE:-image.tags}"
