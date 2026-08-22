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
# A PREVIEW narrows the result to the PRIMARY destination alone (see sink_primary).
# sink_repos may therefore come back EMPTY on a routed cell, which is not an error — the
# caller reads sink_routed to tell "this cell has nothing to publish" from "no route
# declared" and exits 0 on the first.
#
# SOURCED, not executed — it populates the caller's arrays and `return 1`s into the
# caller's `set -e`.

sink_names=()
sink_repos=()
# The FIRST destination the route declares. Already the primary everywhere else in this
# action — it carries the verify pass and the digest the signer reads — so it is also the
# only destination a preview may reach.
sink_primary=""
# Y once a route was declared, so an EMPTY sink list means "narrowed away", never
# "unrouted". Without it a preview that filtered every sink out would fall through to the
# single-destination path below and publish under a name nobody declared.
sink_routed=N
# Y once this cell's own SINK was found in REFS, which is what separates the two ways an
# empty list happens: a sink missing from the route is a stale workflow and must fail; a
# sink merely narrowed away by a preview is the feature working.
sink_seen=N
# REFS/SINK/PREVIEW are action-input env vars, not locals — the SC2153 lowercase-lookalike
# hint (sink_names) is a false positive here.
# shellcheck disable=SC2153
if [ -n "${REFS:-}" ]; then
  sink_routed=Y
  while read -r _sink _ref; do
    [ -n "${_ref}" ] || continue
    [ -n "${sink_primary}" ] || sink_primary="${_sink}"
    if [ -n "${SINK:-}" ] && [ "${_sink}" != "${SINK}" ]; then
      echo "${OCI_ACTION} skipping sink=${_sink} — this cell publishes sink=${SINK}"
      continue
    fi
    sink_seen=Y
    # A preview tag is PERMANENT on a registry that cannot delete tags, so it has no
    # business on a public mirror it was never meant to reach. Declaration order decides
    # which destination that leaves: the project already ordered its route.
    if [ -n "${PREVIEW:-}" ] && [ "${_sink}" != "${sink_primary}" ]; then
      echo "${OCI_ACTION} skipping sink=${_sink} — preview=${PREVIEW} publishes to primary sink=${sink_primary} only"
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
  if [ -n "${SINK:-}" ] && [ "${sink_seen}" = N ]; then
    echo "${OCI_ACTION}: no ref declared for sink=${SINK} — cell axis and refs disagree" >&2
    return 1
  fi
fi
if [ "${#sink_repos[@]}" -eq 0 ] && [ "${sink_routed}" = N ]; then
  : "${IMAGE:?${OCI_ACTION}: IMAGE (the basename ref) is required when REFS is empty}"
  _legacy="${IMAGE%:*}"
  if [ -n "${REGISTRY:-}" ]; then
    _legacy="${REGISTRY}/${_legacy}"
  fi
  sink_names+=("")
  sink_repos+=("${_legacy}")
fi
echo "${OCI_ACTION} destinations=${#sink_repos[@]} primary=${sink_primary:-<none>} sinks=[${sink_names[*]:-}] repos=[${sink_repos[*]:-}]"
