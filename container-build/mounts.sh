#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: satisfy each ABSTRACT bind declared in $MOUNTS (the newline
# name=mountpoint list ci-resolver lowers from a tool's `mounts` map) with a
# throwaway EMPTY directory and a `--build-context <name>=<dir>` flag. On an
# ephemeral CI runner there is no seeded cache, so every declared bind is empty —
# a Dockerfile `RUN --mount=from=<name>` then sees an empty mount and downloads
# fresh. The mountpoint (the map value) is Dockerfile-internal, carried for engines
# that need it but unused here. SHARED by every container-build backend (buildx,
# buildah both take --build-context) so the realisation lives in one place. SOURCED,
# not executed: it populates the caller's `build_contexts` array, so the caller owns
# `set -euo pipefail`.

build_contexts=()
# MOUNTS is an action-input env var, not a local — the SC2153 lowercase-lookalike
# hint (build_contexts) is a false positive here.
# shellcheck disable=SC2153
read -ra _mounts <<< "${MOUNTS:-}"        # whitespace-split the name=mountpoint list
for pair in "${_mounts[@]}"; do
  [ -n "${pair}" ] || continue          # tolerate an empty/space-only list
  name="${pair%%=*}"                     # bind NAME (left of =); mountpoint is Dockerfile-internal
  dir="$(mktemp -d)"                     # empty ephemeral source for this bind
  echo "mount bind name=${name} source=${dir} (empty)"   # log every decision with its variable
  build_contexts+=(--build-context "${name}=${dir}")
done
echo "parsed build_contexts=${#build_contexts[@]}"
