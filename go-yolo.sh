#!/usr/bin/env bash
# go-yolo: run AI coding agents in a Docker container.
#
# This file only lists the steps of a run; each step lives in lib/<module>.sh, and the items
# of the project image come from the packs in packs/<pack>.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(dirname "$SELF")"
AGENTS=(claude codex vibe opencode shell)
PACKS=(host go java)

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
# shellcheck source=lib/plan.sh
source "$REPO_DIR/lib/plan.sh"
# shellcheck source=lib/agent.sh
source "$REPO_DIR/lib/agent.sh"
# shellcheck source=lib/run.sh
source "$REPO_DIR/lib/run.sh"
# shellcheck source=lib/prune.sh
source "$REPO_DIR/lib/prune.sh"
# shellcheck source=lib/parity.sh
source "$REPO_DIR/lib/parity.sh"
# shellcheck source=packs/host.sh
source "$REPO_DIR/packs/host.sh"
# shellcheck source=packs/go.sh
source "$REPO_DIR/packs/go.sh"
# shellcheck source=packs/java.sh
source "$REPO_DIR/packs/java.sh"

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

resolve_plan               # what goes into the project image and the container
confirm_plan               # shows a new or changed plan and asks
if ((!DRY_RUN)); then
  ensure_base_image
  # Once the base image exists, its package versions can be compared with the host's; any
  # difference shows up as a change to confirm before the project image is built.
  resolve_plan
  confirm_plan
fi
choose_project_image
add_plan_mounts            # the plan's caches, seeds and read-only mounts
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
if ((PARITY)); then
  run_parity
  exit
fi
print_banner
exec "${CMD[@]}"
