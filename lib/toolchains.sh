# shellcheck shell=bash
# Host toolchains mounted into the container: the tools listed in GOYOLO_TOOLS.
#
# (docs/PLAN.md replaces these mounts with toolchains copied into the project image, as the Go
# pack already does; GOYOLO_TOOLS goes in phase 4.)
#
# Sets: TOOL_ENV          docker run -e arguments for the GOYOLO_TOOLS toolchains
#       LEGACY_TOOL_PATH  their bin/ directories, for PATH (see tool_path in lib/run.sh)

TOOL_ENV=()
LEGACY_TOOL_PATH=""

# Cache directories (newline-separated) mounted read-write for each listed tool, even when the
# tool itself isn't installed, so ./mvnw and ./gradlew projects reuse them too.
declare -A TOOL_CACHES=()

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
  LEGACY_TOOL_PATH=$tool_path
  if [[ -n ${GRADLE_USER_HOME:-} && " ${tool_names[*]} " == *" gradle "* ]]; then
    TOOL_ENV+=(-e "GRADLE_USER_HOME=$GRADLE_USER_HOME")
  fi
}
