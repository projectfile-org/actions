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
# Load-bearing for the multi-arch publish too: EVERY tag of the cascade must end up the
# same kind of object, so a `latest` left a plain image while `1.2.3` is a manifest list
# would be invisible to every consumer until one pulled on a foreign architecture.
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

echo "${OCI_ACTION} version=${VERSION:-<none>} cascade=[${tags[*]}]"
