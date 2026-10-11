#!/usr/bin/env bash
# go-yolo: run AI coding agents in a Docker container.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(dirname "$SELF")"
AGENTS=(claude codex vibe opencode shell)
SUPPORTED_DISTROS="debian, ubuntu, kali"
ALIAS_BEGIN='# >>> go-yolo aliases >>>'
ALIAS_END='# <<< go-yolo aliases <<<'

die() { printf 'go-yolo: error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'go-yolo: warning: %s\n' "$*" >&2; }
note() { printf 'go-yolo: %s\n' "$*" >&2; }

usage() {
  cat <<EOF
Usage: go-yolo.sh [launcher-opts] <agent> [agent args...]

agents:  ${AGENTS[*]}
opts:    --net open|allowlist|none   (default: open)
         --rebuild                   force image rebuild
         --yolo                      turn off the agent's permission prompts (default: off)
         --no-tmux                   don't run the agent inside tmux (default: tmux on a TTY;
                                     prefix c: extra shell)
         --dry-run                   print the docker command and exit
         -h | --help

alias commands (no agent needed):
  go-yolo.sh --print-aliases         print alias definitions to stdout
  go-yolo.sh --install-aliases       add the aliases to your shell rc file(s)
  go-yolo.sh --uninstall-aliases     remove them again

Everything after <agent> is passed to the agent unchanged.
EOF
}

# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------

alias_lines() {
  local agent value
  for agent in "${AGENTS[@]}"; do
    value="$(printf '%q' "$SELF") $agent"
    printf "alias gy-%s='%s'\n" "$agent" "${value//\'/\'\\\'\'}"
  done
}

rc_files() {
  printf '%s\n' "$HOME/.bashrc"
  if [[ -f $HOME/.zshrc ]]; then printf '%s\n' "$HOME/.zshrc"; fi
}

# Print the file without the go-yolo alias block.
strip_alias_block() {
  awk -v b="$ALIAS_BEGIN" -v e="$ALIAS_END" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip' "$1"
}

# Overwrite in place, keeping the inode (rc files are often symlinks into a dotfiles repo).
replace_contents() {
  local file=$1 tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

install_aliases() {
  local file files
  mapfile -t files < <(rc_files)
  for file in "${files[@]}"; do
    if [[ -e $file ]]; then
      # On a re-install keep the existing backup: it predates the go-yolo block.
      if [[ ! -e $file.go-yolo.bak ]] || ! grep -qxF "$ALIAS_BEGIN" "$file"; then
        cp -p -- "$file" "$file.go-yolo.bak"
      fi
    else
      : >"$file"
    fi
    {
      strip_alias_block "$file"
      printf '%s\n' "$ALIAS_BEGIN"
      alias_lines
      printf '%s\n' "$ALIAS_END"
    } | replace_contents "$file"
    note "updated $file (backup: $file.go-yolo.bak)"
  done
  note "open a new shell or run: source ${files[0]}"
}

uninstall_aliases() {
  local file files changed=0
  mapfile -t files < <(rc_files)
  for file in "${files[@]}"; do
    if [[ ! -f $file ]] || ! grep -qxF "$ALIAS_BEGIN" "$file"; then continue; fi
    strip_alias_block "$file" | replace_contents "$file"
    note "removed go-yolo aliases from $file"
    changed=1
  done
  if ((changed)); then
    note "open a new shell for the change to take effect (or: unalias gy-claude gy-codex gy-vibe gy-opencode gy-shell)"
  else
    note "no go-yolo aliases found"
  fi
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

NET=open
REBUILD=0
YOLO=0
USE_TMUX=1
TMUX_FORCED=0
DRY_RUN=0

while (($#)); do
  case $1 in
    --net)
      (($# >= 2)) || die "--net needs a value (open|allowlist|none)"
      NET=$2; shift 2 ;;
    --net=*) NET=${1#*=}; shift ;;
    --rebuild) REBUILD=1; shift ;;
    --yolo) YOLO=1; shift ;;
    --tmux) USE_TMUX=1; TMUX_FORCED=1; shift ;;
    --no-tmux) USE_TMUX=0; TMUX_FORCED=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --print-aliases) alias_lines; exit 0 ;;
    --install-aliases) install_aliases; exit 0 ;;
    --uninstall-aliases) uninstall_aliases; exit 0 ;;
    --) shift; break ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) break ;;
  esac
done

case $NET in
  open|allowlist|none) ;;
  *) die "invalid --net value '$NET' (use open, allowlist or none)" ;;
esac

if (($# == 0)); then
  usage >&2
  exit 2
fi
AGENT=$1
shift
if [[ " ${AGENTS[*]} " != *" $AGENT "* ]]; then
  die "unknown agent '$AGENT'; valid agents: ${AGENTS[*]}"
fi

# ---------------------------------------------------------------------------
# Host detection
# ---------------------------------------------------------------------------

os_release_get() {
  local line value
  line="$(grep -E "^$1=" "$2" | tail -n 1 || true)"
  value=${line#*=}
  value=${value#[\"\']}
  value=${value%[\"\']}
  printf '%s' "$value"
}

OS_RELEASE=${GOYOLO_OS_RELEASE:-/etc/os-release}
[[ -r $OS_RELEASE ]] || die "cannot read $OS_RELEASE; supported host distros: $SUPPORTED_DISTROS"
HOST_ID="$(os_release_get ID "$OS_RELEASE")"
HOST_CODENAME="$(os_release_get VERSION_CODENAME "$OS_RELEASE")"

case $HOST_ID in
  debian|ubuntu|kali) ;;
  *) die "unsupported host distro '${HOST_ID:-unknown}' (from $OS_RELEASE); supported: $SUPPORTED_DISTROS" ;;
esac
[[ $HOST_CODENAME =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
  || die "VERSION_CODENAME missing or invalid in $OS_RELEASE; supported host distros: $SUPPORTED_DISTROS"

case $HOST_ID in
  debian) BASE_IMAGE="debian:$HOST_CODENAME" ;;
  ubuntu) BASE_IMAGE="ubuntu:$HOST_CODENAME" ;;
  kali) BASE_IMAGE="kalilinux/kali-rolling" ;;
esac

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
HOST_USER="$(id -un)"
[[ $HOME == /* ]] || die "\$HOME must be an absolute path"
HOME_DIR=${HOME%/}

# ---------------------------------------------------------------------------
# Image
# ---------------------------------------------------------------------------

compute_hash() {
  (
    cd "$REPO_DIR"
    find Dockerfile entrypoint.sh scripts agents firewall tmux -type f -print0 \
      | LC_ALL=C sort -z | xargs -0 sha256sum
  ) | sha256sum | cut -c1-8
}

HASH="$(compute_hash)"
IMAGE_BASE="go-yolo:${HOST_ID}-${HOST_CODENAME}"
IMAGE="${IMAGE_BASE}-${HASH}"

ensure_image() {
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
  if ((REBUILD)) || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    local build=(docker build --build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "GOYOLO_HASH=$HASH")
    local var
    # Optional version pins, e.g. GOYOLO_CLAUDE_VERSION=2.1.0 (use with --rebuild).
    for var in NODE_MAJOR UV_VERSION CLAUDE_VERSION CODEX_VERSION OPENCODE_VERSION VIBE_VERSION; do
      local env_name="GOYOLO_$var"
      if [[ -n ${!env_name:-} ]]; then build+=(--build-arg "$var=${!env_name}"); fi
    done
    if ((REBUILD)); then build+=(--pull); fi
    build+=(-t "$IMAGE" -t "$IMAGE_BASE" "$REPO_DIR")
    note "building $IMAGE from $BASE_IMAGE"
    "${build[@]}" >&2
  else
    docker tag "$IMAGE" "$IMAGE_BASE"
  fi
}

# ---------------------------------------------------------------------------
# Mounts
# ---------------------------------------------------------------------------

MOUNTS=()
declare -A MOUNTED=()
MOUNT_ORDER=()

# Quote one field of a --mount value (docker parses it as CSV).
csv_field() {
  if [[ $1 == *[,\"]* ]]; then
    printf '"%s"' "${1//\"/\"\"}"
  else
    printf '%s' "$1"
  fi
}

# add_mount PATH rw|ro — bind PATH at the same path in the container.
add_mount() {
  local path=$1 mode=$2 spec
  [[ $path == /* ]] || die "mount path must be absolute: $path"
  [[ $path != *$'\n'* ]] || die "mount path contains a newline: $path"
  [[ $path == / ]] || path=${path%/}
  [[ -z ${MOUNTED[$path]:-} ]] || return 0
  MOUNTED[$path]=$mode
  MOUNT_ORDER+=("$path")
  spec="type=bind,$(csv_field "source=$path"),$(csv_field "target=$path")"
  if [[ $mode == ro ]]; then spec+=",readonly"; fi
  MOUNTS+=(--mount "$spec")
}

is_under() { [[ $1 == "$2" || $1 == "$2"/* ]]; }

# Workdir: refuse $HOME, / or any ancestor of $HOME — that would expose too much.
WORKDIR=$PWD
WORKDIR_REAL="$(pwd -P)"
HOME_REAL="$(readlink -f "$HOME_DIR" || printf '%s' "$HOME_DIR")"
for dir in "$WORKDIR" "$WORKDIR_REAL"; do
  if [[ $dir == / ]] || is_under "$HOME_DIR" "$dir" || is_under "$HOME_REAL" "$dir"; then
    die "refusing to run in $dir: it is / or contains your home directory; cd into a project directory"
  fi
done
add_mount "$WORKDIR" rw

if [[ -f $HOME_DIR/.gitconfig ]]; then add_mount "$HOME_DIR/.gitconfig" ro; fi

# Go toolchain and caches.
GO_ENV=()
if command -v go >/dev/null 2>&1; then
  mapfile -t go_vars < <(go env GOROOT GOPATH GOCACHE GOMODCACHE GOENV)
  GOROOT_DIR=${go_vars[0]:-}
  GOPATH_DIR=${go_vars[1]%%:*}
  GOCACHE_DIR=${go_vars[2]:-}
  GOMODCACHE_DIR=${go_vars[3]:-}
  GOENV_FILE=${go_vars[4]:-}
  GOPATH_MODE=${GOYOLO_GOPATH_MODE:-rw}

  if [[ -d $GOROOT_DIR ]]; then add_mount "$GOROOT_DIR" ro; fi
  case $GOPATH_MODE in
    rw|ro)
      if [[ -d $GOPATH_DIR ]]; then add_mount "$GOPATH_DIR" "$GOPATH_MODE"; fi
      if [[ -d $GOMODCACHE_DIR ]] && ! is_under "$GOMODCACHE_DIR" "$GOPATH_DIR"; then
        add_mount "$GOMODCACHE_DIR" "$GOPATH_MODE"
      fi
      ;;
    modcache)
      if [[ -d $GOMODCACHE_DIR ]]; then add_mount "$GOMODCACHE_DIR" rw; fi
      ;;
    *) die "invalid GOYOLO_GOPATH_MODE '$GOPATH_MODE' (use rw, ro or modcache)" ;;
  esac
  if [[ -d $GOCACHE_DIR ]]; then add_mount "$GOCACHE_DIR" rw; fi
  if [[ -f $GOENV_FILE ]]; then add_mount "$GOENV_FILE" ro; fi

  GO_ENV=(-e "GOROOT=$GOROOT_DIR" -e "GOPATH=${go_vars[1]}" -e "GOCACHE=$GOCACHE_DIR" -e "GOMODCACHE=$GOMODCACHE_DIR")
  if [[ -f $GOENV_FILE ]]; then GO_ENV+=(-e "GOENV=$GOENV_FILE"); fi
else
  warn "go not found on PATH; starting without the Go toolchain"
fi

# Agent config: only the selected agent's AGENT_MOUNTS, never another agent's.
AGENT_MOUNTS=()
if [[ $AGENT != shell ]]; then
  # shellcheck source=/dev/null
  source "$REPO_DIR/agents/$AGENT.conf"
fi

looks_like_file() {
  local name=${1##*/}
  name=${name#.}
  [[ $name == *.* ]]
}

for path in "${AGENT_MOUNTS[@]}"; do
  if [[ -e $path ]]; then
    add_mount "$path" rw
  elif looks_like_file "$path"; then
    note "skipping $path (does not exist)"
  elif ((DRY_RUN)); then
    note "would create $path (mode 700) so a login inside the container persists"
    add_mount "$path" rw
  else
    mkdir -p -- "$path"
    chmod 700 -- "$path"
    note "created $path (mode 700) so a login inside the container persists"
    add_mount "$path" rw
  fi
done

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

NET_ARGS=()
case $NET in
  open) ;;
  allowlist) NET_ARGS=(--cap-add=NET_ADMIN --cap-add=NET_RAW) ;;
  none) NET_ARGS=(--network none) ;;
esac

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

PWD_HASH="$(printf '%s' "$WORKDIR" | sha256sum | cut -c1-8)"
RAND_SUFFIX="$(printf '%04x' $((RANDOM % 65536)))"

CMD=(docker run --rm)
if [[ -t 0 && -t 1 ]]; then
  CMD+=(-it)
else
  # tmux needs a terminal. It is the default, so fall back to running the agent directly
  # (e.g. for piped or scripted runs) unless --tmux was given explicitly.
  if ((TMUX_FORCED && !DRY_RUN)); then die "--tmux needs a terminal (stdin and stdout must be a TTY)"; fi
  if ((!TMUX_FORCED)); then USE_TMUX=0; fi
  CMD+=(-i)
fi
CMD+=(
  --name "go-yolo-$AGENT-$PWD_HASH-$RAND_SUFFIX"
  --hostname go-yolo
  --security-opt no-new-privileges
  -w "$WORKDIR"
  -e "GOYOLO_UID=$HOST_UID"
  -e "GOYOLO_GID=$HOST_GID"
  -e "GOYOLO_USER=$HOST_USER"
  -e "GOYOLO_HOME=$HOME_DIR"
  -e "GOYOLO_AGENT=$AGENT"
  -e "GOYOLO_NET=$NET"
  -e "GOYOLO_YOLO=$YOLO"
  -e "GOYOLO_TMUX=$USE_TMUX"
  -e "GOYOLO_EXTRA_DOMAINS=${GOYOLO_EXTRA_DOMAINS:-}"
)
# Nested tmux: the container's tmux switches its prefix to C-a.
if [[ -n ${TMUX:-} ]]; then CMD+=(-e GOYOLO_HOST_TMUX=1); fi
for var in TERM COLORTERM LANG; do
  if [[ -n ${!var:-} ]]; then CMD+=(-e "$var"); fi
done
# The image may lack the host terminal's terminfo entry (xterm-ghostty, xterm-kitty, ...)
# and tmux refuses to start without it; pass the host's entry along.
if [[ -n ${TERM:-} ]] && command -v infocmp >/dev/null 2>&1 \
  && terminfo="$(infocmp -x "$TERM" 2>/dev/null)"; then
  CMD+=(-e "GOYOLO_TERMINFO=$terminfo")
fi
CMD+=("${GO_ENV[@]}" "${MOUNTS[@]}" "${NET_ARGS[@]}" "$IMAGE" "$@")

if ((YOLO)); then
  if [[ $NET == open ]]; then
    warn "YOLO mode: $AGENT runs without permission prompts and network access is unrestricted (consider --net allowlist)"
  else
    warn "YOLO mode: $AGENT runs without permission prompts"
  fi
fi

if ((DRY_RUN)); then
  printf '%q\n' "${CMD[@]}"
  exit 0
fi

# One line on stderr, so the agent's stdout stays clean. GOYOLO_QUIET=1 turns it off.
print_banner() {
  local path mode rw="" ro="" yolo=off line
  for path in "${MOUNT_ORDER[@]}"; do
    mode=${MOUNTED[$path]}
    if [[ $path == "$HOME_DIR"/* ]]; then path=\~/${path#"$HOME_DIR"/}; fi
    if [[ $mode == ro ]]; then ro+="${ro:+, }$path"; else rw+="${rw:+, }$path"; fi
  done
  if ((YOLO)); then yolo=ON; fi
  line="go-yolo: $AGENT in container $IMAGE · net=$NET · yolo=$yolo"
  if ((USE_TMUX)); then line+=" · tmux"; fi
  if [[ -n $rw ]]; then line+=" · rw: $rw"; fi
  if [[ -n $ro ]]; then line+=" · ro: $ro"; fi
  printf '%s\n' "$line" >&2
}

ensure_image
if [[ ${GOYOLO_QUIET:-0} != 1 ]]; then print_banner; fi
exec "${CMD[@]}"
