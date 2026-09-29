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
  kind=trunk
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
  kind=branch
elif [ -z "${VERSION:-}" ]; then
  # No cascade: the load tag carried by the basename ref. A ref with no `:tag` half
  # would silently become a tag spelled like a repository path, so refuse it.
  case "${IMAGE:-}" in
    *:*) tags=("${IMAGE##*:}"); kind=load ;;
    *) echo "${OCI_ACTION}: VERSION is empty and image=${IMAGE:-<unset>} carries no :tag to fall back on" >&2
       return 1 ;;
  esac
elif [[ "${ver}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  tags=("${ver}" "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" latest)
  kind=release major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
else
  tags=("${ver}")                            # pre-release / non-semver: exact only
  kind=prerelease
fi

echo "${OCI_ACTION} version=${VERSION:-<none>} preview=${PREVIEW:-<none>} trunk=${on_trunk} cascade=[${tags[*]}]"

# HEADS: one `<kind> <template>…` line per declared kind; a kind it omits keeps the cascade above
while read -r _kind _templates; do
  [ "${_kind}" = "${kind}" ] || continue
  read -r -a _tmpl <<< "${_templates}"
  tags=()
  for _t in "${_tmpl[@]}"; do
    _t="${_t//\$\{version\}/${ver}}"
    _t="${_t//\$\{major\}/${major:-}}"
    _t="${_t//\$\{minor\}/${minor:-}}"
    _t="${_t//\$\{patch\}/${patch:-}}"
    _t="${_t//\$\{branch\}/${preview_slug:-}}"
    [[ " ${tags[*]} " == *" ${_t} "* ]] || tags+=("${_t}")
  done
  echo "${OCI_ACTION} heads kind=${kind} templates=[${_templates}] heads=[${tags[*]}]"
done <<< "${HEADS:-}"

# VARIANT: one `<value> <default|->` line per variant part, in declared order
[ -n "${VARIANT:-}" ] || return 0
if [ -z "${VARIANT_TAG:-}" ]; then
  echo "${OCI_ACTION}: variant is set but variant-tag is empty" >&2
  return 1
fi
heads=("${tags[@]}")
v_vals=()
v_defs=()
while read -r _val _def; do
  [ -n "${_val}" ] || continue
  [ "${_def:--}" != "-" ] || _def=
  echo "${OCI_ACTION} variant part value=${_val} default=${_def:-<none>}"
  v_vals+=("${_val}")
  v_defs+=("${_def}")
done <<< "${VARIANT}"
_own_cell="${v_vals[*]}"

# Prints one variant per line for the cell whose part values are $@, aliases included when declared
_oci_variants() {
  local vals=("$@") out=("") next i v
  for i in "${!vals[@]}"; do
    next=()
    for v in "${out[@]}"; do
      next+=("${v:+${v}${VARIANT_JOIN:-}}${vals[i]}")
      [ "${VARIANT_ALIASES:-none}" != defaults ] || [ "${vals[i]}" != "${v_defs[i]}" ] || next+=("${v}")
    done
    out=("${next[@]}")
  done
  printf '%s\n' "${out[@]}"
}

# Prints the tag of head $1 and variant $2: the head alone, the bare variant, or the declared template
_oci_tag() {
  local t="${VARIANT_TAG}"
  if [ -z "$2" ]; then
    echo "$1"
  elif [[ " ${VARIANT_BARE:-} " == *" $1 "* ]]; then
    echo "$2"
  else
    t="${t//\$\{head\}/$1}"
    echo "${t//\$\{variant\}/$2}"
  fi
}

# VARIANT_CELLS: every cell this publish belongs to, part values space-joined; empty means this cell alone
mapfile -t cells < <(printf '%s\n' "${VARIANT_CELLS:-${_own_cell}}" | sed '/^[[:space:]]*$/d')
if [[ $'\n'"$(printf '%s\n' "${cells[@]}")"$'\n' != *$'\n'"${_own_cell}"$'\n'* ]]; then
  echo "${OCI_ACTION}: unknown-cell cell=[${_own_cell}] is not among variant-cells" >&2
  return 1
fi
echo "${OCI_ACTION} variant cells=${#cells[@]} join=[${VARIANT_JOIN:-}] aliases=${VARIANT_ALIASES:-none} tag=${VARIANT_TAG} bare=[${VARIANT_BARE:-}] heads=[${heads[*]}]"

declare -A _owner=()
tags=()
for _c in "${cells[@]}"; do
  read -r -a _cv <<< "${_c}"
  mapfile -t _vars < <(_oci_variants "${_cv[@]}")
  for _v in "${_vars[@]}"; do
    for _h in "${heads[@]}"; do
      # a head moves with the next build, so a variant spelled like one would move with it
      if [ -n "${_v}" ] && [ "${_h}" = "${_v}" ]; then
        echo "${OCI_ACTION}: head-is-variant head=${_h} equals variant=${_v} of cell=[${_c}]" >&2
        return 1
      fi
      _t="$(_oci_tag "${_h}" "${_v}")"
      if [[ ! "${_t}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]]; then
        echo "${OCI_ACTION}: tag=${_t} of cell=[${_c}] is not a valid OCI tag" >&2
        return 1
      fi
      if [ -n "${_owner[${_t}]:-}" ] && [ "${_owner[${_t}]}" != "${_c}" ]; then
        echo "${OCI_ACTION}: cell-collision tag=${_t} derived by cell=[${_owner[${_t}]}] and cell=[${_c}]" >&2
        return 1
      fi
      _owner[${_t}]="${_c}"
      [ "${_c}" != "${_own_cell}" ] || [[ " ${tags[*]} " == *" ${_t} "* ]] || tags+=("${_t}")
    done
  done
done
echo "${OCI_ACTION} variant cell=[${_own_cell}] tags=[${tags[*]}]"
