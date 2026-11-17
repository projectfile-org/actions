#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Damián Búho <damian.buho@proton.me>
#
# SPDX-License-Identifier: MIT

# site.sh — check the site directory PAGES_PATH (default dist/site) carries an index.html and export it as PAGES_SITE

set -euo pipefail

site="${PAGES_PATH:-dist/site}"
if [[ ! -f "${site}/index.html" ]]; then
	echo "pages-deploy: ${site}/index.html is missing, nothing to deploy" >&2
	exit 1
fi
echo "PAGES_SITE=${site}" >>"${GITHUB_ENV}"
echo "pages-deploy: site=${site} files=$(find "${site}" -type f | wc -l)"
