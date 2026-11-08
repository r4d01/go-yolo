#!/usr/bin/env bash
# go-yolo: run AI coding agents in a Docker container.
#
# This file only lists the steps of a run; each step lives in lib/<module>.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(dirname "$SELF")"
AGENTS=(claude codex vibe opencode shell)

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
# shellcheck source=lib/toolchains.sh
source "$REPO_DIR/lib/toolchains.sh"
# shellcheck source=lib/agent.sh
source "$REPO_DIR/lib/agent.sh"
# shellcheck source=lib/run.sh
source "$REPO_DIR/lib/run.sh"

ui_set_color auto
parse_args "$@"            # exits for --help and the alias commands
detect_host
choose_image

mount_workdir              # the project directory; refuses $HOME and its parents
check_project              # must be the git repository root
ensure_state_dir           # .go-yolo/

# More mounts. Explicit ones come first: the first mode given for a path wins.
add_user_mounts
add_git_config_mounts
add_go_mounts
add_tool_mounts
load_agent_profile
add_agent_mounts

set_network_args
decide_tmux
build_docker_command
warn_yolo

if ((DRY_RUN)); then
  printf '%q\n' "${CMD[@]}"
  exit 0
fi

ensure_image
print_banner
exec "${CMD[@]}"
