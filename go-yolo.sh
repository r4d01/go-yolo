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
         --no-tmux                   don't run the agent inside tmux (default: tmux on a TTY,
                                     except for non-interactive runs such as claude -p;
                                     prefix c: extra shell)
         --tmux                      always use tmux, even for non-interactive runs
         --mount PATH[:ro|:rw]       also mount PATH at the same path (default: ro; repeatable)
         --dry-run                   print the docker command and exit
         -h | --help

env:     GOYOLO_TOOLS="java mvn gradle"  host tools to mount (read-only) and put on PATH
                                     (default shown; add e.g. sbt kotlin ant, or set empty)
         GOYOLO_MOUNTS="PATH[:ro|:rw] ..."  extra mounts, like --mount (whitespace-separated)
         GOYOLO_GOPATH_MODE=rw|ro|modcache  how GOPATH is mounted (default: rw)
         GOYOLO_EXTRA_DOMAINS="a.example ..."  more domains for --net allowlist
         GOYOLO_QUIET=1                     don't print the mount summary line
         GOYOLO_{CLAUDE,CODEX,OPENCODE,VIBE,UV}_VERSION, GOYOLO_NODE_MAJOR
                                     version pins for the image build (use with --rebuild)

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
USER_MOUNTS=()

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
    --mount)
      (($# >= 2)) || die "--mount needs a value (PATH[:ro|:rw])"
      USER_MOUNTS+=("$2"); shift 2 ;;
    --mount=*) USER_MOUNTS+=("${1#*=}"); shift ;;
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
    if ((REBUILD)); then build+=(--pull --no-cache); fi
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
  local path=$1 mode=$2 spec real
  validate_mount_path "$path"
  # Resolve the source before lexical normalization: symlink/.. follows the symlink first.
  real="$(realpath -m -- "$path")"
  path="$(realpath -ms -- "$path")"
  [[ -z ${MOUNTED[$path]:-} ]] || return 0
  MOUNTED[$path]=$mode
  MOUNT_ORDER+=("$path")
  spec="type=bind,$(csv_field "source=$real"),$(csv_field "target=$path")"
  if [[ $mode == ro ]]; then spec+=",readonly"; fi
  MOUNTS+=(--mount "$spec")
}

is_under() { [[ $1 == "$2" || $1 == "$2"/* ]]; }

# System directories (and $HOME or its ancestors) that must never be bind-mounted from the host.
is_system_dir() {
  case $1 in
    # These locations are used before the entrypoint drops privileges. Protect
    # descendants too: a single bind-mounted executable/library can shadow the image.
    /opt/go-yolo|/opt/go-yolo/*) return 0 ;;
    /bin/*|/sbin/*|/lib/*|/lib32/*|/lib64/*) return 0 ;;
    /usr/bin/*|/usr/sbin/*|/usr/libexec/*) return 0 ;;
    /usr/local/bin/*|/usr/local/sbin/*|/usr/local/lib/*|/usr/lib32/*|/usr/lib64/*) return 0 ;;
    /usr/lib/*)
      # Debian JDKs live here; their external symlink targets are checked separately.
      case $1 in /usr/lib/jvm|/usr/lib/jvm/*) ;; *) return 0 ;; esac ;;
    /etc/*)
      # Keep the data directories needed by Debian's host-mounted JDKs usable.
      case $1 in
        /etc/java-*-openjdk|/etc/java-*-openjdk/*|/etc/ssl/certs/java|/etc/ssl/certs/java/*) ;;
        *) return 0 ;;
      esac ;;
    /run|/run/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*) return 0 ;;
    /|/bin|/sbin|/lib|/lib32|/lib64|/etc|/etc/alternatives|/opt|/var|/tmp|/home) return 0 ;;
    /usr|/usr/bin|/usr/sbin|/usr/lib|/usr/lib32|/usr/lib64|/usr/libexec|/usr/lib/*-linux-gnu*) return 0 ;;
    /usr/share|/usr/share/doc|/usr/share/man|/usr/share/info|/usr/include) return 0 ;;
    /usr/local|/usr/local/bin|/usr/local/sbin|/usr/local/lib|/usr/local/share) return 0 ;;
  esac
  is_under "$HOME_DIR" "$1" || is_under "$HOME_REAL" "$1"
}

validate_mount_path() {
  local path=$1 real normalized
  [[ $path == /* ]] || die "mount path must be absolute: $path"
  [[ $path != *$'\n'* ]] || die "mount path contains a newline: $path"
  real="$(realpath -m -- "$path")"
  normalized="$(realpath -ms -- "$path")"
  if is_system_dir "$normalized" || is_system_dir "$real"; then
    die "refusing to mount $path: it is a system directory, your home directory or one of its parents"
  fi
}

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

# Extra mounts (GOYOLO_MOUNTS, then --mount): PATH[:ro|:rw], read-only by default. Added before
# the automatic mounts, so an explicit mode wins for a path that would be mounted anyway.
# read -d '': split on all whitespace, newlines included (read stops at the first newline).
read -d '' -ra env_mounts <<<"${GOYOLO_MOUNTS:-}" || true
for spec in "${env_mounts[@]}" "${USER_MOUNTS[@]}"; do
  case $spec in
    *:ro) path=${spec%:ro}; mode=ro ;;
    *:rw) path=${spec%:rw}; mode=rw ;;
    *) path=$spec; mode=ro ;;
  esac
  [[ -n $path ]] || die "empty mount path in '$spec'"
  [[ -e $path ]] || die "mount path does not exist: $path"
  if [[ $path != /* ]]; then path="$PWD/$path"; fi
  add_mount "$path" "$mode"
done

if [[ -f $HOME_DIR/.gitconfig ]]; then add_mount "$HOME_DIR/.gitconfig" ro; fi
# XDG git config. Only these files: the directory may also hold a credential store.
for file in config ignore attributes; do
  if [[ -f $HOME_DIR/.config/git/$file ]]; then add_mount "$HOME_DIR/.config/git/$file" ro; fi
done

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

# Other host toolchains (GOYOLO_TOOLS): each tool's install dir is mounted read-only and its
# bin/ is put on PATH. A set but empty GOYOLO_TOOLS mounts none.
TOOLS=${GOYOLO_TOOLS-java mvn gradle}
TOOL_ENV=()
TOOL_PATH=""
# Cache dirs (newline-separated) mounted read-write for each listed tool, even when the tool
# itself isn't installed, so ./mvnw and ./gradlew projects reuse them too.
declare -A TOOL_CACHES=(
  [mvn]="$HOME_DIR/.m2"
  [gradle]="${GRADLE_USER_HOME:-$HOME_DIR/.gradle}"
  [sbt]="$HOME_DIR/.sbt"$'\n'"$HOME_DIR/.ivy2"$'\n'"$HOME_DIR/.cache/coursier"
)


# Install dir of tool NAME: the parent of the bin/ directory its executable resolves into.
tool_home() {
  local name=$1 bin real home
  if [[ $name == java && -n ${JAVA_HOME:-} && -x $JAVA_HOME/bin/java ]]; then
    readlink -f "$JAVA_HOME"
    return 0
  fi
  bin="$(command -v "$name" 2>/dev/null)" || return 1
  [[ $bin == /* ]] || return 1
  real="$(readlink -f "$bin")" || return 1
  [[ ${real%/*} == */bin ]] || return 1
  home=${real%/bin/*}
  # Java 8 layout: <jdk>/jre/bin/java — prefer the JDK, which has javac.
  if [[ $name == java && $home == */jre && -x ${home%/jre}/bin/javac ]]; then home=${home%/jre}; fi
  printf '%s' "${home:-/}"
}

# Mount DIR read-only plus the directories its symlinks point into outside DIR (Debian JDKs link
# into /etc/java-N-openjdk and /etc/ssl/certs/java, Debian's maven into /usr/share/java).
add_tree_mount() {
  local dir=$1 link target parent
  local -A seen=()
  add_mount "$dir" ro
  while IFS= read -r -d '' link; do
    target="$(readlink -f "$link")" || continue
    [[ -e $target ]] && ! is_under "$target" "$dir" || continue
    parent=${target%/*}
    seen[${parent:-/}]=1
  done < <(find "$dir" -type l -print0 2>/dev/null)
  while IFS= read -r parent; do
    [[ -n $parent ]] && ! is_system_dir "$parent" || continue
    local mounted covered=0
    for mounted in "${MOUNT_ORDER[@]}"; do
      if is_under "$parent" "$mounted"; then covered=1; break; fi
    done
    if ((!covered)); then add_mount "$parent" ro; fi
  done < <(printf '%s\n' "${!seen[@]}" | awk '{ print length, $0 }' | sort -n | cut -d' ' -f2-)
}

read -d '' -ra TOOL_NAMES <<<"$TOOLS" || true
for tool in "${TOOL_NAMES[@]}"; do
  [[ $tool =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid tool name '$tool' in GOYOLO_TOOLS"
  if home="$(tool_home "$tool")"; then
    if is_system_dir "$home"; then
      warn "not mounting $tool: it is installed straight into $home/bin (only <install dir>/bin layouts are supported)"
    else
      add_tree_mount "$home"
      TOOL_PATH+="${TOOL_PATH:+:}$home/bin"
      if [[ $tool == java ]]; then TOOL_ENV+=(-e "JAVA_HOME=$home"); fi
    fi
  fi
  if [[ -n ${TOOL_CACHES[$tool]:-} ]]; then
    mapfile -t caches <<<"${TOOL_CACHES[$tool]}"
    for cache in "${caches[@]}"; do
      if [[ -d $cache ]]; then add_mount "$cache" rw; fi
    done
  fi
done
if [[ -n $TOOL_PATH ]]; then TOOL_ENV+=(-e "GOYOLO_TOOL_PATH=$TOOL_PATH"); fi
if [[ -n ${GRADLE_USER_HOME:-} && " ${TOOL_NAMES[*]} " == *" gradle "* ]]; then
  TOOL_ENV+=(-e "GRADLE_USER_HOME=$GRADLE_USER_HOME")
fi

# Agent config: only the selected agent's AGENT_MOUNTS, never another agent's.
AGENT_MOUNTS=()
# Non-interactive runs (no tmux): flags anywhere in the agent args, subcommands as the first.
AGENT_BATCH_ARGS=(-c)  # shell: bash -c runs a command and exits
AGENT_BATCH_COMMANDS=()
if [[ $AGENT != shell ]]; then
  AGENT_BATCH_ARGS=()
  # shellcheck source=/dev/null
  source "$REPO_DIR/agents/$AGENT.conf"
fi

looks_like_file() {
  local name=${1##*/}
  name=${name#.}
  [[ $name == *.* ]]
}

for path in "${AGENT_MOUNTS[@]}"; do
  # Validate before creating a missing config directory on the host.
  validate_mount_path "$path"
  if [[ -e $path ]]; then
    add_mount "$path" rw
  elif [[ $path == *.json ]]; then
    # Without the mount the agent would write this file into the container's home and lose it.
    if ((DRY_RUN)); then
      note "would create $path (mode 600, containing {}) so it persists"
    else
      (umask 077 && printf '{}\n' >"$path")
      note "created $path (mode 600, containing {}) so it persists"
    fi
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

# A non-interactive run (claude -p, codex exec, ...) would print into a tmux window that
# closes as soon as the agent exits, so run it directly unless --tmux was given.
if ((USE_TMUX && !TMUX_FORCED && $#)); then
  for batch in "${AGENT_BATCH_COMMANDS[@]}"; do
    if [[ $1 == "$batch" ]]; then USE_TMUX=0; fi
  done
  for arg in "$@"; do
    for batch in --help --version "${AGENT_BATCH_ARGS[@]}"; do
      if [[ $arg == "$batch" ]]; then USE_TMUX=0; fi
    done
  done
fi

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
CMD+=("${GO_ENV[@]}" "${TOOL_ENV[@]}" "${MOUNTS[@]}" "${NET_ARGS[@]}" "$IMAGE" "$@")

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
