#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# release.test.sh — checks release.sh attaches every platform asset and swept sidecar from one job
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A commit hook's GIT_DIR would point release.sh's git fetch at the real repository.
unset "${!GIT_@}"
work="$(mktemp --directory)"
trap 'rm --recursive --force "${work}"' EXIT
mkdir --parents "${work}/bin" "${work}/dist/torrents" "${work}/torrents"
# Stub tea: every call succeeds except deleting an absent attachment; attaches are recorded.
cat > "${work}/bin/tea" <<'STUB'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "release assets delete") exit 1 ;;
  "release assets create") echo "${*: -1}" >> attached ;;
esac
STUB
chmod +x "${work}/bin/tea"
touch "${work}/dist/app-linux-x86_64" "${work}/dist/app-linux-x86_64.asc" "${work}/dist/app-darwin-aarch64"
touch "${work}/dist/torrents/app.torrent" "${work}/torrents/image-amd64.magnet" "${work}/dist/unrelated"

# release.sh logs to stderr and calls git, which finds no tag here and falls back to the bare tag.
(cd "${work}" && PATH="${work}/bin:${PATH}" VERSION=v1.0.0 RELEASE_PATH=dist/app SERVER_URL=https://forge.invalid \
  REPO=o/r FORGEJO_TOKEN=t RELEASE_RETRIES=1 RELEASE_BACKOFF=0 bash "${here}/release.sh" 2> release.log) || {
  cat "${work}/release.log" >&2
  exit 1
}

want="dist/app-darwin-aarch64
dist/app-linux-x86_64
dist/app-linux-x86_64.asc
dist/torrents/app.torrent
torrents/image-amd64.magnet"
got="$(sort "${work}/attached")"
if [ "${got}" != "${want}" ]; then
  printf 'release-test: FAIL attached:\n%s\nwant:\n%s\n' "${got}" "${want}" >&2
  exit 1
fi
echo "release-test: PASS $(wc --lines < "${work}/attached") assets from one job"
