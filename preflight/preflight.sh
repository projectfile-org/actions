#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
set -euo pipefail

: "${PREFLIGHT_CHECK:?preflight: check is required}"
PREFLIGHT_RETRIES="${PREFLIGHT_RETRIES:-3}"
PREFLIGHT_TIMEOUT="${PREFLIGHT_TIMEOUT:-30}"
failures=()
warnings=0

log() { echo "preflight check=${PREFLIGHT_CHECK} $*"; }
fail() { echo "::error::preflight check=${PREFLIGHT_CHECK} $*" >&2; failures+=("$*"); }
warn() { echo "::warning::preflight check=${PREFLIGHT_CHECK} $*" >&2; warnings=$((warnings + 1)); }

# Exports each PREFLIGHT_* pair of the env input; any other name is refused.
while IFS= read -r pair; do
  [ -n "${pair}" ] || continue
  name="${pair%%=*}"
  if [[ "${pair}" != *=* || ! "${name}" =~ ^PREFLIGHT_[A-Z0-9_]+$ ]]; then
    warn "env pair ignored name=[${name}]"
    continue
  fi
  export "${name}=${pair#*=}"
  log "env ${name}=${pair#*=}"
done <<<"${PREFLIGHT_ENV:-}"

# Sleeps 2^attempt seconds plus up to one second of jitter.
backoff() { sleep "$((2 ** $1)).$((RANDOM % 10))"; }

# Qualifies a bare Docker Hub name and appends the tag unless the path already carries one.
compose_ref() {
  local image="$1" version="$2" ref
  ref="${image}"
  [[ "${version}" == - || "${image##*/}" == *:* ]] || ref="${image}:${version}"
  [[ "${ref%%/*}" == *[.:]* || "${ref%%/*}" == localhost ]] || ref="docker.io/${ref}"
  printf '%s' "${ref}"
}

# Exits 0 when version satisfies every comma-joined constraint of range.
in_range() {
  local version="${1#v}" range="$2" constraint op want low
  IFS=, read -r -a constraints <<<"${range}"
  for constraint in "${constraints[@]}"; do
    constraint="${constraint// /}"
    op="${constraint%%[0-9v]*}"
    want="${constraint#"${op}"}"
    want="${want#v}"
    low="$(printf '%s\n%s\n' "${version}" "${want}" | sort --version-sort | head --lines=1)"
    case "${op}" in
      '>=') [ "${low}" = "${want}" ] || return 1 ;;
      '>') if [ "${low}" != "${want}" ] || [ "${version}" = "${want}" ]; then return 1; fi ;;
      '<=') [ "${low}" = "${version}" ] || return 1 ;;
      '<') if [ "${low}" != "${version}" ] || [ "${version}" = "${want}" ]; then return 1; fi ;;
      '=' | '==' | '') [ "${version}" = "${want}" ] || return 1 ;;
      *) warn "range constraint unknown op=[${op}] constraint=${constraint}"; return 1 ;;
    esac
  done
}

# Names why skopeo could not read a ref: ABSENT, UNKNOWN (ghcr answers private and absent alike) or UNREACHABLE.
classify() {
  case "$1" in
    *"manifest unknown"* | *"not found"* | *"name unknown"*) echo ABSENT ;;
    *nauthorized* | *denied* | *"authentication required"* | *403*) echo UNKNOWN ;;
    *) echo UNREACHABLE ;;
  esac
}

check_image() {
  local image="$1" version="$2" commands="$3" requires="$4" ref sink err manifest digest key cache config provides label cmd
  ref="$(compose_ref "${image}" "${version}")"
  sink="${ref%%/*}"
  if [[ "${ref}" == *registry.invalid* ]]; then
    fail "image=${ref} sink=${sink} verdict=UNSET :: the image's registry variable has no value on this forge"
    return
  fi
  if ! manifest="$(timeout "${PREFLIGHT_TIMEOUT}" skopeo inspect --raw --retry-times "${PREFLIGHT_RETRIES}" "docker://${ref}" 2>"${errfile}")"; then
    err="$(tr '\n' ' ' <"${errfile}")"
    fail "image=${ref} sink=${sink} verdict=$(classify "${err}") :: ${err}"
    return
  fi
  digest="$(skopeo manifest-digest /dev/stdin <<<"${manifest}")"
  key="$(printf '%s %s' "${commands}" "${requires}" | sha256sum | cut --characters=1-16)"
  cache="${cache_dir}/${digest#*:}-${key}"
  if [ -f "${cache}" ]; then
    log "image=${ref} digest=${digest} verdict=ok cached=${cache}"
    return
  fi
  if ! config="$(timeout "${PREFLIGHT_TIMEOUT}" skopeo inspect --config --retry-times "${PREFLIGHT_RETRIES}" "docker://${ref}" 2>"${errfile}")"; then
    fail "image=${ref} sink=${sink} verdict=UNREADABLE :: $(tr '\n' ' ' <"${errfile}")"
    return
  fi
  label="$(jq --raw-output '.config.Labels["org.opencontainers.image.version"] // ""' <<<"${config}")"
  provides="$(jq --raw-output '.config.Labels["org.projectfile.provides"] // ""' <<<"${config}")"
  log "image=${ref} digest=${digest} version=[${label}] requires=[${requires}] provides=[${provides}]"
  local before="${#failures[@]}" warned="${warnings}"
  if [ "${requires}" != - ]; then
    if [[ ! "${label#v}" =~ ^[0-9] ]]; then
      warn "image=${ref} version=[${label}] is not a release version — range ${requires} unchecked"
    elif ! in_range "${label}" "${requires}"; then
      fail "image=${ref} sink=${sink} version=${label} outside requires=${requires}"
    fi
  fi
  if [ "${commands}" != - ]; then
    if [ -z "${provides}" ]; then
      warn "image=${ref} carries no org.projectfile.provides label — commands [${commands}] unchecked"
    else
      IFS=, read -r -a wanted <<<"${commands}"
      for cmd in "${wanted[@]}"; do
        [[ ",${provides}," == *",${cmd},"* ]] || warn "image=${ref} provides=[${provides}] lists no command=${cmd} — a PATH binary is not listed"
      done
    fi
  fi
  if [ "${#failures[@]}" -ne "${before}" ]; then
    return
  elif [ "${warnings}" -ne "${warned}" ]; then
    log "image=${ref} digest=${digest} verdict=ok-with-warnings cache-write=skipped"
  else
    printf '%s\n' "${ref}" >"${cache}.$$" && mv --force "${cache}.$$" "${cache}"
    log "image=${ref} digest=${digest} verdict=ok cache-write=${cache}"
  fi
}

check_images() {
  local image version commands requires
  command -v skopeo >/dev/null || { fail "skopeo absent on the runner"; return; }
  command -v jq >/dev/null || { fail "jq absent on the runner"; return; }
  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/preflight"
  mkdir --parents "${cache_dir}"
  errfile="$(mktemp)"
  # shellcheck disable=SC2064 # errfile is fixed by now
  trap "rm --force '${errfile}'" EXIT
  while read -r image version commands requires; do
    [ -n "${image:-}" ] || continue
    check_image "${image}" "${version:--}" "${commands:--}" "${requires:--}"
  done <<<"${PREFLIGHT_IMAGES:-}"
}

check_hosts() {
  local entry host port attempt
  for entry in ${PREFLIGHT_HOSTS:-}; do
    host="${entry%:*}" port="${entry##*:}"
    if [ -z "${host}" ] || [ -z "${port}" ] || [ "${host}" = "${entry}" ]; then
      log "host=[${entry}] skipped — host or port unset"
      continue
    fi
    for ((attempt = 1; ; attempt++)); do
      if timeout 5 bash -c "exec 3<>'/dev/tcp/${host}/${port}'" 2>/dev/null; then
        log "host=${host}:${port} verdict=ok attempt=${attempt}"
        break
      fi
      if [ "${attempt}" -ge "${PREFLIGHT_RETRIES}" ]; then
        fail "host=${host}:${port} verdict=UNREACHABLE attempts=${attempt}"
        break
      fi
      log "host=${host}:${port} attempt=${attempt}/${PREFLIGHT_RETRIES} failed — retrying"
      backoff "${attempt}"
    done
  done
}

check_disk() {
  local min="${PREFLIGHT_MIN_FREE_GIB:-10}" dir free root
  root="$(timeout 10 docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  for dir in "${GITHUB_WORKSPACE:-$PWD}" ${root:+"${root}"}; do
    if [ ! -d "${dir}" ]; then
      log "dir=${dir} skipped — not readable from the runner"
      continue
    fi
    free="$(df --output=avail --block-size=1G "${dir}" | tail --lines=1 | tr --delete ' ')"
    if [ "${free}" -lt "${min}" ]; then
      fail "dir=${dir} free=${free}GiB below min=${min}GiB"
    else
      log "dir=${dir} free=${free}GiB min=${min}GiB verdict=ok"
    fi
  done
}

case "${PREFLIGHT_CHECK}" in
  images) check_images ;;
  hosts) check_hosts ;;
  disk) check_disk ;;
  *) fail "unknown check — want images, hosts or disk" ;;
esac

if [ "${#failures[@]}" -gt 0 ]; then
  log "verdict=failed failures=${#failures[@]}"
  exit 1
fi
log "verdict=ok"
