#!/usr/bin/env bash
# go-yolo: run AI coding agents in a Docker container.
#
# This file only lists the steps of a run; each step lives in lib/<module>.sh, and the items
# of the project image come from the catalogs in catalogs/<catalog>.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(dirname "$SELF")"

# The agents (agents/<name>.conf, plus the built-in shell) and the catalogs (catalogs/<name>.sh,
# the host catalog first) are whatever files are there: adding one means adding a file.
AGENTS=()
for file in "$REPO_DIR"/agents/*.conf; do AGENTS+=("$(basename -- "$file" .conf)"); done
AGENTS+=(shell)
CATALOGS=(host)
for file in "$REPO_DIR"/catalogs/*.sh; do
  name="$(basename -- "$file" .sh)"
  if [[ $name != host ]]; then CATALOGS+=("$name"); fi
done
unset file name

# shellcheck source=lib/ui.sh
source "$REPO_DIR/lib/ui.sh"
# shellcheck source=lib/args.sh
source "$REPO_DIR/lib/args.sh"
# shellcheck source=lib/aliases.sh
source "$REPO_DIR/lib/aliases.sh"
# shellcheck source=lib/host.sh
source "$REPO_DIR/lib/host.sh"
# shellcheck source=lib/image.sh
source "$REPO_DIR/lib/image.sh"
# shellcheck source=lib/mounts.sh
source "$REPO_DIR/lib/mounts.sh"
# shellcheck source=lib/project.sh
source "$REPO_DIR/lib/project.sh"
# shellcheck source=lib/config.sh
source "$REPO_DIR/lib/config.sh"
# shellcheck source=lib/kinds.sh
source "$REPO_DIR/lib/kinds.sh"
# shellcheck source=lib/plan.sh
source "$REPO_DIR/lib/plan.sh"
# shellcheck source=lib/apt.sh
source "$REPO_DIR/lib/apt.sh"
# shellcheck source=lib/items.sh
source "$REPO_DIR/lib/items.sh"
# shellcheck source=lib/confirm.sh
source "$REPO_DIR/lib/confirm.sh"
# shellcheck source=lib/agent.sh
source "$REPO_DIR/lib/agent.sh"
# shellcheck source=lib/run.sh
source "$REPO_DIR/lib/run.sh"
# shellcheck source=lib/prune.sh
source "$REPO_DIR/lib/prune.sh"
# shellcheck source=lib/parity.sh
source "$REPO_DIR/lib/parity.sh"
for catalog in "${CATALOGS[@]}"; do
  # shellcheck source=/dev/null # the catalogs are checked on their own by tests/lint.sh
  source "$REPO_DIR/catalogs/$catalog.sh"
done
unset catalog

ui_set_color auto
parse_args "$@"            # exits for --help, --prune and the alias commands
detect_host
choose_base_image

mount_workdir              # the project directory; refuses $HOME and its parents
check_project              # must be the git repository root
ensure_state_dir           # .go-yolo/

# More mounts. Explicit ones come first: the first mode given for a path wins.
add_user_mounts
add_git_config_mounts
load_agent_profile
add_agent_mounts

# The base image is the same for every project and holds nothing from the host, so it is built
# without asking; once it exists, the plan can compare its packages with the host's.
if ((!DRY_RUN)); then ensure_base_image; fi
resolve_plan               # what goes into the project image and the container
confirm_plan               # asks if the plan is new or exposes more than the confirmed one
choose_project_image
add_plan_mounts            # the plan's cache volumes and read-only mounts
if ((PARITY)); then prepare_parity; fi   # probes instead of an agent

set_network_args
decide_tmux
build_docker_command
warn_yolo

if ((DRY_RUN)); then
  printf '%q\n' "${CMD[@]}"
  exit 0
fi

ensure_project_image
ensure_cache_volumes
if ((PARITY)); then
  run_parity
  exit
fi
print_banner
exec "${CMD[@]}"
