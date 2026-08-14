#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: resolve the DESTINATIONS this cell publishes to into two parallel
# arrays — the sink NAME (what a credential keys on) and the repository half of its ref
# (what every tag is pushed under). REFS carries one `<sink> <ref>` line per place the
# route declares, each ref COMPOSED by the document that declared the sink, so no action
# assumes a path shape and one build can land nested on GHCR and flattened on Docker Hub.
# REGISTRY + IMAGE stay the single-destination spelling a project with no publish route
# still uses. SINK is this CELL's own destination on the publish axis: the cell owns one
# ref and skips the rest, so a registry refusing a push fails ITS cell, not the release.
#
# SHARED by oci-push and oci-manifest: the index must be assembled at exactly the
# repository the per-arch tags were pushed to, and two copies of this rule could disagree
# without either action failing. SOURCED, not executed — it populates the caller's arrays
# and `return 1`s into the caller's `set -e`.

sink_names=()
sink_repos=()
# REFS/SINK are action-input env vars, not locals — the SC2153 lowercase-lookalike hint
# (sink_names) is a false positive here.
# shellcheck disable=SC2153
if [ -n "${REFS:-}" ]; then
  while read -r _sink _ref; do
    [ -n "${_ref}" ] || continue
    if [ -n "${SINK:-}" ] && [ "${_sink}" != "${SINK}" ]; then
      echo "${OCI_ACTION} skipping sink=${_sink} — this cell publishes sink=${SINK}"
      continue
    fi
    sink_names+=("${_sink}")
    # A composed ref may carry the plane's tag; the cascade supplies its own, so only
    # the repository half is kept.
    sink_repos+=("${_ref%:*}")
  done <<< "${REFS}"
  # A cell whose sink names no ref must STOP: the axis and the refs list were composed
  # from one document, so disagreement means the workflow is stale, and falling through
  # to the single-destination path would publish under a name nobody declared.
  if [ -n "${SINK:-}" ] && [ "${#sink_repos[@]}" -eq 0 ]; then
    echo "${OCI_ACTION}: no ref declared for sink=${SINK} — cell axis and refs disagree" >&2
    return 1
  fi
fi
if [ "${#sink_repos[@]}" -eq 0 ]; then
  : "${IMAGE:?${OCI_ACTION}: IMAGE (the basename ref) is required when REFS is empty}"
  _legacy="${IMAGE%:*}"
  if [ -n "${REGISTRY:-}" ]; then
    _legacy="${REGISTRY}/${_legacy}"
  fi
  sink_names+=("")
  sink_repos+=("${_legacy}")
fi
echo "${OCI_ACTION} destinations=${#sink_repos[@]} sinks=[${sink_names[*]}] repos=[${sink_repos[*]}]"
