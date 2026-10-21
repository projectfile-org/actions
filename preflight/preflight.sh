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
passes=0
green='' yellow='' red='' reset=''
if [ -z "${NO_COLOR:-}${PREFLIGHT_NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
  green=$'\e[32m' yellow=$'\e[33m' red=$'\e[31m' reset=$'\e[0m'
fi

log() { echo "$*"; }
pass() { echo "${green}✓ $*${reset}"; passes=$((passes + 1)); }
fail() { echo "::error::✗ $*" >&2; failures+=("$*"); }
warn() { echo "::warning::⚠ $*" >&2; warnings=$((warnings + 1)); }

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
  [[ "${ref}" == */* && ("${ref%%/*}" == *[.:]* || "${ref%%/*}" == localhost) ]] || ref="docker.io/${ref}"
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

# Names why skopeo could not read a ref: TIMEOUT, ABSENT, UNKNOWN (ghcr answers private and absent alike) or UNREACHABLE.
classify() {
  [ "$1" -ne 124 ] || { echo TIMEOUT; return; }
  case "$2" in
    *"manifest unknown"* | *"not found"* | *"name unknown"*) echo ABSENT ;;
    *nauthorized* | *denied* | *"authentication required"* | *403*) echo UNKNOWN ;;
    *) echo UNREACHABLE ;;
  esac
}

# Reads skopeo inspect VIEW of REF into out with per-attempt timeout and backoff; fails ABSENT/UNKNOWN, warns on a transient end.
inspect() {
  local view="$1" ref="$2" sink="$3" attempt rc err verdict
  for ((attempt = 1; ; attempt++)); do
    rc=0
    out="$(timeout "${PREFLIGHT_TIMEOUT}" skopeo inspect "${view}" "docker://${ref}" 2>"${errfile}")" || rc=$?
    [ "${rc}" -ne 0 ] || return 0
    err="$(tr '\n' ' ' <"${errfile}")"
    [ "${rc}" -ne 124 ] || err="no answer within ${PREFLIGHT_TIMEOUT}s"
    err="${err:-skopeo exit=${rc} with no output}"
    verdict="$(classify "${rc}" "${err}")"
    case "${verdict}" in
      ABSENT | UNKNOWN) fail "image=${ref} sink=${sink} verdict=${verdict} :: ${err}"; return 1 ;;
    esac
    if [ "${attempt}" -ge "${PREFLIGHT_RETRIES}" ]; then
      warn "image=${ref} sink=${sink} verdict=${verdict} attempts=${attempt} unchecked — the job’s own pull decides :: ${err}"
      return 1
    fi
    log "↻ image=${ref} view=${view} attempt=${attempt}/${PREFLIGHT_RETRIES} verdict=${verdict} retrying :: ${err}"
    backoff "${attempt}"
  done
}

check_image() {
  local image="$1" version="$2" commands="$3" requires="$4" ref sink out digest key cache provides label cmd
  ref="$(compose_ref "${image}" "${version}")"
  sink="${ref%%/*}"
  if [[ "${ref}" == *registry.invalid* ]]; then
    fail "image=${ref} sink=${sink} verdict=UNSET :: the image's registry variable has no value on this forge"
    return
  fi
  inspect --raw "${ref}" "${sink}" || return 0
  digest="$(skopeo manifest-digest /dev/stdin <<<"${out}")"
  key="$(printf '%s %s' "${commands}" "${requires}" | sha256sum | cut --characters=1-16)"
  cache="${cache_dir}/${digest#*:}-${key}"
  if [ -f "${cache}" ]; then
    pass "image=${ref} digest=${digest:7:12} verdict=ok cached"
    return
  fi
  inspect --config "${ref}" "${sink}" || return 0
  label="$(jq --raw-output '.config.Labels["org.opencontainers.image.version"] // ""' <<<"${out}")"
  provides="$(jq --raw-output '.config.Labels["org.projectfile.provides"] // ""' <<<"${out}")"
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
      warn "image=${ref} version=[${label}] carries no org.projectfile.provides label — commands [${commands}] unchecked"
    else
      IFS=, read -r -a wanted <<<"${commands}"
      for cmd in "${wanted[@]}"; do
        [[ ",${provides}," == *",${cmd},"* ]] || warn "image=${ref} provides=[${provides}] lists no command=${cmd} — a PATH binary is not listed"
      done
    fi
  fi
  [ "${#failures[@]}" -eq "${before}" ] && [ "${warnings}" -eq "${warned}" ] || return 0
  printf '%s\n' "${ref}" >"${cache}.$$" && mv --force "${cache}.$$" "${cache}"
  pass "image=${ref} digest=${digest:7:12} version=[${label}] verdict=ok"
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
  local entry host port fallback attempt
  for entry in ${PREFLIGHT_HOSTS:-}; do
    IFS=: read -r host port fallback <<<"${entry}"
    port="${port:-${fallback:-}}"
    if [ -z "${host}" ] || [ -z "${port}" ]; then
      log "host=[${entry}] skipped — host unset or port without default"
      continue
    fi
    for ((attempt = 1; ; attempt++)); do
      if timeout 5 bash -c "exec 3<>'/dev/tcp/${host}/${port}'" 2>/dev/null; then
        pass "host=${host}:${port} verdict=ok attempt=${attempt}"
        break
      fi
      if [ "${attempt}" -ge "${PREFLIGHT_RETRIES}" ]; then
        fail "host=${host}:${port} verdict=UNREACHABLE attempts=${attempt}"
        break
      fi
      log "↻ host=${host}:${port} attempt=${attempt}/${PREFLIGHT_RETRIES} retrying"
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
      pass "dir=${dir} free=${free}GiB min=${min}GiB verdict=ok"
    fi
  done
}

case "${PREFLIGHT_CHECK}" in
  images) check_images ;;
  hosts) check_hosts ;;
  disk) check_disk ;;
  *) fail "unknown check — want images, hosts or disk" ;;
esac

totals="ok=${passes} warnings=${warnings} failures=${#failures[@]}"
if [ "${#failures[@]}" -gt 0 ]; then
  echo "${red}✗ preflight check=${PREFLIGHT_CHECK} verdict=failed ${totals}${reset}"
  for failure in "${failures[@]}"; do echo "${red}  ✗ ${failure}${reset}"; done
  exit 1
elif [ "${warnings}" -gt 0 ]; then
  echo "${yellow}⚠ preflight check=${PREFLIGHT_CHECK} verdict=ok ${totals}${reset}"
else
  echo "${green}✓ preflight check=${PREFLIGHT_CHECK} verdict=ok ${totals}${reset}"
fi
