#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: run a containerised tool on the HOST runner. Recompose the image
# ref from the image path + tag (a bare Docker-Hub name is qualified docker.io/), forward
# the requested env as NAME=VALUE pairs into the container (the VALUE rides the input — a
# composite action can't read the caller job's `env:` as process env), mount the checkout
# at /app/ws (the SAME mountpoint m6e's container mode uses, so both lowerings agree on
# container semantics), and exec the run string in the container. When RUN contains shell
# metacharacters (&&, ||, |, ;, redirects, $(...)) it is wrapped in `sh -c` so the
# container's own shell evaluates them; otherwise the command is word-split and exec'd
# directly — this keeps distroless images (e.g. hadolint/hadolint, FROM scratch) working
# since they carry no sh at all.
set -euo pipefail

: "${IMAGE:?run-tool: image is required}"
: "${VERSION:?run-tool: version is required}"
: "${RUN:?run-tool: run is required}"

# Recompose a FULLY-QUALIFIED ref. The image path arrives carrying its FULL registry
# prefix (pf-ci embeds it via a ci.images var: `kiota.ch/d9t/...`), so an
# already-qualified ref is used VERBATIM, and only a bare Docker-Hub-namespace name
# (`hadolint/hadolint`) is prefixed `docker.io/`. The explicit host is load-bearing on
# the forge runner's podman backend: unlike the Docker daemon (which reads a bare
# `hadolint/hadolint` as implicitly docker.io), podman treats an unqualified name as
# searchable across every `unqualified-search-registries` entry and, on more than one
# match (e.g. kiota.ch + docker.io), drops into an interactive "Please select an image"
# prompt — which HANGS a non-interactive runner. So a fully-qualified ref is built for
# the bare Docker-Hub case, but an already-qualified ref is NEVER re-prefixed (that
# would yield docker.io/kiota.ch/... — a non-existent Docker-Hub path). Host detection
# mirrors Docker's reference rule: a leading slash-segment is a host iff it holds ':'
# (port) or '.' or is 'localhost'.
qualified=no
if [[ "${IMAGE}" == */* ]]; then
  case "${IMAGE%%/*}" in *:* | *.* | localhost) qualified=yes ;; esac
fi
# base: a tag-bearing IMAGE is a COMPLETE ref. The instance-override knob
# `${{ vars.HADOLINT_IMAGE || 'hadolint/hadolint' }}` lets an operator redirect to a
# mirror by setting the var to a FULL tagged ref (`kiota.ch/d9t/hadolint/hadolint:v2.14.0`);
# appending the resolver's default :<version> onto that would double the tag
# (`...:v2.14.0:v2.14.0` — docker: invalid reference format). The tag sits AFTER the last
# `/`, so a port-only host (`kiota.ch:5000/...`, its `:` before the first `/`) never matches.
base="${IMAGE}"
[[ "${IMAGE##*/}" == *:* ]] || base="${IMAGE}:${VERSION}"
if [ "${qualified}" = yes ]; then
  ref="${base}"
else
  ref="docker.io/${base}"
fi

# Forward each requested env as a NAME=VALUE pair (one per line). The VALUE rides the
# action input because a composite action does NOT inherit the caller job's `env:` as
# PROCESS env (the Forgejo runner drops it) — a by-NAME `--env NAME` passthrough would
# read an UNSET var and forward nothing (the empty-M6E_IMAGE_ARCHIVE scanner failure).
# pf-ci resolved each value (matrix axis, archive path, a per-target credential
# ref) at render time. A line with NO `=` is a bare NAME (no value resolved) and is
# forwarded by name — the graceful fallback to the runner's own OS env. We log only the
# NAMES (left of the first `=`) so a forwarded secret value never reaches the log.
#
# env_pairs is the same list in the shape the HOST path needs (see prefer-local below):
# `env NAME=VALUE… cmd` takes only ASSIGNMENTS, so a bare NAME is dropped there — it is
# already in the runner's own environment, which a host run inherits outright.
# b19-log filters at B19_VERBOSITY, whose default is `warn` — that drops every info/note
# line, so a tool that PASSES prints NOTHING and reads as one that never ran. m6e-run
# already forces `info` for the make plane; a forge log is pure capture, so it wants the
# same. A FLOOR, not a default: the runner image BAKES `B19_VERBOSITY=warn`
# (r8e/forgejo-runner) and a composite action inherits the runner's process env, so a
# `:-info` fallback never fires and every audit stays mute. Only a MORE verbose level
# survives. Seeded FIRST because docker keeps the LAST --env: a tool's set-env still wins.
case "${B19_VERBOSITY:-}" in
  debug) verbosity="${B19_VERBOSITY}" ;;
  *)     verbosity=info ;;
esac
env_opts=(--env "B19_VERBOSITY=${verbosity}")
env_pairs=("B19_VERBOSITY=${verbosity}")
env_names=""
while IFS= read -r pair; do
  [ -n "${pair}" ] || continue
  env_opts+=(--env "${pair}")
  [[ "${pair}" == *=* ]] && env_pairs+=("${pair}")
  env_names="${env_names:+${env_names} }${pair%%=*}"
done <<< "${ENV_VARS:-}"

# Extra mounts the resolver computed (e.g. a scanner DB cache dir): each token is a
# `HOST:CONTAINER[:ro]` spec appended verbatim as a --volume. This action only knows
# "mount these paths" — the DIVERGENCE (a self-hosted runner binds a persistent dir
# RO; an ephemeral one mounts an actions/cache-restored dir) lives entirely in the
# resolver's NAME-`mounts` lowering, so ONE primitive serves both targets (Law 3).
#
# Pre-create the host side first: unlike the Docker daemon, rootless podman (the forge
# runner's backend) does NOT auto-create a missing bind source — it aborts with
# `statfs <path>: no such file or directory`. mkdir -p the path-like host of each spec
# so the mount resolves regardless of backend; an empty RO cache dir is the INTENDED
# state on a fresh volume (the tool's own flock fallback then fills the writable twin),
# so creating it never masks a real error. Named volumes (no leading slash) are left
# untouched — podman manages those itself.
mount_opts=()
for spec in ${MOUNTS:-}; do
  host="${spec%%:*}"
  case "${host}" in
    /*|./*|../*) mkdir -p "${host}" ;;
  esac
  mount_opts+=(--volume "${spec}")
done

# Join a container network so the tool can reach the LIVE compose stack (dc-up-d) by
# compose service name — the ssh-audit case: a black-box audit of the running sshd. The
# default bridge is isolated from the stack, and host networking is rejected (port
# collisions + privilege), so the resolver hands us the stack's network NAME here. The
# network is created by dc-up-d earlier in the SAME fused `live` job, so it already
# exists when this runs. Empty => the default bridge (the common case; every non-live
# tool). One --network only; a comma-list would need repeated flags we do not need yet.
net_opts=()
[ -n "${NETWORK:-}" ] && net_opts=(--network "${NETWORK}")

# Prefer a HOST binary over the container when the operator has baked the tool into the
# runner image (the `COPY pf-cli/pf-bridge` case) and allowlisted it here. This is the
# forge twin of the make lowering's `m6e.prefer-local` (m6e core/ci/020-executor.mk),
# which pf-ci does NOT lower: that key sits under the `m6e:` block, and it is set on
# nearly every tool in the fleet, so it cannot discriminate WHICH binaries a given runner
# actually ships. That knowledge belongs to the runner, so the switch is a runner env
# allowlist — the same shape as the RUN_TOOL_PULL knob above.
#
# RUN_TOOL_PREFER_LOCAL holds whitespace- or comma-separated ENTRYPOINT names (the first
# word of `run`). Empty (the default) => never prefer local, i.e. today's behaviour
# byte-for-byte. Secure by default: a binary that merely happens to sit on the runner PATH
# never silently displaces the pinned image; the operator names each one.
#
# Two hard refusals keep the host path SEMANTICALLY equal to the container path, since
# neither can be honoured outside a container:
#   * mounts  — a scanner's DB cache would silently vanish, and the tool would run against
#               an empty DB and still exit 0 (a green scan that scanned nothing).
#   * network — a `network: live` tool addresses compose services by NAME; off the
#               container network that name does not resolve.
# Either present => container, whatever the allowlist says.
#
# OPERATOR RULE: do NOT allowlist a tool on a runner pool that BUILDS that same tool. The
# baked binary would check the project with the PREVIOUS release instead of the commit
# under test — the projectfile/bridge dogfooding case.
entrypoint="${RUN%% *}"
prefer_local=no
if [ -z "${RUN_TOOL_PREFER_LOCAL:-}" ]; then
  prefer_reason="disabled (RUN_TOOL_PREFER_LOCAL empty)"
elif [ -n "${MOUNTS:-}" ]; then
  prefer_reason="refused: tool declares mounts [${MOUNTS}]"
elif [ -n "${NETWORK:-}" ]; then
  prefer_reason="refused: tool joins network [${NETWORK}]"
else
  prefer_reason="not allowlisted in [${RUN_TOOL_PREFER_LOCAL}]"
  for allowed in ${RUN_TOOL_PREFER_LOCAL//,/ }; do
    [ "${allowed}" = "${entrypoint}" ] || continue
    if local_path=$(command -v "${entrypoint}" 2>/dev/null); then
      prefer_local=yes
      prefer_reason="allowlisted, resolved to ${local_path}"
    else
      prefer_reason="allowlisted but absent from PATH — falling back to the image"
    fi
    break
  done
fi

echo "run-tool ref=${ref} run=${RUN} env=[${env_names}] mounts=[${MOUNTS:-}] network=[${NETWORK:-}] pull=${RUN_TOOL_PULL:-always} verbosity=${verbosity} advisory=${ADVISORY:-false}"
echo "run-tool prefer-local=${prefer_local} entrypoint=${entrypoint} :: ${prefer_reason}"
# --pull always: tool images ride MUTABLE tags (BASE_IMAGE_DEFAULT_VERSION || latest),
# so a runner that has already cached the tag would otherwise run a STALE image forever —
# both docker and podman default to `--pull missing`, which only fetches an ABSENT tag, not
# a moved one. Re-checking the registry each run keeps the runner on the freshly-pushed tool
# image; an unchanged digest is a cheap manifest no-op (no re-download). RUN_TOOL_PULL is the
# secure-default switch (AGENTS: expose behaviour) — set it to `missing`/`never` for an
# offline or local run (e.g. act against images already in the host store).
pull="${RUN_TOOL_PULL:-always}"
# Build the container command: wrap in `sh -c` when RUN contains shell metacharacters
# (&&, ||, |, ;, $(...), backtick, redirects) OR double-quotes. Distroless images
# (e.g. hadolint/hadolint, FROM scratch) have no sh at all — passing `sh -c` as the
# command causes crun to fail with "executable file sh not found" before the
# container process starts. Plain tool invocations (the common case for run-tool)
# need no shell; word-splitting is sufficient and works for both our b19 tini-based
# images and distroless images alike.
#
# Double-quote in RUN forces the sh path on purpose: a quoted arg like
# `.scripts/publish-go-module.sh "${{ github.ref_name }}"` is sh syntax — the
# quotes ask the shell to strip them AND preserve the space inside. The word-split
# path strips a surrounding quote-pair per word (see below) but cannot preserve an
# interior space, so a quoted multi-word arg like `"a b"` would split into `"a` +
# `b"`. Treating `"` as shell-meta routes such runs through `sh -c`, which handles
# both the strip and the space.
shell_meta_re='[&|;<>"]'
dollar_paren="\$("
backtick='`'
if [[ "${RUN}" =~ ${shell_meta_re} || "${RUN}" == *"${dollar_paren}"* || "${RUN}" == *"${backtick}"* ]]; then
  echo "run-tool shell-wrap=yes (shell metacharacters or quotes detected in run)"
  cmd=(sh -c "${RUN}")
else
  echo "run-tool shell-wrap=no (plain command, word-split)"
  read -ra cmd <<< "${RUN}"
  # Strip ONE matching pair of surrounding quotes from each word. The word-split
  # path has no shell to consume quote syntax, so a quoted token like
  # `'dist/**/*.html'` reaches the tool with the quotes as LITERAL characters
  # (html-validate then matches a file literally named 'dist/**/*.html' and finds
  # nothing). A shell would strip them; this mirrors that for the no-shell path.
  # Only a FULL wrap is stripped — interior or unbalanced quotes stay literal, so
  # a value that genuinely contains a quote (a password, a grep pattern) is never
  # mangled. Single AND double are handled even though `"` already routes to the
  # sh -c path above: this is the word-split path's own contract (strip a wrap),
  # not an assumption about how the RUN arrived here.
  for i in "${!cmd[@]}"; do
    w="${cmd[i]}"
    if [[ ${#w} -ge 2 ]] && [[ "${w:0:1}" == "${w: -1}" ]] && [[ "${w:0:1}" == \' || "${w:0:1}" == \" ]]; then
      cmd[i]="${w:1:${#w}-2}"
    fi
  done
fi
# Capture the exit code instead of letting `set -e` abort: a non-zero run is DECODED
# below before we propagate it (the container is `--rm`, so the code is the only
# post-mortem left).
rc=0
if [ "${prefer_local}" = yes ]; then
  # HOST path: the workspace IS the cwd (the container binds this same $PWD at /app/ws and
  # sets it as the workdir), so the tool sees an identical tree with no bind at all. Only
  # the ASSIGNMENTS are re-applied; the runner's own environment is inherited, which is
  # what the container path emulates with its by-NAME forwarding.
  env "${env_pairs[@]}" "${cmd[@]}" || rc=$?
else
  docker run --rm --pull "${pull}" --volume "${PWD}":/app/ws --workdir /app/ws      \
    "${net_opts[@]}" "${mount_opts[@]}" "${env_opts[@]}" "${ref}" "${cmd[@]}" || rc=$?
fi

if [ "${rc}" -ne 0 ]; then
  # What we are doing: turn an opaque "RUN exit status N" into a named cause so a CI
  # log reader does not have to memorise the table. 128+S = killed by signal S; the
  # rest are the tool's own status. 137 (SIGKILL) is the one that bites a CONCURRENT
  # runner — the OOM killer or a forced `stop`/teardown reaping the container.
  case "${rc}" in
    137) hint="SIGKILL (128+9) — OOM killer or forced stop/teardown" ;;
    143) hint="SIGTERM (128+15) — graceful stop" ;;
    139) hint="SIGSEGV (128+11) — segfault" ;;
    134) hint="SIGABRT (128+6) — abort" ;;
    124) hint="timeout(1) deadline exceeded" ;;
    *)   hint="tool exit status" ;;
  esac
  # Name the site that ACTUALLY ran: on the host path `ref` is the image we bypassed, so
  # reporting it would send triage to the wrong binary.
  if [ "${prefer_local}" = yes ]; then site="host=${local_path}"; else site="ref=${ref}"; fi
  echo "run-tool FAILED rc=${rc} ${site} run=[${RUN}] :: ${hint}" >&2
  # On a kill-signal exit, surface host memory — the usual culprit when many tool
  # runs share one host runner — so triage needs no shell access to the box.
  case "${rc}" in
    137 | 143)
      command -v free >/dev/null 2>&1 && free --mebi >&2 || true
      ;;
  esac
  # An ADVISORY tool is reported EXACTLY as above — same named cause, same log — and only
  # its exit code differs: the finding is worth reading, not worth a red build. The rc is
  # neutralised after the report so a log reader sees what broke and the status it broke
  # with. Fail-CLOSED: only the literal `true` opts in, so a typo leaves the gate armed.
  if [ "${ADVISORY:-}" = "true" ]; then
    echo "run-tool ADVISORY rc=${rc} run=[${RUN}] :: reported, not blocking" >&2
    rc=0
  fi
fi
exit "${rc}"
