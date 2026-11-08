# shellcheck shell=bash
# Host toolchains mounted into the container: Go, and the tools listed in GOYOLO_TOOLS.
#
# (docs/PLAN.md replaces these mounts with toolchains copied into a per-project image:
# Go in phase 1, GOYOLO_TOOLS in phase 4.)
#
# Sets: GO_ENV    docker run -e arguments for the Go toolchain
#       TOOL_ENV  docker run -e arguments for the GOYOLO_TOOLS toolchains

GO_ENV=()
TOOL_ENV=()

# Cache directories (newline-separated) mounted read-write for each listed tool, even when the
# tool itself isn't installed, so ./mvnw and ./gradlew projects reuse them too.
declare -A TOOL_CACHES=()

# Go toolchain (GOROOT, read-only) and its caches, as the host's `go env` reports them.
add_go_mounts() {
  if ! command -v go >/dev/null 2>&1; then
    warn "go not found on PATH; starting without the Go toolchain"
    return 0
  fi

  local go_vars goroot gopath gocache gomodcache goenv_file mode
  mapfile -t go_vars < <(go env GOROOT GOPATH GOCACHE GOMODCACHE GOENV)
  goroot=${go_vars[0]:-}
  gopath=${go_vars[1]%%:*}   # only the first entry of a GOPATH list
  gocache=${go_vars[2]:-}
  gomodcache=${go_vars[3]:-}
  goenv_file=${go_vars[4]:-}
  mode=${GOYOLO_GOPATH_MODE:-rw}

  if [[ -d $goroot ]]; then add_mount "$goroot" ro; fi
  case $mode in
    rw|ro)
      if [[ -d $gopath ]]; then add_mount "$gopath" "$mode"; fi
      if [[ -d $gomodcache ]] && ! is_under "$gomodcache" "$gopath"; then
        add_mount "$gomodcache" "$mode"
      fi
      ;;
    modcache)
      if [[ -d $gomodcache ]]; then add_mount "$gomodcache" rw; fi
      ;;
    *) die "invalid GOYOLO_GOPATH_MODE '$mode' (use rw, ro or modcache)" ;;
  esac
  if [[ -d $gocache ]]; then add_mount "$gocache" rw; fi
  if [[ -f $goenv_file ]]; then add_mount "$goenv_file" ro; fi

  GO_ENV=(-e "GOROOT=$goroot" -e "GOPATH=${go_vars[1]}" -e "GOCACHE=$gocache" -e "GOMODCACHE=$gomodcache")
  if [[ -f $goenv_file ]]; then GO_ENV+=(-e "GOENV=$goenv_file"); fi
}

# tool_home NAME — print the install dir of tool NAME: the parent of the bin/ directory its
# executable resolves into. Fails if the tool isn't found or has no such layout.
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

# GOYOLO_TOOLS (default "java mvn gradle"): each tool's install dir is mounted read-only and its
# bin/ is put on PATH. A set but empty GOYOLO_TOOLS mounts none.
add_tool_mounts() {
  local tool_names tool home tool_path="" caches cache
  TOOL_CACHES=(
    [mvn]="$HOME_DIR/.m2"
    [gradle]="${GRADLE_USER_HOME:-$HOME_DIR/.gradle}"
    [sbt]="$HOME_DIR/.sbt"$'\n'"$HOME_DIR/.ivy2"$'\n'"$HOME_DIR/.cache/coursier"
  )

  read -d '' -ra tool_names <<<"${GOYOLO_TOOLS-java mvn gradle}" || true
  for tool in "${tool_names[@]}"; do
    [[ $tool =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid tool name '$tool' in GOYOLO_TOOLS"

    if home="$(tool_home "$tool")"; then
      if is_system_dir "$home"; then
        warn "not mounting $tool: it is installed straight into $home/bin (only <install dir>/bin layouts are supported)"
      else
        add_tree_mount "$home"
        tool_path+="${tool_path:+:}$home/bin"
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

  # The entrypoint puts these first on PATH, after it has dropped privileges.
  if [[ -n $tool_path ]]; then TOOL_ENV+=(-e "GOYOLO_TOOL_PATH=$tool_path"); fi
  if [[ -n ${GRADLE_USER_HOME:-} && " ${tool_names[*]} " == *" gradle "* ]]; then
    TOOL_ENV+=(-e "GRADLE_USER_HOME=$GRADLE_USER_HOME")
  fi
}
