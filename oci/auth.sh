#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: log in to every destination this cell publishes to, up front, into
# ONE containers/image auth file (Docker config format) that skopeo and buildah both
# read. Credentials key on the SINK NAME, never the host: two accounts on one registry
# need two secrets, which a host-keyed scheme cannot hold. `<SINK>_REGISTRY_USERNAME` /
# `_PASSWORD` win when bound; the unprefixed pair stays the fleet default, so a
# single-destination project binds nothing new. The password goes in on stdin, never in
# argv, so it cannot reach a process listing or a log.
#
# A failed login aborts before any copy or push: half a fan-out is worse than none.
# SOURCED, not executed — the authfile is the CALLER's (its EXIT trap wipes it, so the
# credential never outlives the job), and a failure `return 1`s into the caller's `set -e`.

_oci_cred() {                                # $1 sink, $2 USERNAME|PASSWORD → value
  local _sink="$1" _kind="$2" _name
  if [ -n "${_sink}" ]; then
    _name="$(printf '%s' "${_sink}" | tr '[:lower:]-' '[:upper:]_')_REGISTRY_${_kind}"
    if [ -n "${!_name:-}" ]; then
      printf '%s' "${!_name}"
      return 0
    fi
  fi
  _name="REGISTRY_${_kind}"
  printf '%s' "${!_name:-}"
}

# The registry to log in to is the ref's own first component. A first component carrying
# no `.`, no `:` and not `localhost` is a Docker Hub NAMESPACE rather than a host — the
# same reference grammar the build plane refuses a bare word under.
_oci_login_server() {                        # $1 repo ref → server
  local _head="${1%%/*}"
  case "${_head}" in
    localhost|*.*|*:*) printf '%s' "${_head}" ;;
    *) printf 'docker.io' ;;
  esac
}

# sink_names/sink_repos are the caller's, populated by oci/sinks.sh before this is
# sourced — the arrays cross a file boundary shellcheck cannot follow.
# shellcheck disable=SC2154
oci_login() {                                # $1 authfile → log in to every sink_repos[]
  local _authfile="$1" _i _sink _server _user _pass
  # mktemp leaves a ZERO-BYTE file; skopeo login READS the authfile (to merge the new
  # entry) before writing, and empty is not valid JSON. Seed an empty Docker-config
  # object so that read parses.
  printf '{}' > "${_authfile}"
  for _i in "${!sink_repos[@]}"; do
    _sink="${sink_names[${_i}]}"
    _server="$(_oci_login_server "${sink_repos[${_i}]}")"
    _user="$(_oci_cred "${_sink}" USERNAME)"
    _pass="$(_oci_cred "${_sink}" PASSWORD)"
    if [ -z "${_user}" ] || [ -z "${_pass}" ]; then
      echo "${OCI_ACTION}: no credentials for sink=${_sink:-<default>} server=${_server} — bind ${_sink:+$(printf '%s' "${_sink}" | tr '[:lower:]-' '[:upper:]_')_}REGISTRY_USERNAME/_PASSWORD" >&2
      return 1
    fi
    echo "${OCI_ACTION} logging in sink=${_sink:-<default>} server=${_server} user=${_user}"
    printf '%s' "${_pass}" | skopeo login --authfile "${_authfile}"               \
      --username "${_user}" --password-stdin "${_server}"
  done
}
