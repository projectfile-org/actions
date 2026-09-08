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
# A BRANCH build takes precedence over every arm below and publishes ONE mutable tag:
# `edge` on the trunk (a PRIMARY name), `latest-<branch>` on any other branch.
# Load-bearing for the multi-arch publish too: EVERY tag of the cascade must end up the
# same kind of object, so a `latest` left a plain image while `1.2.3` is a manifest list
# would be invisible to every consumer until one pulled on a foreign architecture.
# SOURCED, not executed: it populates the caller's `tags` array.

ver="${VERSION#v}"
tags=()
on_trunk=N
if [ -n "${PREVIEW:-}" ]; then
  case " ${PRIMARY:-} " in                   # padded both sides: a whole name, never a prefix
    *" ${PREVIEW} "*) on_trunk=Y ;;
  esac
fi
if [ "${on_trunk}" = Y ]; then
  tags=(edge)                                # fixed, so it survives the trunk being renamed
elif [ -n "${PREVIEW:-}" ]; then
  # Checked BEFORE the semver arm because a BRANCH may be named like a version
  # (`1.27.0`, `release-2`): taking the cascade there would move `latest` and every
  # release head to an unreviewed branch build. The `latest-` prefix is structural, not
  # cosmetic — it is what keeps a preview tag impossible to mistake for a release one in
  # a tag list nobody can delete (most registries, this workspace's own included, cannot
  # remove a tag at all).
  #
  # OCI accepts [a-zA-Z0-9._-] in a tag and a branch name accepts far more (the `/` in
  # feature/x, and worse), so every other byte flattens to `-` — the same rule the make
  # plane's M6E_GIT_BRANCH_SANITIZED applies. Clamped well inside the 128-char tag limit,
  # which the `latest-` prefix already eats into.
  preview_slug="$(printf '%s' "${PREVIEW}" | tr --complement 'a-zA-Z0-9._-' '-' | cut --characters=1-110)"
  tags=("latest-${preview_slug}")
elif [ -z "${VERSION:-}" ]; then
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

echo "${OCI_ACTION} version=${VERSION:-<none>} preview=${PREVIEW:-<none>} trunk=${on_trunk} cascade=[${tags[*]}]"
