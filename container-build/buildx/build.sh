#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: build the context to a daemon-readable DOCKER-format archive
# with docker buildx, named for this cell (the build→scan hand-off tar). `type=docker`
# (not `type=oci`) writes the `manifest.json` layout the daemonless scanners require
# (trivy/dockle `--input` reject an OCI archive); `docker load` reads either, so the
# live-stack hand-off is unaffected. It is single-platform — fine here, the per-cell
# CI build is one arch.
#
# Self-contained: build-args from $BUILD_ARGS/$FILE_ARGS (build-args.sh), mounts
# from $MOUNTS (mounts.sh), labels + version from the pf-cli/git resolvers vendored
# at lib/ (labels.sh, m6e-version.sh) — NO m6e submodule clone needed. The standard
# m6e build-args (frontend pin, registries, identity) are added here, mirroring the
# make-plane buildx-build so a CI build and a local `make container-build` pass the
# same --build-arg set (modulo the cell values that arrive via BUILD_ARGS).
set -euo pipefail

BACKEND=buildx
# shellcheck source-path=SCRIPTDIR source=../forge.sh
source "${GITHUB_ACTION_PATH}/../forge.sh"
# shellcheck source-path=SCRIPTDIR source=../build-args.sh
source "${GITHUB_ACTION_PATH}/../build-args.sh"
# shellcheck source-path=SCRIPTDIR source=../mounts.sh
source "${GITHUB_ACTION_PATH}/../mounts.sh"
# shellcheck source-path=SCRIPTDIR source=../labels.sh
source "${GITHUB_ACTION_PATH}/../labels.sh"

# Standard m6e build-args (mirror the make-plane buildx-build): frontend pin +
# bare registry/cache forwards (docker reads env; unset => Dockerfile default) +
# identity. NAMESPACE/PROJECT are skipped when empty (CI does not always inject
# them; a bare NAME with no value is noisy under buildx, so emit only when set).
std_args=(--build-arg "BUILDKIT_SYNTAX=${M6E_DOCKER_BUILDX_SYNTAX:-docker/dockerfile:1}")
for _name in DESTINATION_DOCKER_REGISTRY SOURCE_DOCKER_REGISTRY     \
             M6E_APT_CACHE_HOST M6E_APT_CACHE_PORT M6E_NEAR_CACHE_HOST; do
    std_args+=(--build-arg "${_name}")
done
std_args+=(--build-arg "M6E_AI=${M6E_AI:-N}")
[ -n "${NAMESPACE:-}" ] && std_args+=(--build-arg "M6E_NAMESPACE=${NAMESPACE}")
[ -n "${PROJECT:-}" ]   && std_args+=(--build-arg "M6E_PROJECT=${PROJECT}")

# Dockerfile stage selection (mirror the make-plane buildx-build): ci-resolver
# passes org.projectfile.ci.build-target.<gha|forgejo> as M6E_BUILD_TARGET. Empty
# => no --target => last stage.
target_args=()
[ -n "${M6E_BUILD_TARGET:-}" ] && target_args+=(--target "${M6E_BUILD_TARGET}")

# Stamp the image ref INTO the docker archive (name=) when one is given, so a
# consumer `docker load`s a TAGGED image the compose stack finds by tag — never
# an anonymous archive. Empty IMAGE keeps the historical anonymous output.
docker_output="type=docker,dest=${ARTIFACT_NAME}.tar"
if [ -n "${IMAGE:-}" ]; then
    docker_output="type=docker,name=${IMAGE},dest=${ARTIFACT_NAME}.tar"
fi
echo "buildx building artifact=${ARTIFACT_NAME} image=${IMAGE:-<anonymous>} context=${CONTEXT} binds=${#build_contexts[@]}"
# env -u SOURCE_DATE_EPOCH: BuildKit consumes the var (env OR build-arg) to stamp
# the image's `created` field; an inherited value would freeze it (e.g. 1970-01-01
# for 0). Stripped here, buildx stamps the real build time — reproducibility
# (clamping layer timestamps) is intentionally not applied on this plane.
env -u SOURCE_DATE_EPOCH docker buildx build "${std_args[@]}" "${build_args[@]}" "${build_contexts[@]}" "${label_args[@]+"${label_args[@]}"}" "${target_args[@]+"${target_args[@]}"}" --output "${docker_output}" "${CONTEXT}"
