#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT
#
# What we are doing: derive the NORMALIZED build-pipeline id (gha-buildx,
# forgejo-buildah, …) this run stamps as the org.m6e.ci.build-by label — the
# same vocabulary the make plane uses (make-buildx / make-buildah). The forge
# half comes from the runner's own markers: Forgejo/Gitea runners export
# FORGEJO_ACTIONS/GITEA_ACTIONS as PROCESS env (unlike job `env:`, which the
# Forgejo runner drops for composite actions), GitHub sets neither. The caller
# sets BACKEND=buildx|buildah before sourcing. SHARED by every container-build
# backend so the id is computed in one place. SOURCED, not executed.

forge="gha"
if [ -n "${FORGEJO_ACTIONS:-}${GITEA_ACTIONS:-}" ]; then
  forge="forgejo"
fi
export M6E_BUILD_BY="${M6E_BUILD_BY:-${forge}-${BACKEND:?forge.sh needs BACKEND}}"
# SOURCE_DATE_EPOCH is intentionally NOT set: container images stamp their real
# build time as `created` (the backends `env -u SOURCE_DATE_EPOCH` to keep it real
# even if the runner leaks one). Reproducibility — clamping timestamps to a fixed
# epoch — is not applied on this plane; re-enabling it means env + the exporter's
# `rewrite-timestamp`, NOT a --build-arg (which would only freeze `created`).
echo "pipeline id forge=${forge} backend=${BACKEND} build-by=${M6E_BUILD_BY}"
