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

# Destinations. REFS carries one `<sink> <ref>` line per place this archive is
# published, each ref COMPOSED by the document that declared the sink — so this
# action never assumes a path shape, which is what lets one build land nested on
# GHCR and flattened on Docker Hub. REGISTRY + IMAGE remain the single-destination
# spelling: a project that declares no publish route still pushes exactly where it
# always did, and this file needs no branch beyond building the list.
sink_names=()
sink_repos=()
if [ -n "${REFS:-}" ]; then
  while read -r _sink _ref; do
    [ -n "${_ref}" ] || continue
    sink_names+=("${_sink}")
    # A composed ref may carry the plane's tag; the cascade below supplies its
    # own, so only the repository half is kept — the same rule as the legacy
    # path, applied in one place.
    sink_repos+=("${_ref%:*}")
  done <<< "${REFS}"
fi
if [ "${#sink_repos[@]}" -eq 0 ]; then
  : "${IMAGE:?oci-push: IMAGE (the basename ref) is required when REFS is empty}"
  # The historical composition: repo half of the load ref, prefixed with the
  # registry when one is given (empty => Docker Hub).
  _legacy="${IMAGE%:*}"
  if [ -n "${REGISTRY:-}" ]; then
    _legacy="${REGISTRY}/${_legacy}"
  fi
  sink_names+=("")
  sink_repos+=("${_legacy}")
fi

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

# Credentials key on the SINK NAME, never the host: two accounts on one registry
# need two secrets, which a host-keyed scheme cannot hold. <SINK>_REGISTRY_USERNAME
# / _PASSWORD win when bound; the unprefixed pair remains the fleet default, so a
# single-destination project binds nothing new.
_cred() {                                    # $1 sink, $2 USERNAME|PASSWORD → value
  local _sink="$1" _kind="$2" _name
  if [ -n "${_sink}" ]; then
    _name="$(printf '%s' "${_sink}" | tr '[:lower:]-' '[:upper:]_')_REGISTRY_${_kind}"
    if [ -n "${!_name:-}" ]; then
      printf '%s' "${!_name}"
      return 0
    fi
  fi
  _name="REGISTRY_${_kind}"
  printf '%s' "${!_name:-}"
}

# The registry to log in to is the ref's own first component. skopeo needs an
# explicit server, and a first component carrying no `.`, no `:` and not
# `localhost` is a Docker Hub NAMESPACE rather than a host — the same reference
# grammar the build plane refuses a bare word under.
_login_server() {                            # $1 repo ref → server
  local _head="${1%%/*}"
  case "${_head}" in
    localhost|*.*|*:*) printf '%s' "${_head}" ;;
    *) printf 'docker.io' ;;
  esac
}

# One authfile holds every server, so each destination logs in once, up front. A
# failed login aborts before any copy: half a fan-out is worse than none.
for _i in "${!sink_repos[@]}"; do
  _sink="${sink_names[${_i}]}"
  _server="$(_login_server "${sink_repos[${_i}]}")"
  _user="$(_cred "${_sink}" USERNAME)"
  _pass="$(_cred "${_sink}" PASSWORD)"
  if [ -z "${_user}" ] || [ -z "${_pass}" ]; then
    echo "oci-push: no credentials for sink=${_sink:-<default>} server=${_server} — bind ${_sink:+$(printf '%s' "${_sink}" | tr '[:lower:]-' '[:upper:]_')_}REGISTRY_USERNAME/_PASSWORD" >&2
    exit 1
  fi
  echo "oci-push logging in sink=${_sink:-<default>} server=${_server} user=${_user}"
  printf '%s' "${_pass}" | skopeo login --authfile "${authfile}"                \
    --username "${_user}" --password-stdin "${_server}"
done

# The FIRST destination is the primary: it carries the verify pass and the digest
# the signer reads. Declaration order is the route's order, so the project decides
# which registry that is.
image_repo="${sink_repos[0]}"

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

# Bounded registry copy: the publish is a network/process crossing, so a registry
# blip (a transient 500 mid blob upload, a dropped connection) must not abort a
# whole release. skopeo ships --retry-times, but containers/image does NOT treat
# every upload 5xx as retryable (a mid-session blob failure can be classified
# fatal), so the flag alone is unreliable for the exact failure seen here. Wrap
# the copy in a loop that ALWAYS retries, with exponential backoff+jitter (same
# shape as m6e's compose-pull) so a flapping registry costs seconds, not a
# rebuild. A copy is idempotent at the dest: re-uploading a blob the registry
# already has is a no-op, so retrying after a partial upload is safe. ONLY the
# copy retries; login and verify stay single-shot. M6E_OCI_PUSH_RETRIES=1 opts out.
_op_retries="${M6E_OCI_PUSH_RETRIES:-3}"
_op_backoff="${M6E_OCI_PUSH_BACKOFF:-2}"
_op_copy() {                                 # $@ → everything after `skopeo copy`
  local _attempt=1 _delay _rc
  while :; do
    # set +e: a failed copy is data for the retry test, not a script exit.
    set +e
    skopeo copy "$@"
    _rc=$?
    set -e
    [ "${_rc}" -eq 0 ] && return 0
    if [ "${_attempt}" -ge "${_op_retries}" ]; then
      echo "oci-push copy FAILED rc=${_rc} ref=${ref} attempts=${_attempt} exhausted" >&2
      return "${_rc}"
    fi
    _delay=$((_op_backoff * (2 ** (_attempt - 1)) + RANDOM % (_op_backoff + 1)))
    echo "oci-push copy failed rc=${_rc} ref=${ref} attempt=${_attempt}/${_op_retries} — retrying in ${_delay}s" >&2
    sleep "${_delay}"
    _attempt=$((_attempt + 1))
  done
}

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
  echo "oci-push copying archive=${archive} -> ref=${ref} format=v2s2 compression=gzip"
  _op_copy --format v2s2                                                      \
    --dest-compress-format gzip --dest-force-compress-format                  \
    --dest-authfile "${authfile}" --digestfile "${digestfile}"                \
    "docker-archive:${archive}" "docker://${ref}"

  if [ -z "${verified}" ] && [ "${M6E_PUBLISH_VERIFY:-Y}" != "N" ]; then
    verified="${_repo}@$(cat "${digestfile}")"
    echo "oci-push verifying ref=${verified} (published config vs built config)"
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
done
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

# Export the tag cascade the same workspace-file way, for the events emit step
# ci-resolver renders after this action (a tool declaring `emit:`). A downstream
# consumer must know WHICH tags moved — `latest` moving is a different fact from a
# patch tag appearing — and the cascade is derived HERE, from VERSION, so reading it
# back beats reimplementing the semver fan-out in the emitting step. A JSON array,
# because the envelope carries it verbatim; every element is a semver token or the
# load tag, so no element can carry a quote to escape.
tags_json="$(printf '"%s",' "${tags[@]}")"
printf '[%s]\n' "${tags_json%,}" > "${M6E_TAGS_FILE:-image.tags}"
