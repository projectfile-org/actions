#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# =============================================================================
# oci-labels.sh - Canonical container image labels (every build pipeline)
# =============================================================================
#
# The ONE computation of image labels, shared by all four build planes:
# make+buildx, make+buildah, and the action library’s container-build
# backends on GHA/Forgejo. Emits one KEY=VALUE line per label on stdout;
# callers convert each line into a `--label` flag (docker buildx build /
# buildah build / buildah config). All diagnostics go to stderr.
#
# Labels emitted:
#   org.opencontainers.image.title        identity.title          (projectfile)
#   org.opencontainers.image.description  identity.summary        (projectfile)
#   org.opencontainers.image.licenses     license.spdx            (projectfile)
#   org.opencontainers.image.source       links[type=source-code].url (projectfile)
#   org.opencontainers.image.version      m6e-version.sh (env > CI tag > git tag > short sha)
#   org.opencontainers.image.revision     full git commit sha
#   org.opencontainers.image.created      real date: tag commit time, else build time (ISO-8601 UTC)
#   org.m6e.ci.build-by                   M6E_BUILD_BY pipeline id (make-buildx, gha-buildx, …)
#   org.m6e.ci.git-commit                 short git commit sha
#   <ext.m6e.build.labels{}>              user labels from the projectfile, verbatim
#
# Environment:
#   PROJECT_ROOT          project dir (default: .)
#   M6E_LABELS            N disables all emission (feature off switch)
#   M6E_BUILD_BY          pipeline id label value (default: unknown)
#   M6E_VERSION           version label override (else: CI tag ref, exact git tag, short sha)
#   M6E_PROJECTFILE_PATH  explicit projectfile (default: discover projectfile.{yaml,toml,json})
#   PF_CLI                pf-cli command override (default: pf-cli on PATH)
#   PF_CLI_IMAGE          container fallback when pf-cli is not installed (opt-in)
#   PF_CLI_ENTRYPOINT     binary to exec in PF_CLI_IMAGE (default: pf-cli)
#   M6E_CONTAINER_RUNTIME container runtime for the PF_CLI_IMAGE fallback (default: docker)
#   M6E_LABEL_TIMEOUT     seconds per pf-cli call — includes may fetch (default: 30)
#   M6E_LABEL_LANG        language for the localized title/summary (default: the
#                         projectfile's org.projectfile.i18n.default-language, else en)
#
# Degradation: a missing git repo, projectfile, or pf-cli skips ONLY the
# affected labels with a stderr note — a build never fails over a label source.
# =============================================================================

set -euo pipefail

_lbl_log() { printf 'oci-labels: %s\n' "$*" >&2; }

if [ "${M6E_LABELS:-Y}" = "N" ]; then
    _lbl_log "disabled via M6E_LABELS=N — emitting nothing"
    exit 0
fi

PROJECT_ROOT="${PROJECT_ROOT:-.}"
PROJECT_ROOT="$(cd "${PROJECT_ROOT}" && pwd)"
M6E_LABEL_TIMEOUT="${M6E_LABEL_TIMEOUT:-30}"

# Emit one label line; empty values are skipped (a label with an empty value
# carries no information and would only churn image digests). Newlines fold to
# spaces: every caller reads this stdout one line per --label, so a multi-line
# value would smuggle its continuation lines in as extra bogus labels.
_lbl_emit() {
    local _value="${2//$'\n'/ }"
    if [ -n "${_value}" ]; then
        [ "${_value}" = "$2" ] || _lbl_log "folded newlines in value of $1"
        printf '%s=%s\n' "$1" "${_value}"
    fi
}

# ── Git-derived values ────────────────────────────────────────────────────────

# --verify --quiet: a plain `rev-parse HEAD` echoes the literal ref name to
# stdout in a repo without commits, which would stamp revision=HEAD.
_git_sha="$(git -C "${PROJECT_ROOT}" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
_git_sha_short="$(git -C "${PROJECT_ROOT}" rev-parse --verify --quiet --short HEAD 2>/dev/null || true)"
_git_sha_short="${_git_sha_short:-no-commit}"
_git_tag="$(git -C "${PROJECT_ROOT}" describe --exact-match --tags HEAD 2>/dev/null || true)"
if [ -z "${_git_sha}" ]; then
    _lbl_log "no git repository at root=${PROJECT_ROOT} — revision label skipped"
fi

# ── Version: the ONE resolver (env > CI tag ref > exact git tag > short sha) ──
# Delegated to the shared m6e-version.sh so this image's `version` LABEL and the
# ldflags version baked into the binaries it ships derive from ONE rule and can
# never disagree. A missing resolver (non-m6e consumer) degrades to an empty
# version, which _lbl_emit then skips — never a build failure.

_version="$(PROJECT_ROOT="${PROJECT_ROOT}"      \
    "$(dirname "${BASH_SOURCE[0]}")/m6e-version.sh" 2>/dev/null || true)"
_lbl_log "resolved version=${_version:-<none>}"

# ── Created: a REAL date — tag commit time > build time ───────────────────────
# Decoupled from SOURCE_DATE_EPOCH on purpose: that var is 0 by default (a
# cache-safe docker --build-arg) and would stamp 1970-01-01 here. The created
# LABEL wants a real date; it never reaches --build-arg, so it cannot bust the
# Docker layer cache — only build-args do.

_epoch=""
if [ -n "${_git_tag}" ]; then
    _epoch="$(git -C "${PROJECT_ROOT}" log -1 --format=%ct "${_git_tag}" 2>/dev/null || true)"
fi
if [ -z "${_epoch}" ]; then
    _epoch="$(date +%s)"
fi
_created="$(date --utc --date="@${_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
if [ -z "${_created}" ]; then
    _lbl_log "cannot format epoch=${_epoch} — created label skipped"
fi

# ── Always-available labels ───────────────────────────────────────────────────

_lbl_emit "org.opencontainers.image.version"  "${_version}"
_lbl_emit "org.opencontainers.image.revision" "${_git_sha}"
_lbl_emit "org.opencontainers.image.created"  "${_created}"
_lbl_emit "org.m6e.ci.build-by"               "${M6E_BUILD_BY:-unknown}"
_lbl_emit "org.m6e.ci.git-commit"             "${_git_sha_short}"

# ── Projectfile discovery ─────────────────────────────────────────────────────

_pf_path="${M6E_PROJECTFILE_PATH:-}"
if [ -z "${_pf_path}" ]; then
    for _ext in yaml toml json; do
        if [ -f "${PROJECT_ROOT}/projectfile.${_ext}" ]; then
            _pf_path="${PROJECT_ROOT}/projectfile.${_ext}"
            break
        fi
    done
fi
if [ -z "${_pf_path}" ]; then
    _lbl_log "no projectfile in root=${PROJECT_ROOT} — projectfile labels skipped"
    exit 0
fi

# ── pf-cli resolution: PF_CLI > PATH > PF_CLI_IMAGE container > skip ─────────
# The container fallback mounts the project read-only and reads the projectfile
# by its in-container path, mirroring m6e's base/000-pfcli-fallback.mk opt-in.
# --entrypoint pf-cli: the published cli image is a b19 service image
# (ENTRYPOINT entrypoint.d, CMD sleep infinity); without this override `get`
# is an unknown command.d verb and the container hangs on sleep until timeout.

_pf_cmd=()
if [ -n "${PF_CLI:-}" ]; then
    read -ra _pf_cmd <<< "${PF_CLI}"
elif command -v pf-cli >/dev/null 2>&1; then
    _pf_cmd=(pf-cli)
elif [ -n "${PF_CLI_IMAGE:-}" ]; then
    _runtime="${M6E_CONTAINER_RUNTIME:-docker}"
    if command -v "${_runtime}" >/dev/null 2>&1; then
        _pf_cmd=("${_runtime}" run --rm --entrypoint "${PF_CLI_ENTRYPOINT:-pf-cli}"
                 --env NO_COLOR=1
                 --volume "${PROJECT_ROOT}:/work:ro" --workdir /work
                 "${PF_CLI_IMAGE}")
        _pf_path="/work/$(basename "${_pf_path}")"
        _lbl_log "pf-cli via container image=${PF_CLI_IMAGE}"
    else
        _lbl_log "runtime ${_runtime} unavailable for PF_CLI_IMAGE=${PF_CLI_IMAGE}"
    fi
fi
if [ ${#_pf_cmd[@]} -eq 0 ]; then
    _lbl_log "pf-cli unavailable (path=${_pf_path}) — projectfile labels skipped"
    exit 0
fi

# Includes may be fetched over HTTP, so every pf-cli call gets a timeout and a
# failure degrades to "no output" instead of failing the build. A timeout or
# nonzero exit is LOGGED, not swallowed: an unreachable include or a wrong
# PF_CLI_IMAGE entrypoint otherwise costs M6E_LABEL_TIMEOUT per call in silence.
_pf() {
    local _rc=0
    timeout "${M6E_LABEL_TIMEOUT}" "${_pf_cmd[@]}" "$@" 2>/dev/null || _rc=$?
    # pf-cli returns 1 for an absent/empty path — benign and common (a project
    # with no user labels), so stay quiet. Only structural failures are loud:
    # 124 = killed by timeout (a hang), 125-127 = runtime/exec failure from a
    # wrong PF_CLI_IMAGE or entrypoint. Both still degrade to no output.
    if [ "${_rc}" -eq 124 ]; then
        _lbl_log "pf-cli timed out after ${M6E_LABEL_TIMEOUT}s (subcommand=${1:-?}) — check PF_CLI_IMAGE entrypoint / include reachability"
    elif [ "${_rc}" -ge 125 ]; then
        _lbl_log "pf-cli runtime failure exit=${_rc} (subcommand=${1:-?}) — check PF_CLI_IMAGE=${PF_CLI_IMAGE:-<none>}"
    fi
    return 0
}

# ── Label language: the project's primary language ───────────────────────────
# identity.title and identity.summary are spec §7 localized maps. Read WITHOUT
# --lang, pf-cli serializes the whole map as `lang=value` lines, so every extra
# locale becomes its own bogus top-level label and the primary one keeps a
# `lang=` prefix in its value.

_lang="${M6E_LABEL_LANG:-}"
if [ -z "${_lang}" ]; then
    _lang="$(_pf get --path-file "${_pf_path}"                          \
        --default en 'org.projectfile.i18n.default-language')"
fi
_lang="${_lang:-en}"
_lbl_log "label language=${_lang} for ${_pf_path}"

# ── Projectfile-derived labels (one batch read) ───────────────────────────────
# NO --expand-env here: identity fields never carry ${VAR} refs, and expansion
# pre-parse breaks the whole document when unrelated build-arg refs (e.g.
# ${B19_DOCKER_REGISTRY}) are unset in the caller's environment.

OCI_LABEL_TITLE="" OCI_LABEL_DESCRIPTION="" OCI_LABEL_LICENSES="" OCI_LABEL_SOURCE=""
_pf_batch="$(_pf get --path-file "${_pf_path}" --batch --format sh      \
    --lang "${_lang}"                                                   \
    --path OCI_LABEL_TITLE=identity.title                               \
    --path OCI_LABEL_DESCRIPTION=identity.summary                       \
    --path OCI_LABEL_LICENSES=license.spdx                              \
    --path OCI_LABEL_SOURCE='links[type=source-code].url')"
if [ -n "${_pf_batch}" ]; then
    eval "${_pf_batch}"
else
    _lbl_log "pf-cli batch read empty for ${_pf_path} — identity labels skipped"
fi

_lbl_emit "org.opencontainers.image.title"       "${OCI_LABEL_TITLE}"
_lbl_emit "org.opencontainers.image.description" "${OCI_LABEL_DESCRIPTION}"
_lbl_emit "org.opencontainers.image.licenses"    "${OCI_LABEL_LICENSES}"
_lbl_emit "org.opencontainers.image.source"      "${OCI_LABEL_SOURCE}"

# ── User labels: ext.m6e.build.labels passthrough (deterministic order) ──────
# --expand-env resolves ${VAR} refs in label VALUES; when unset refs elsewhere
# in the document break the expanded parse, retry plain so user labels still
# land (their ${VAR} refs then stay literal — degraded, logged, non-fatal).

_ext_labels="$(_pf get --path-file "${_pf_path}" --expand-env 'ext.m6e.build.labels{}')"
if [ -z "${_ext_labels}" ]; then
    _ext_labels="$(_pf get --path-file "${_pf_path}" 'ext.m6e.build.labels{}')"
    if [ -n "${_ext_labels}" ]; then
        _lbl_log "expand-env parse failed for ${_pf_path} — user labels unexpanded"
    fi
fi
while IFS= read -r _line; do
    case "${_line}" in
        '') ;;
        *=*) _lbl_log "projectfile label ${_line%%=*}"
             printf '%s\n' "${_line}" ;;
        *)   _lbl_log "dropped label line carrying no KEY=VALUE: ${_line}" ;;
    esac
done <<< "${_ext_labels}"
