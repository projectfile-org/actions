#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: populate the `label_args` array with the CANONICAL label
# set (OCI standard + org.m6e.ci.* + the projectfile's ext.m6e.build.labels),
# computed by the pf-cli/git resolver VENDORED at lib/oci-labels.sh (a copy of
# the m6e/container script) — so this action needs NO m6e submodule clone. The
# vendored resolver degrades to git-only labels when pf-cli is absent (the same
# behaviour as the make plane). SHARED by every container-build backend. SOURCED,
# not executed: the caller owns `set -euo pipefail` and must have sourced
# forge.sh first (M6E_BUILD_BY).

label_args=()
labels_script="${GITHUB_ACTION_PATH}/../lib/oci-labels.sh"
if [ -x "${labels_script}" ]; then
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    echo "label ${line%%=*}"                   # log the KEY; values can be long
    label_args+=(--label "${line}")
  done < <("${labels_script}" || true)
else
  echo "labels skipped: ${labels_script} not present"
fi
echo "parsed label_args=${#label_args[@]} build-by=${M6E_BUILD_BY:-unset}"
