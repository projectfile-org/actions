#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: lower the git VERSION into the SET of tags this release publishes.
# A STABLE semver X.Y.Z fans out to the moving heads X and X.Y plus `latest`, so
# consumers can pin loosely (`:1`, `:1.0`) or float (`:latest`). A PRE-RELEASE
# (X.Y.Z-rc1, build metadata, …) or any non-semver tag publishes ONLY its exact
# spelling — an rc must never move `latest` or a release head. A leading `v` is stripped
# (v1.2.3 == 1.2.3). EMPTY VERSION (not a tag build — defensive: publish is gated
# tag-only) degrades to the single load-tag push.
#
# SHARED by oci-push and oci-manifest and load-bearing for both: the index is pushed to
# every tag of the SAME cascade the per-arch images were pushed under, so a second copy
# of this derivation could silently leave `latest` an image while `1.2.3` is an index.
# SOURCED, not executed: it populates the caller's `tags` array.

ver="${VERSION#v}"
tags=()
if [ -z "${VERSION:-}" ]; then
  # No cascade: the load tag carried by the basename ref. A ref with no `:tag` half
  # would silently become a tag spelled like a repository path, so refuse it.
  case "${IMAGE:-}" in
    *:*) tags=("${IMAGE##*:}") ;;
    *) echo "${OCI_ACTION}: VERSION is empty and image=${IMAGE:-<unset>} carries no :tag to fall back on" >&2
       return 1 ;;
  esac
elif [[ "${ver}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  tags=("${ver}" "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" latest)
else
  tags=("${ver}")                            # pre-release / non-semver: exact only
fi

# One build cell per architecture, so the per-arch push suffixes every tag it publishes —
# `latest-arm64` as much as `1.2.3-arm64`. Without it all three cells push the SAME refs
# and the last one silently wins. The manifest list is the UNSUFFIXED tag, an index over
# exactly these, so both ends compose the suffix here.
oci_arch_tag() {                             # $1 tag, $2 arch (empty => unsuffixed)
  printf '%s%s' "$1" "${2:+-$2}"
}

echo "${OCI_ACTION} version=${VERSION:-<none>} cascade=[${tags[*]}]"
