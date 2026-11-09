# shellcheck shell=bash
# The Docker images.
#
#   go-yolo-base:<distro>-<codename>-<hash>   shared by all projects: OS, agents, entrypoint
#           ▲ FROM
#   go-yolo:<project>-<path hash>-<plan hash> one per project: the plan's build-time items,
#                                             installed from their source (lib/recipes.sh) or
#                                             copied from the host
#
# The base hash covers every file copied into the base image, the plan hash every build-time
# plan line (the base tag included), so any change gets its own image.
#
# Sets: HASH         hash of the base image files (8 hex digits)
#       BASE_TAG     go-yolo-base:<distro>-<codename>-<hash>
#       BASE_LATEST  go-yolo-base:<distro>-<codename>, pointing at the newest base build
#       IMAGE        the project image

# Hash of the files copied into the base image (first 8 hex digits).
compute_hash() {
  (
    cd "$REPO_DIR"
    find Dockerfile entrypoint.sh scripts agents firewall tmux -type f -print0 \
      | LC_ALL=C sort -z | xargs -0 sha256sum
  ) | sha256sum | cut -c1-8
}

choose_base_image() {
  HASH="$(compute_hash)"
  BASE_LATEST="go-yolo-base:${HOST_ID}-${HOST_CODENAME}"
  BASE_TAG="$BASE_LATEST-$HASH"
}

choose_project_image() {
  IMAGE="go-yolo:$PROJECT_SLUG-$PLAN_HASH"
}

# Print the base image's installed packages, one "name<TAB>version" per line; nothing if the
# base image doesn't exist yet. Cached per image ID (a rebuild gets a new ID).
base_packages() {
  local id cache
  command -v docker >/dev/null 2>&1 || return 0
  id="$(docker image inspect -f '{{.Id}}' "$BASE_TAG" 2>/dev/null)" || return 0
  [[ -n $id ]] || return 0
  cache="${XDG_CACHE_HOME:-$HOME_DIR/.cache}/go-yolo/base-packages-${id#sha256:}"
  if [[ ! -f $cache ]]; then
    mkdir -p -- "${cache%/*}"
    docker run --rm --entrypoint dpkg-query "$BASE_TAG" \
      -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\n' \
      | awk -F'\t' '$1 ~ /^ii/ { print $2 "\t" $3 }' >"$cache.tmp"
    mv -- "$cache.tmp" "$cache"
  fi
  cat -- "$cache"
}

# Build the base image unless it exists already (or --rebuild was given).
ensure_base_image() {
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
  if ((!REBUILD)) && docker image inspect "$BASE_TAG" >/dev/null 2>&1; then
    docker tag "$BASE_TAG" "$BASE_LATEST"
    return 0
  fi

  local build=(docker build --build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "GOYOLO_HASH=$HASH")
  local var env_name
  # Optional version pins, e.g. GOYOLO_CLAUDE_VERSION=2.1.0 (use with --rebuild).
  for var in NODE_MAJOR UV_VERSION CLAUDE_VERSION CODEX_VERSION OPENCODE_VERSION VIBE_VERSION; do
    env_name="GOYOLO_$var"
    if [[ -n ${!env_name:-} ]]; then build+=(--build-arg "$var=${!env_name}"); fi
  done
  if ((REBUILD)); then build+=(--pull --no-cache); fi
  build+=(-t "$BASE_TAG" -t "$BASE_LATEST" "$REPO_DIR")
  note "building $BASE_TAG from $BASE_IMAGE"
  "${build[@]}" >&2
}

# Print the host directories the plan copies into the image, one "path<TAB>flags" per line.
# The Nth line is build context copyN (see ensure_project_image).
plan_copies() {
  local line kind group method name value flags
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name value flags <<<"$line"
    if [[ $method == copy && ( $kind == toolchain || $kind == tools ) ]]; then
      printf '%s\t%s\n' "$name" "$flags"
    fi
  done
}

# json_string TEXT — TEXT as a JSON string (for Dockerfile COPY's ["src", "dest"] form).
json_string() {
  local text=${1//\\/\\\\}
  printf '"%s"' "${text//\"/\\\"}"
}

# Print Dockerfile lines that create PATH's missing parent directories under $HOME, owned by
# you and with the host's modes (755 where the host has none), so a directory copied there is reachable as on the host.
# CREATED (an associative array name) remembers the ones already made.
user_parents() {
  local path=$1 dir
  local -n made=$2
  local parents=()
  dir=${path%/*}
  while is_under "$dir" "$HOME_DIR"; do
    parents=("$dir" "${parents[@]}")
    [[ $dir != "$HOME_DIR" ]] || break
    dir=${dir%/*}
  done
  for dir in "${parents[@]}"; do
    [[ -z ${made[$dir]:-} ]] || continue
    made[$dir]=1
    # The host's mode; 755 for a directory the host doesn't have (an SDK it doesn't have).
    printf 'RUN install -d -o %s -g %s -m %s %q\n' "$HOST_UID" "$HOST_GID" "$(stat -c %a -- "$dir" 2>/dev/null || printf 755)" "$dir"
  done
}

# locale_input NAME — localedef's input name for locale NAME: without the code set, but with the
# modifier (en_US.UTF-8 → en_US, sr_RS.UTF-8@latin → sr_RS@latin).
locale_input() {
  local name=$1 modifier=""
  if [[ $name == *@* ]]; then modifier="@${name#*@}"; name=${name%%@*}; fi
  printf '%s%s' "${name%%.*}" "$modifier"
}

# Print the project image's Dockerfile, generated from the plan. The order: installs from the
# vendors (the biggest and most stable, so projects with the same toolchain share layers), copies
# and links, apt packages, locales, certificates; then, if the plan has items built in a build
# stage (lib/recipes.sh), that stage, and last the single files (built ones and copies).
project_dockerfile() {
  local packages=() certs=() locales=() copies=() links=() builds=() files=() line name path flags number=0
  local kind group method value stage=""
  local -A created=()
  mapfile -t copies < <(plan_copies)
  mapfile -t links < <(plan_items link link)
  mapfile -t certs < <(plan_items cert copy)
  mapfile -t locales < <(plan_items locale generate)
  mapfile -t builds < <(plan_lines "" build)
  mapfile -t files < <(plan_lines tool copy)
  while IFS= read -r name; do
    packages+=("$name=$(plan_value package "$name")")
  done < <(plan_items package apt)

  printf '# Generated by go-yolo from .go-yolo/plan; edit .go-yolo/config instead.\n'
  if ((${#builds[@]})); then stage=" AS project"; fi
  printf 'FROM %s%s\n' "$BASE_TAG" "$stage"
  dockerfile_downloads created
  if ((${#copies[@]})); then
    printf '\n# directories from the host, at the same paths and with the same owners\n'
    for line in "${copies[@]}"; do
      IFS=$'\t' read -r path flags <<<"$line"
      number=$((number + 1))
      if has_flag "$flags" user-owned; then
        user_parents "$path" created
        printf 'COPY --from=copy%s --chown=%s:%s ["/", %s]\n' "$number" "$HOST_UID" "$HOST_GID" "$(json_string "$path/")"
      else
        printf 'COPY --from=copy%s ["/", %s]\n' "$number" "$(json_string "$path/")"
      fi
    done
  fi
  for name in "${links[@]}"; do
    printf 'RUN mkdir -p %q && ln -sfn %q %q\n' "${name%/*}" "$(plan_value link "$name")" "$name"
  done
  if ((${#packages[@]})); then
    # Never --allow-downgrades: the plan only asks for versions the image can get without one.
    printf '\n# apt packages, at the host'"'"'s versions where possible (see .go-yolo/plan)\n'
    printf 'RUN apt-get update \\\n && apt-get install -y --no-install-recommends \\\n'
    printf '      %s \\\n' "${packages[@]}"
    printf ' && rm -rf /var/lib/apt/lists/*\n'
  fi
  if ((${#locales[@]})); then
    printf '\n# the host'"'"'s locales (as locale-gen would make them)\n'
    printf 'RUN true'
    for name in "${locales[@]}"; do
      printf ' \\\n && localedef -i %s -c -f %s -A /usr/share/locale/locale.alias %s' \
        "$(locale_input "$name")" "$(plan_value locale "$name")" "$name"
    done
    printf '\n'
  fi
  if ((${#certs[@]})); then
    printf '\n# CA certificates trusted by the host, at the same paths\n'
    printf 'COPY files/ /\n'
    printf 'RUN update-ca-certificates\n'
  fi
  if ((${#builds[@]})); then dockerfile_build_stage "${builds[@]}"; fi
  if ((${#builds[@]} + ${#files[@]})); then
    printf '\n# built above, or single files copied from the host, at the host'"'"'s paths\n'
    number=0
    for line in "${builds[@]}"; do
      IFS=$'\t' read -r kind group method name value flags <<<"$line"
      number=$((number + 1))
      if [[ $kind == tool ]]; then
        dockerfile_copy_file "$flags" "/tmp/go-yolo-build/$number/${name##*/}" "$name" created --from=build
      else
        dockerfile_copy_file "$flags" "$name/" "$name/" created --from=build
      fi
    done
    number=0
    for line in "${files[@]}"; do
      IFS=$'\t' read -r kind group method name value flags <<<"$line"
      number=$((number + 1))
      dockerfile_copy_file "$flags" "files-copied/$number" "$name" created
    done
  fi
}

# dockerfile_downloads CREATED — the plan's download items: each archive installed by
# scripts/install-archive.sh, as the owner the host has (user-owned ones after USER). The empty
# files the host has in the directory (download_empty_files) come as files-empty/N.
dockerfile_downloads() {
  local kind group method name value flags url algorithm sums files first=1 number=0 empty
  while IFS=$'\t' read -r kind group method name value flags; do
    if ((first)); then
      printf '\n# installed from their vendors, checked against the vendor'"'"'s checksum and the host'"'"'s files\n'
      first=0
    fi
    number=$((number + 1))
    IFS=$'\t' read -r url algorithm sums files <<<"$(recipe "$kind" "$name")"
    empty=""
    if [[ -n $(download_empty_files "$name") ]]; then
      empty="/tmp/go-yolo-empty-$number"
      printf 'COPY files-empty/%s %s\n' "$number" "$empty"
    fi
    if has_flag "$flags" user-owned; then
      user_parents "$name" "$1"
      printf 'RUN install -d -o %s -g %s -m %s %q\n' "$HOST_UID" "$HOST_GID" "$(stat -c %a -- "$name")" "$name"
      printf 'USER %s:%s\n' "$HOST_UID" "$HOST_GID"
    fi
    printf 'RUN /opt/go-yolo/scripts/install-archive.sh %s' "$(shell_words "$url" "$algorithm" "$sums" "$name" "${value##*, }")"
    if [[ -n $empty ]]; then printf ' --empty %s' "$empty"; fi
    # shellcheck disable=SC2086 # the recipe's files, one word each
    printf ' -- %s\n' "$(shell_words $files)"
    if has_flag "$flags" user-owned; then printf 'USER root\n'; fi
  done < <(plan_lines "" download)
}

# download_empty_files DIR — the empty files in host directory DIR, relative to it, one per line:
# the archive may lack them (Gradle's provisioned.ok) or have something else there (Gradle unpacks
# a JDK's license links as empty files), so the image gets them as the host has them.
download_empty_files() {
  find "$1" -mindepth 1 -type f -empty -printf '%P\n' 2>/dev/null | LC_ALL=C sort
}

# dockerfile_build_stage LINE... — the build stage: each item's recipe command run as you, with
# your HOME, writing its file into /tmp/go-yolo-build/N, which is then checked against the host's.
dockerfile_build_stage() {
  local line kind group method name value flags number=0 dirs=()
  for line in "$@"; do
    IFS=$'\t' read -r kind group method name value flags <<<"$line"
    if [[ $kind != tool ]]; then dirs+=("$name"); fi
  done
  printf '\n# a build stage: tools built at the host'"'"'s paths (they end up in the binaries) and\n'
  printf '# checked against the host'"'"'s, directories (an SDK) installed and checked; only those go into\n'
  printf '# the image, not what was downloaded for them\n'
  printf 'FROM project AS build\n'
  printf 'RUN install -d -o %s -g %s %s\n' "$HOST_UID" "$HOST_GID" "$(shell_words "$HOME_DIR" /tmp/go-yolo-build "${dirs[@]}")"
  printf 'USER %s:%s\n' "$HOST_UID" "$HOST_GID"
  printf 'ENV HOME=%s\n' "$(json_string "$HOME_DIR")"
  for line in "$@"; do
    IFS=$'\t' read -r kind group method name value flags <<<"$line"
    number=$((number + 1))
    if [[ $kind != tool ]]; then
      printf 'RUN %s\n' "$(recipe "$kind" "$name")"
      continue
    fi
    printf 'RUN OUT=/tmp/go-yolo-build/%s && mkdir -p "$OUT" \\\n && %s \\\n' "$number" "$(recipe "$kind" "$name")"
    printf ' && /opt/go-yolo/scripts/verify.sh "$OUT" %s\n' "$(shell_words "${value##*, }" "${name##*/}")"
  done
  printf '\nFROM project\n'
}

# dockerfile_copy_file FLAGS SOURCE DEST CREATED [--from=STAGE] — COPY one file to DEST, owned as on
# the host (FLAGS: user-owned), its parent directories under $HOME made first.
dockerfile_copy_file() {
  local flags=$1 source=$2 dest=$3 made_name=$4 from=${5:-} chown=""
  if has_flag "$flags" user-owned; then
    user_parents "$dest" "$made_name"
    chown=" --chown=$HOST_UID:$HOST_GID"
  fi
  printf 'COPY%s%s [%s, %s]\n' "${from:+ $from}" "$chown" "$(json_string "$source")" "$(json_string "$dest")"
}

# Write .go-yolo/build/: the Dockerfile and the files it copies (the build context): the
# certificates in files/, single copied files as files-copied/N, the empty files of the Nth
# download as files-empty/N.
write_build_dir() {
  local dir="$PROJECT_DIR/.go-yolo/build" path number=0
  rm -rf -- "$dir"
  mkdir -p -- "$dir/files" "$dir/files-copied" "$dir/files-empty"
  project_dockerfile >"$dir/Dockerfile"
  while IFS= read -r path; do
    mkdir -p -- "$dir/files${path%/*}"
    cp -- "$path" "$dir/files$path"
  done < <(plan_items cert copy)
  while IFS= read -r path; do
    number=$((number + 1))
    cp -p -- "$path" "$dir/files-copied/$number"
  done < <(plan_items tool copy)
  number=0
  while IFS= read -r path; do
    number=$((number + 1))
    download_empty_files "$path" >"$dir/files-empty/$number"
  done < <(plan_lines "" download | cut -f4)
}

# Build the project image unless it exists already (or --rebuild was given).
ensure_project_image() {
  if ((!REBUILD)) && docker image inspect "$IMAGE" >/dev/null 2>&1; then return 0; fi

  local dir="$PROJECT_DIR/.go-yolo/build"
  write_build_dir
  local build=(docker build --label "go-yolo.project=$PROJECT_DIR" --label "go-yolo.plan=$PLAN_HASH"
    --label "go-yolo.confirmed=$PLAN_CONFIRMED" -t "$IMAGE" -f "$dir/Dockerfile")
  local line path flags number=0
  # Each copied host directory is a named build context (copy1, copy2, ...), read in place.
  while IFS= read -r line; do
    IFS=$'\t' read -r path flags <<<"$line"
    number=$((number + 1))
    build+=(--build-context "copy$number=$path")
  done < <(plan_copies)
  if ((REBUILD)); then build+=(--no-cache); fi
  build+=("$dir")
  note "building $IMAGE (Dockerfile: .go-yolo/build/Dockerfile)"
  if ! "${build[@]}" >&2; then
    die "building the project image failed. If apt couldn't install a package at the host's version, update the host (apt upgrade) or leave the package out (go-yolo.sh --setup). If an installed item isn't the host's, or its download failed, make it a copy: its mode \"copy\" in .go-yolo/config"
  fi
}
