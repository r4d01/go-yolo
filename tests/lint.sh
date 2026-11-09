#!/usr/bin/env bash
# shellcheck over everything: the launcher with its lib/ modules, the entrypoint and scripts,
# the catalogs (on their own: go-yolo.sh finds them at run time, so shellcheck can't follow), and
# the tests.
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
shellcheck -x go-yolo.sh
shellcheck entrypoint.sh scripts/*.sh
# Catalogs use the launcher's globals (HOME_DIR, PROJECT_DIR, ...) and are called by name.
shellcheck -e SC2034,SC2154 catalogs/*.sh
printf 'shellcheck: no findings\n'
