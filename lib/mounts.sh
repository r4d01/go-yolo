# shellcheck shell=bash
# Bind mounts: safety checks, and the workdir, extra and git config mounts.
#
# Every host path is mounted at the same path in the container.
#
# Sets: MOUNTS       docker run --mount arguments
#       MOUNTED      path -> rw|ro, for every mounted path
#       MOUNT_ORDER  mounted paths in the order they were added (for the banner)
#       VOLUME_TARGETS  the paths of the cache volume mounts
#       WORKDIR      the project directory ($PWD)

MOUNTS=()
declare -A MOUNTED=()
MOUNT_ORDER=()
VOLUME_TARGETS=()   # paths where cache volumes are mounted (the entrypoint hands them to the user)
WORKDIR=""

# is_under PATH DIR — true if PATH is DIR or inside it.
is_under() { [[ $1 == "$2" || $1 == "$2"/* ]]; }

# True if PATH must never be bind-mounted: system directories, go-yolo's own files, and
# $HOME or one of its parents.
is_system_dir() {
  case $1 in
    # The image's own files and everything used before the entrypoint drops privileges.
    # Descendants count too: one bind-mounted executable or library can shadow the image's.
    /opt/go-yolo|/opt/go-yolo/*) return 0 ;;
    /bin/*|/sbin/*|/lib/*|/lib32/*|/lib64/*) return 0 ;;
    /usr/bin/*|/usr/sbin/*|/usr/libexec/*|/usr/lib32/*|/usr/lib64/*) return 0 ;;
    /usr/local/bin/*|/usr/local/sbin/*|/usr/local/lib/*) return 0 ;;
    # Exception: a JDK installed by hand in /usr/lib/jvm/<name> can be copied into the image.
    /usr/lib/jvm/*) ;;
    /usr/lib/*) return 0 ;;
    /etc/*) return 0 ;;
    # Kernel and runtime trees.
    /run|/run/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*) return 0 ;;
    # System roots themselves (other descendants, such as /opt/foo, are allowed).
    /|/bin|/sbin|/lib|/lib32|/lib64|/etc|/opt|/var|/tmp|/home) return 0 ;;
    /usr|/usr/bin|/usr/sbin|/usr/lib|/usr/lib32|/usr/lib64|/usr/libexec) return 0 ;;
    /usr/share|/usr/share/doc|/usr/share/man|/usr/share/info|/usr/include) return 0 ;;
    /usr/local|/usr/local/bin|/usr/local/sbin|/usr/local/lib|/usr/local/share) return 0 ;;
  esac
  is_under "$HOME_DIR" "$1" || is_under "$HOME_REAL" "$1"
}

# Die unless PATH is safe to mount, both as written and with symlinks resolved.
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

# add_volume_mount PATH VOLUME — mount Docker volume VOLUME at PATH, read-write.
add_volume_mount() {
  local path=$1 volume=$2
  validate_mount_path "$path"
  path="$(realpath -ms -- "$path")"
  [[ -z ${MOUNTED[$path]:-} ]] || return 0
  MOUNTED[$path]=rw
  MOUNT_ORDER+=("$path")
  VOLUME_TARGETS+=("$path")
  MOUNTS+=(--mount "type=volume,$(csv_field "source=$volume"),$(csv_field "target=$path")")
}

# Quote one field of a --mount value (docker parses it as CSV).
csv_field() {
  if [[ $1 == *[,\"]* ]]; then
    printf '"%s"' "${1//\"/\"\"}"
  else
    printf '%s' "$1"
  fi
}

# add_mount PATH rw|ro [SOURCE] — bind PATH at the same path in the container; or, with
# SOURCE, bind SOURCE there (a project cache at the host's cache path, for example). The first
# mode given for a path wins.
add_mount() {
  local path=$1 mode=$2 source=${3:-$1} spec real
  validate_mount_path "$path"
  validate_mount_path "$source"
  # Resolve the source before lexical normalization: symlink/.. follows the symlink first.
  real="$(realpath -m -- "$source")"
  path="$(realpath -ms -- "$path")"
  [[ -z ${MOUNTED[$path]:-} ]] || return 0
  MOUNTED[$path]=$mode
  MOUNT_ORDER+=("$path")
  spec="type=bind,$(csv_field "source=$real"),$(csv_field "target=$path")"
  if [[ $mode == ro ]]; then spec+=",readonly"; fi
  MOUNTS+=(--mount "$spec")
}

# The project directory, read-write. Refuse $HOME, / or any parent of $HOME: too much.
mount_workdir() {
  local dir
  WORKDIR=$PWD
  for dir in "$WORKDIR" "$(pwd -P)"; do
    if [[ $dir == / ]] || is_under "$HOME_DIR" "$dir" || is_under "$HOME_REAL" "$dir"; then
      die "refusing to run in $dir: it is / or contains your home directory; cd into a project directory"
    fi
  done
  add_mount "$WORKDIR" rw
}

# Extra mounts from GOYOLO_MOUNTS, then --mount: PATH[:ro|:rw], read-only by default. They are
# added before the automatic mounts, so an explicit mode wins for a path mounted anyway.
add_user_mounts() {
  local env_mounts spec path mode
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
}

# Git config, read-only. For XDG config only these files: the directory may also hold a
# credential store.
add_git_config_mounts() {
  local file
  if [[ -f $HOME_DIR/.gitconfig ]]; then add_mount "$HOME_DIR/.gitconfig" ro; fi
  for file in config ignore attributes; do
    if [[ -f $HOME_DIR/.config/git/$file ]]; then add_mount "$HOME_DIR/.config/git/$file" ro; fi
  done
}
