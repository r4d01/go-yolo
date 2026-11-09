# shellcheck shell=bash
# The project: the git repository root, and its .go-yolo/ state directory.
#
# .go-yolo/ holds go-yolo's per-project state (config, confirmed plan, build files); the caches
# are Docker volumes (see cache_volume).
# It ignores itself in git and is hidden from the container, so the agent can't change it and
# a repository can't ship one.
#
# Sets: PROJECT_DIR  the repository root (the physical path of $PWD)
#       STATE_DIR    $WORKDIR/.go-yolo, as the container sees it
#       PROJECT_SLUG <name>-<path hash>: names the project's image and cache volumes

PROJECT_DIR=""
STATE_DIR=""
PROJECT_SLUG=""

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
  PROJECT_SLUG="$(project_slug "$PROJECT_DIR")"
}

# project_slug DIR — "<name>-<path hash>" for project DIR, e.g. myapp-d0c6fbb2. Docker image and
# volume names allow [a-z0-9_.-] here; the hash keeps two projects called "app" apart.
project_slug() {
  local name
  name="$(basename -- "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_.\n-' '_' | cut -c1-40)"
  printf '%s-%s' "$name" "$(printf '%s' "$1" | sha256sum | cut -c1-8)"
}

# cache_volume NAME — the Docker volume that holds this project's cache NAME.
cache_volume() { printf 'go-yolo-%s-%s' "$PROJECT_SLUG" "$1"; }

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
  note_old_cache_dir
}

# Caches used to live in .go-yolo/cache/; now they are Docker volumes. Say so once.
note_old_cache_dir() {
  local dir="$PROJECT_DIR/.go-yolo"
  [[ -d $dir/cache && ! -e $dir/noted-old-cache ]] || return 0
  note "$dir/cache is no longer used (caches are Docker volumes now); remove it with: chmod -R u+w $dir/cache && rm -rf $dir/cache (shown once)"
  : >"$dir/noted-old-cache"
}
