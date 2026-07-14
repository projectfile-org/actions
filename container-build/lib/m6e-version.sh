#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# =============================================================================
# m6e-version.sh - The ONE build-version resolver (every plane, every artifact)
# =============================================================================
#
# Emits a SINGLE version string on stdout — the value that gets baked into every
# artifact so a Docker image, its OCI `version` label, and the Go/Crystal/etc
# binaries it ships all agree. Shared by BOTH build planes:
#   - make plane:  100-git-state.mk (the M6E_VERSION make var), buildx-build,
#                  buildah-build, and oci-labels.sh all source this ONE rule.
#   - forge plane: the projectfile/ci-actions container-build backend derives
#                  M6E_VERSION from the checkout here, exactly like it derives
#                  labels from the shared oci-labels.sh.
#
# Resolution order (first hit wins):
#   1. M6E_VERSION env, if non-empty      an explicit override always wins.
#   2. CI tag ref                         GITHUB_REF_TYPE=tag → GITHUB_REF_NAME.
#                                         These are process env on BOTH GHA and
#                                         Forgejo runners and survive a shallow
#                                         checkout that never fetched the tag.
#   3. exact git tag at HEAD              `git describe --exact-match --tags`.
#   4. short commit sha                   the untagged fallback — a real, TICKET-
#                                         able identifier instead of a static
#                                         "development" string.
#   5. no-commit                          a repo without commits (last resort).
#
# Cache-safety: steps 3-4 are DETERMINISTIC for a given commit (the same commit
# always yields the same tag/sha), so this value as a docker --build-arg does
# NOT bust the layer cache on a rebuild of the same commit — unlike `date +%s`.
# Two DIFFERENT commits differ, but then the source layer differs anyway.
#
# Environment:
#   PROJECT_ROOT   repo dir to read git state from (default: .)
#   M6E_VERSION    explicit override (step 1)
#   GITHUB_REF_TYPE / GITHUB_REF_NAME   CI tag ref (step 2)
#
# Degradation: every git call is guarded — a missing repo falls straight through
# to "no-commit"; this script never fails a build over version resolution.
# =============================================================================

set -euo pipefail

_ver_log() { printf 'm6e-version: %s\n' "$*" >&2; }

PROJECT_ROOT="${PROJECT_ROOT:-.}"

# 1. Explicit override — a caller that already knows the version wins outright.
if [ -n "${M6E_VERSION:-}" ]; then
    _ver_log "version from M6E_VERSION override: ${M6E_VERSION}"
    printf '%s\n' "${M6E_VERSION}"
    exit 0
fi

# 2. CI tag ref — resolves the tag even when the runner's shallow checkout never
#    fetched it, so a tag build stamps the tag and not the fallback sha.
if [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
    _ver_log "version from CI tag ref: ${GITHUB_REF_NAME}"
    printf '%s\n' "${GITHUB_REF_NAME}"
    exit 0
fi

# 3. Exact git tag on HEAD — the release case on any plane with a full checkout.
_tag="$(git -C "${PROJECT_ROOT}" describe --exact-match --tags HEAD 2>/dev/null || true)"
if [ -n "${_tag}" ]; then
    _ver_log "version from exact git tag: ${_tag}"
    printf '%s\n' "${_tag}"
    exit 0
fi

# 4. Short commit sha — the untagged fallback (deterministic, cache-safe).
_sha="$(git -C "${PROJECT_ROOT}" rev-parse --verify --quiet --short HEAD 2>/dev/null || true)"
if [ -n "${_sha}" ]; then
    _ver_log "version from short commit sha (untagged): ${_sha}"
    printf '%s\n' "${_sha}"
    exit 0
fi

# 5. No commits at all — last-resort sentinel, never a failure.
_ver_log "no git commit at root=${PROJECT_ROOT} — emitting no-commit"
printf '%s\n' "no-commit"
