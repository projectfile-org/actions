#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: turn the per-architecture tags one release pushed
# (`<repo>:<tag>-amd64`, `-arm64`, `-riscv64`) into the manifest list consumers pull,
# at the unsuffixed `<repo>:<tag>` — for EVERY tag of the semver cascade, not just the
# release one, because `latest` is the tag every child image FROMs. The per-arch tags
# stay real published tags; the list is an index over them.
#
# Nothing here handles a tar: the images are already at the registry, so the list is
# built from remote references (`buildah manifest add docker://…`) and pushed back. That
# is what keeps the single-image docker-archive contract intact for the two scanners,
# the live test and oci-push — the multi-arch object exists only registry-side.
#
# The registry is the only witness: every pushed list is read back and asserted to be an
# index carrying exactly the declared architecture set. Nothing upstream can catch a bad
# index — each per-arch image is individually correct and verifies clean.
set -euo pipefail

# Names every shared oci/ library logs and fails under.
OCI_ACTION=oci-manifest

# No declared architecture set => no per-arch tags exist, the unsuffixed tag IS the image
# oci-push pushed, and an index over one manifest would REPLACE that image with a
# pointless wrapper. The ~110 projects that declare nothing take this path.
read -ra arches <<< "${ARCHES:-}"
if [ "${#arches[@]}" -eq 0 ]; then
  echo "${OCI_ACTION}: no architecture declared for image=${IMAGE:-<unset>} — nothing to index"
  exit 0
fi

# Destinations (sink_names/sink_repos) — the SAME route oci-push published under.
# shellcheck source-path=SCRIPTDIR source=../oci/sinks.sh
source "${GITHUB_ACTION_PATH}/../oci/sinks.sh"

# buildah and skopeo read the same containers/image auth file. The EXIT trap wipes it so
# the credential never persists past the job.
authfile="$(mktemp)"
trap 'rm -f "${authfile}"' EXIT
# shellcheck source-path=SCRIPTDIR source=../oci/auth.sh
source "${GITHUB_ACTION_PATH}/../oci/auth.sh"
oci_login "${authfile}"

# The semver cascade (tags[]), BARE — oci_arch_tag composes each member's suffix below.
# shellcheck source-path=SCRIPTDIR source=../oci/tags.sh
source "${GITHUB_ACTION_PATH}/../oci/tags.sh"
# shellcheck source-path=SCRIPTDIR source=../oci/retry.sh
source "${GITHUB_ACTION_PATH}/../oci/retry.sh"

# `manifest create` refuses a name already in local storage, so each list gets a name
# unique to this run AND this destination/tag pair — a re-run of a failed release must
# not trip over the list its predecessor left behind, and the reap after each push is
# best-effort by design (a killed job leaves storage behind; the name never collides).
list_seq=0

# The list is pushed in v2s2 (a Docker manifest LIST) to match its members: oci-push
# forces v2s2 on every per-arch image because the OCI image spec carries no HEALTHCHECK
# field, and an OCI index over Docker manifests is a mix no consumer needs to meet.
for _repo in "${sink_repos[@]}"; do
for t in "${tags[@]}"; do
  list_seq=$((list_seq + 1))
  list="oci-manifest-${GITHUB_RUN_ID:-local}-${list_seq}"
  buildah manifest rm "${list}" > /dev/null 2>&1 || true
  buildah manifest create "${list}" > /dev/null
  for _arch in "${arches[@]}"; do
    member="${_repo}:$(oci_arch_tag "${t}" "${_arch}")"
    echo "${OCI_ACTION} adding member=${member} list=${list} arch=${_arch}"
    oci_retry "add member=${member}" buildah manifest add                       \
      --authfile "${authfile}" "${list}" "docker://${member}"
  done

  ref="${_repo}:${t}"
  echo "${OCI_ACTION} pushing list=${list} -> ref=${ref} arches=[${arches[*]}] format=v2s2"
  oci_retry "push ref=${ref}" buildah manifest push --all --format v2s2         \
    --authfile "${authfile}" "${list}" "docker://${ref}"
  buildah manifest rm "${list}" > /dev/null

  # Read the index back from the registry and assert it carries exactly the declared
  # set. A missing architecture here means a build cell published nothing while the job
  # still went green; a surplus means a stale member from an earlier release survived.
  # M6E_PUBLISH_VERIFY=N opts out, the same knob oci-push's config check answers to.
  if [ "${M6E_PUBLISH_VERIFY:-Y}" != "N" ]; then
    _want="$(printf '%s\n' "${arches[@]}" | sort -u | paste -sd, -)"
    _live="$(skopeo inspect --raw --authfile "${authfile}" "docker://${ref}" |
      jq --raw-output '[.manifests[]?.platform.architecture] | unique | join(",")')"
    if [ "${_want}" != "${_live}" ]; then
      echo "${OCI_ACTION} VERIFY FAILED ref=${ref} — the registry serves arches=[${_live:-<not an index>}], declared=[${_want}]" >&2
      exit 1
    fi
    echo "${OCI_ACTION} verified ref=${ref} arches=[${_live}]"
  fi
done
done

echo "${OCI_ACTION} indexed destinations=${#sink_repos[@]} tags=[${tags[*]}] arches=[${arches[*]}]"
