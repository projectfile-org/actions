#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: assemble the `--build-arg` flags for a container build from
# two action inputs, so the rendered workflow stays DECLARATIVE (no inline decomment/
# grep — that shell lives HERE).
#   $BUILD_ARGS  newline-separated NAME=VALUE pairs; passed as `--build-arg NAME=VALUE`.
#                The VALUE rides the input because a composite action does NOT inherit
#                the caller job's `env:` as process env (the Forgejo runner drops it) —
#                a by-NAME `--build-arg NAME` passthrough would read an UNSET var and
#                build with empty args (silently wrong: e.g. a matrix series defaulting).
#                A bare NAME (no `=`) falls back to buildx/buildah reading it from env.
#                A `NAME=` with an EMPTY value is SKIPPED, not forwarded: Docker only
#                falls through to the Dockerfile's own `ARG NAME=<default>` when the
#                flag is absent entirely — an explicit `--build-arg NAME=` always wins,
#                even over a non-empty Dockerfile default (e.g. a curated mirror URL or
#                locale list). The render emits `NAME=${{ x || y }}`, which resolves to
#                exactly this empty form whenever neither side is set — mirrors the
#                make-plane backends (buildx-build/buildah-build's own `[ -n "${_def}" ]`).
#   $FILE_ARGS   `NAME=path` specs; the value is the first non-comment, non-blank line
#                of path (the per-cell digest pin), read at build time from the checkout.
# SHARED by every container-build backend (buildx, buildah) so this lives in one
# place. SOURCED, not executed: it populates the caller's `build_args` array, so the
# caller owns `set -euo pipefail`.

build_args=()
# BUILD_ARGS / FILE_ARGS / ARTIFACT_NAME / CONTEXT are action-input env vars, not
# locals — the SC2153 lowercase-lookalike hint (build_args) is a false positive here.
# shellcheck disable=SC2153
while IFS= read -r pair; do                     # one NAME=VALUE per line
  [ -n "${pair}" ] || continue                  # tolerate blank lines / empty input
  case "${pair}" in
    *=*) ;;                                     # NAME=VALUE form, handled below
    *) echo "build-arg name=${pair} (env)"; build_args+=(--build-arg "${pair}"); continue ;;
  esac
  _name="${pair%%=*}"
  _val="${pair#*=}"
  if [ -z "${_val}" ]; then                     # let the Dockerfile's own ARG default win
    echo "build-arg name=${_name} (empty — skipped, Dockerfile default applies)"
    continue
  fi
  # Log NAME always; for cache-backend vars also log the VALUE LENGTH (not the
  # value) so an empty-at-source endpoint is diagnosable without leaking it.
  case "${_name}" in
    SCCACHE_REDIS_ENDPOINT|CCACHE_REMOTE_STORAGE|SCCACHE_BUCKET|SCCACHE_MEMCACHED_ENDPOINT)
      echo "build-arg name=${_name} value-len=${#_val}" ;;
    *)
      echo "build-arg name=${_name}" ;;
  esac
  build_args+=(--build-arg "${pair}")           # NAME=VALUE
done <<< "${BUILD_ARGS:-}"
unset _name _val

read -ra _files <<< "${FILE_ARGS:-}"           # whitespace-split the NAME=path list
for spec in "${_files[@]}"; do
  [ -n "${spec}" ] || continue
  name="${spec%%=*}"                           # arg NAME (left of the first =)
  path="${spec#*=}"                            # repo path (right of the first =)
  # First meaningful line: drop comments and blanks, strip surrounding whitespace.
  value="$(grep -v '^[[:space:]]*#' "${path}" | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')"
  echo "file-arg name=${name} path=${path} value=${value}"   # log every decision with its variables
  build_args+=(--build-arg "${name}=${value}")
done
# SOURCE_DATE_EPOCH is intentionally NOT forwarded as a build-arg: on BuildKit
# that only freezes the image's `created` field to the epoch (a dead 1970 date at
# 0) without clamping layer contents. `created` is left as the real build time
# (the backends `env -u SOURCE_DATE_EPOCH`); the fleet Dockerfiles no longer even
# declare the ARG.

# M6E_VERSION: the build version stamped BOTH into the image's OCI version label
# and the ldflags of every binary the image ships. DERIVED from the checkout by
# the ONE shared resolver VENDORED at lib/m6e-version.sh (exact git tag → short
# commit sha) — the SAME script the vendored oci-labels.sh uses — so the label
# and the binary never disagree, and an untagged push carries a real commit sha
# instead of the branch name a ${{ github.ref_name }} build-arg would leak. No
# m6e submodule needed. Skipped when the caller already listed M6E_VERSION.
version_script="${GITHUB_ACTION_PATH}/../lib/m6e-version.sh"
if ! grep -q '^M6E_VERSION' <<<"${BUILD_ARGS:-}"; then
  if [ -x "${version_script}" ]; then
    m6e_version="$("${version_script}" 2>/dev/null || true)"
    if [ -n "${m6e_version}" ]; then
      echo "build-arg name=M6E_VERSION (resolved=${m6e_version})"
      build_args+=(--build-arg "M6E_VERSION=${m6e_version}")
    else
      echo "M6E_VERSION resolver produced no value — build-arg skipped"
    fi
  else
    echo "M6E_VERSION resolver absent (${version_script}) — build-arg skipped"
  fi
fi
echo "parsed build_args=${#build_args[@]} artifact=${ARTIFACT_NAME} context=${CONTEXT}"
