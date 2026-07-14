#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are trying to do: materialise the `.secrets/` tree a compose `secrets:`
# block mounts, from the org.projectfile.ci.secrets declarations. This is the
# cloud (ci-resolver) half of the provisioning contract; the m6e half reads the
# SAME declarations (the one source of truth) and calls the same dispatch logic.
# Two secret kinds only:
#   value:  write a literal string verbatim to the file
#   docker: run `docker run <resolved-image> <run>`; stdout is captured as the
#           secret value (openssl, htpasswd, the m6e-secret-* recipes)
# Dots in the name are the ONLY path separator: `gf.security.admin.password` ->
# `<dir>/gf/security/admin/password`. Sibling derivation: a `docker:` recipe is
# given its OWN directory (mounted + passed as $1) so it can read `../password`
# (bcrypt) or `../username`+`../password` (htpasswd) — the recipe names that
# derive are run AFTER the secrets they may depend on.

set -euo pipefail

# NOTE: the default for DECLARATIONS is the empty-object literal `{}`. Writing it
# inline as `${DECLARATIONS:-{}}` would mis-parse — the inner `}` closes the
# parameter expansion early and a literal `}` is appended to the value, corrupting
# valid JSON. Bracket-quote the default (`${DECLARATIONS:-"{}"}`) so the braces
# are an opaque string, not expansion syntax.
DECLARATIONS="${DECLARATIONS:-"{}"}"
DIR="${DIR:-.secrets}"
DEFAULT_IMAGE="${DEFAULT_IMAGE:-}"
IMAGE="${IMAGE:-}"

# jq is on every GHA/Forgejo runner; fail closed with a clear message if absent.
if ! command -v jq >/dev/null 2>&1; then
  echo "secrets-provision: jq is required on the runner to parse declarations" >&2
  exit 2
fi

# An empty/absent subtree is a no-op (the empty-subtree invariant). The step is
# only injected when `secrets:` is non-empty, but stay a safe no-op regardless.
keys=$(jq -r 'keys[]' <<<"${DECLARATIONS}" 2>/dev/null || true)
if [ -z "${keys}" ]; then
  echo "secrets-provision: no declarations (empty subtree) — nothing to provision"
  exit 0
fi

key_count=$(jq '. | length' <<<"${DECLARATIONS}")
echo "secrets-provision: provisioning ${key_count} secret(s) under ${DIR}/"

mkdir -p "${DIR}"

# Resolve which image a declaration's `docker:` runs in. `self` => the project's
# OWN built image (the `image:` input); anything else => the default misc-tools
# image where the m6e-secret-* recipes live. Fail closed if `self` is used with
# no project image supplied.
resolve_image() {
  local decl_image="${1:-}"
  case "${decl_image}" in
    self)
      if [ -z "${IMAGE}" ]; then
        echo "secrets-provision: a secret declared 'docker: { image: self }' but no project image was supplied" >&2
        return 2
      fi
      printf '%s' "${IMAGE}"
      ;;
    "")
      if [ -z "${DEFAULT_IMAGE}" ]; then
        echo "secrets-provision: a 'docker:' secret needs default-image (the misc-tools image) but none was supplied" >&2
        return 2
      fi
      printf '%s' "${DEFAULT_IMAGE}"
      ;;
    *)
      # The schema's enum:[self] makes any other value a structural error; this
      # branch is unreachable for schema-valid input. Defensive fail-closed.
      echo "secrets-provision: unknown docker image ref '${decl_image}' (expected 'self' or absent)" >&2
      return 2
      ;;
  esac
}

# Write one secret: resolve its kind (value vs docker), run the generator, and
# capture stdout into the file (no trailing newline — bcrypt/htpasswd compare
# byte-for-byte, so a trailing newline corrupts the value).
write_secret() {
  local name="$1"
  # File path: dots -> slashes; every other char (incl. underscore) is literal.
  local file_path="${DIR}/${name//.//}"
  local file_dir
  file_dir="$(dirname "${file_path}")"

  if [ -f "${file_path}" ]; then
    echo "secrets-provision: SKIP ${file_path} (already exists)"
    return 0
  fi

  mkdir -p "${file_dir}"

  # Extract this secret's declaration as JSON and decode the kind. The shorthand
  # (bare string) is normalised to {"value": str} by jq; {docker: str} to
  # {docker: {run: str}}.
  local decl
  decl=$(jq --arg n "${name}" '.[$n]' <<<"${DECLARATIONS}")

  if [ "$(jq -r 'type' <<<"${decl}")" = "string" ]; then
    # Bare-string shorthand ≡ {value: <string>}.
    jq -j ' .' <<<"${decl}" >"${file_path}"
    echo "secrets-provision: WROTE ${file_path} (value)"
    return 0
  fi

  if jq -e 'has("value")' <<<"${decl}" >/dev/null; then
    # {value: <string>} — write verbatim. -j suppresses the JSON quoting/newline.
    jq -j '.value' <<<"${decl}" >"${file_path}"
    echo "secrets-provision: WROTE ${file_path} (value)"
    return 0
  fi

  if jq -e 'has("docker")' <<<"${decl}" >/dev/null; then
    # {docker: ...} — a generator. Normalise shorthand (string -> {run: str}),
    # resolve the image, forward env, and capture stdout.
    local docker_decl
    docker_decl=$(jq '.docker | if type == "string" then {run: .} else . end' <<<"${decl}")
    local run_cmd decl_image run_image
    run_cmd=$(jq -j '.run' <<<"${docker_decl}")
    decl_image=$(jq -j '.image // ""' <<<"${docker_decl}")
    run_image="$(resolve_image "${decl_image}")" || return $?

    # Build env-forward opts (NAME only; the VALUE rides the runner's OS env,
    # the same contract as a tool manifest's `env:`). Log NAMES only.
    local env_names="" env_opts=()
    while IFS= read -r env_name; do
      [ -n "${env_name}" ] || continue
      env_opts+=(--env "${env_name}")
      env_names="${env_names:+${env_names} }${env_name}"
    done < <(jq -r '.env[]?' <<<"${docker_decl}")

    # Mount the secret's OWN directory read-only at the SAME path so a deriving
    # recipe (bcrypt reads ../password, htpasswd reads ../username + ../password)
    # finds its siblings. The dispatcher writes the OUTPUT file on the HOST (not
    # in the container), so the mount is RO — the recipe only READS.
    local abs_file_dir
    abs_file_dir="$(cd "${file_dir}" && pwd)"
    # podman (the forge runner backend) does NOT auto-create a missing bind
    # source; pre-create it (mirrors run-tool/run.sh's bind-source handling).
    mkdir -p "${abs_file_dir}"

    echo "secrets-provision: RUN ${run_image} ${run_cmd} <secret-dir=${file_dir}> env=[${env_names}] -> ${file_path}"
    docker run --rm                                         \
      --volume "${abs_file_dir}:${abs_file_dir}:ro"         \
      "${env_opts[@]}"                                      \
      "${run_image}"                                        \
      sh -c "${run_cmd} \"\${1}\"" _ "${abs_file_dir}"      \
      | tr -d '\n' >"${file_path}"
    echo "secrets-provision: WROTE ${file_path} (docker)"
    return 0
  fi

  echo "secrets-provision: secret '${name}' has neither value nor docker (malformed declaration)" >&2
  return 2
}

# Deriving recipes (bcrypt/bcrypt-b64/htpasswd) read siblings. Run them AFTER the
# secrets they may depend on so the sibling files exist. The recipe name is the
# convention; a recipe NOT in this set has no sibling dependency and runs in
# pass 1 alongside the value secrets.
is_deriving() {
  local run_cmd="$1"
  case "${run_cmd}" in
    m6e-secret-bcrypt | m6e-secret-bcrypt-b64 | m6e-secret-htpasswd) return 0 ;;
    *) return 1 ;;
  esac
}

# Pass 1: value secrets + non-deriving docker secrets (random, custom keygens).
# Pass 2: deriving docker secrets (bcrypt/bcrypt-b64/htpasswd), whose siblings
# are now in place.
for pass in 1 2; do
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    decl=$(jq --arg n "${name}" '.[$n]' <<<"${DECLARATIONS}")
    kind=""
    if [ "$(jq -r 'type' <<<"${decl}")" = "string" ] || jq -e 'has("value")' <<<"${decl}" >/dev/null; then
      kind=value
    elif jq -e 'has("docker")' <<<"${decl}" >/dev/null; then
      kind=docker
    fi
    [ "${kind}" = "" ] && {
      echo "secrets-provision: secret '${name}' is malformed (neither value nor docker)" >&2
      exit 2
    }
    if [ "${kind}" = docker ]; then
      # -r: the raw (unquoted) command name, so is_deriving's string compare
      # matches the bare recipe name (without -r jq emits "m6e-secret-htpasswd"
      # WITH quotes, which never matches → every docker secret is mis-classified
      # as non-deriving and the two-pass ordering collapses).
      run_cmd=$(jq -r '.docker | if type == "string" then . else .run end' <<<"${decl}")
      if is_deriving "${run_cmd}"; then
        [ "${pass}" = 2 ] || continue
      else
        [ "${pass}" = 1 ] || continue
      fi
    else
      [ "${pass}" = 1 ] || continue
    fi
    write_secret "${name}"
  done <<<"${keys}"
done

echo "secrets-provision: done"
