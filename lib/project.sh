# shellcheck shell=bash
# The project: the git repository root, and its .go-yolo/ state directory.
#
# .go-yolo/ holds go-yolo's per-project state (config, confirmed plan, build files, caches).
# It ignores itself in git and is hidden from the container, so the agent can't change it and
# a repository can't ship one.
#
# Sets: PROJECT_DIR  the repository root (the physical path of $PWD)
#       STATE_DIR    $WORKDIR/.go-yolo, as the container sees it

PROJECT_DIR=""
STATE_DIR=""

# Die unless go-yolo runs from the root of a git repository.
check_project() {
  local top output
  command -v git >/dev/null 2>&1 || die "git not found on PATH"
  if ! output="$(git rev-parse --show-toplevel 2>&1)"; then
    die "not inside a git repository (${output#fatal: }); go-yolo runs from a repository's root directory (git init starts one)"
  fi
  top=$output
  PROJECT_DIR="$(pwd -P)"
  if [[ $PROJECT_DIR != "$(realpath -- "$top")" ]]; then
    die "run go-yolo from the repository's root directory: cd $top"
  fi
  STATE_DIR="$WORKDIR/.go-yolo"
}

# Die if an existing .go-yolo can't be trusted: not a plain directory of ours, or tracked by git.
check_state_dir() {
  local dir="$PROJECT_DIR/.go-yolo" tracked
  if [[ -L $dir ]]; then die "$dir is a symlink; .go-yolo must be a plain directory"; fi
  if [[ ! -e $dir ]]; then return 0; fi
  [[ -d $dir ]] || die "$dir is not a directory"
  [[ $(stat -c %u -- "$dir") == "$HOST_UID" ]] || die "$dir is not owned by you"

  tracked="$(git ls-files -- .go-yolo | head -n 3)"
  if [[ -n $tracked ]]; then
    die "the repository tracks files in .go-yolo/ (${tracked//$'\n'/, }); a repository must not ship go-yolo state"
  fi
}

# Create .go-yolo/ if needed (mode 700), with a .gitignore that makes git ignore all of it.
ensure_state_dir() {
  local dir="$PROJECT_DIR/.go-yolo"
  check_state_dir
  if ((DRY_RUN)); then
    if [[ ! -d $dir ]]; then note "would create $dir"; fi
    return 0
  fi
  if [[ ! -d $dir ]]; then
    mkdir -m 700 -- "$dir"
    note "created $dir (ignored by git; hidden from the container)"
  fi
  if [[ ! -e $dir/.gitignore ]]; then printf '*\n' >"$dir/.gitignore"; fi
  warn_dockerignore
}

# Warn once if the project builds Docker images without excluding .go-yolo/ from the build
# context: the caches would be sent to every `docker build`.
warn_dockerignore() {
  local marker="$PROJECT_DIR/.go-yolo/warned-dockerignore"
  [[ -f $PROJECT_DIR/Dockerfile && ! -e $marker ]] || return 0
  if [[ -f $PROJECT_DIR/.dockerignore ]] && grep -qE '^/?\.go-yolo/?(\*\*)?$' "$PROJECT_DIR/.dockerignore"; then
    return 0
  fi
  warn "this project has a Dockerfile; add .go-yolo/ to its .dockerignore, or its caches end up in the build context (shown once)"
  : >"$marker"
}
