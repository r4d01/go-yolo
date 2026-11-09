# shellcheck shell=bash
# The helpers catalogs (catalogs/*.sh) use to add items to the plan, for the items the setup
# picked. Each checks the safety rules and what the plan already has.
# (Apt packages: plan_packages in lib/apt.sh.)

# plan_cert PATH — a CA certificate to add to the image's trust store, at the same path.
plan_cert() {
  local path=$1
  plan_add cert host copy "$path" "$(sha256sum <"$path" | cut -c1-8)"
}

# plan_copy KIND GROUP DIR VALUE FLAGS — copy host directory DIR into the image at the same path,
# owned as on the host: by root, or by you (then `go install` and the like work there too, but
# their results don't outlive the container). This is the fallback for items no recipe installs
# (lib/recipes.sh). KIND is what it is (toolchain, tools); VALUE shows a change (a version, or
# dir_fingerprint). A symlinked DIR is copied at its real path, plus a link item for the symlink.
# FLAGS: why it is a copy (no-recipe, copy-picked, ...), and on-path to put DIR/bin on PATH.
plan_copy() {
  local kind=$1 group=$2 dir=$3 value=$4 flags=$5
  install_target "$kind" "$group" "$dir" || return 0
  plan_add "$kind" "$group" copy "$TARGET" "$value" "$(owner_flags "$TARGET" "$flags")"
}

# first_file PATH... — print the first PATH that is a file (e.g. of a glob); fail if none is.
first_file() {
  local path
  for path in "$@"; do
    if [[ -f $path ]]; then printf '%s' "$path"; return 0; fi
  done
  return 1
}

# dir_fingerprint DIR — "N files, HASH": changes when a file is added, removed or changed.
dir_fingerprint() {
  local count hash
  count="$(find "$1" -type f | wc -l)"
  hash="$(find "$1" -printf '%P %s %T@\n' | LC_ALL=C sort | sha256sum | cut -c1-8)"
  printf '%s files, %s' "$count" "$hash"
}

# plan_mount GROUP PATH [FLAGS] — mount host file or directory PATH read-only at the same path.
plan_mount() {
  local group=$1 path=$2 flags=${3:--} value=-
  if plan_has mount "$path"; then return 0; fi
  validate_mount_path "$path"
  if [[ -f $path ]]; then
    value="$(sha256sum <"$path" | cut -c1-8)"
    # Repository credentials in settings.xml, tokens in gradle.properties or .npmrc, ...
    if grep -qiE 'password|passwd|secret|token|credential|_auth' -- "$path" 2>/dev/null; then
      flags="$(add_flag "$flags" may-hold-secrets)"
    fi
  fi
  plan_add mount "$group" ro "$path" "$value" "$flags"
}

# plan_cache GROUP PATH NAME — the project's cache NAME: a Docker volume (see cache_volume),
# mounted at the host's cache path PATH. It starts empty; the host's own cache at PATH is never
# read or written.
plan_cache() {
  local group=$1 path=$2 name=$3
  validate_mount_path "$path"
  plan_add cache "$group" volume "$path" "$name"
}

# plan_tool GROUP NAME [MODE [RECIPE]] — the host's install of command NAME: its apt packages, or
# its install directory (the parent of the bin/ that holds NAME), put on PATH: installed by
# function RECIPE (called with the directory; it fails if it doesn't know the install), else (or
# with MODE copy) copied. An SDKMAN-style "current" symlink is kept as a link.
plan_tool() {
  local group=$1 name=$2 mode=${3:-image} recipe=${4:-} bin real home owners
  if ! bin="$(command -v -- "$name" 2>/dev/null)" || [[ $bin != /* ]]; then
    plan_add tools "$group" skip "$name" - not-on-path
    return 0
  fi
  real="$(readlink -f -- "$bin")"
  if [[ $mode != copy ]] && owners="$(apt_owners "$real")"; then
    # shellcheck disable=SC2086 # one word per package
    plan_packages "$group" $owners
    return 0
  fi
  # The install directory is the real one (/opt/kotlin for /opt/kotlin/bin/kotlin), unless the
  # path on PATH goes through a link to it, like SDKMAN's .../gradle/current/bin/gradle.
  home=${real%/bin/*}
  if [[ $bin == */bin/* && $(realpath -m -- "${bin%/bin/*}") == "$home" ]]; then
    home=${bin%/bin/*}
  fi
  if [[ $home == "$real" ]] || is_system_dir "$home"; then
    plan_add tools "$group" skip "$name" - not-in-bin-dir
    return 0
  fi
  if [[ $mode == copy ]]; then
    plan_copy toolchain "$group" "$home" "$(basename -- "$(realpath -- "$home")")" on-path,copy-picked
  elif [[ -z $recipe ]] || ! "$recipe" "$home"; then
    plan_copy toolchain "$group" "$home" "$(basename -- "$(realpath -- "$home")")" on-path,no-recipe
  fi
}

# plan_domain GROUP HOST — allow HOST with --net allowlist.
plan_domain() {
  if plan_has domain "$2"; then return 0; fi
  plan_add domain "$1" allow "$2"
}

# plan_locale NAME — generate locale NAME (e.g. en_US.UTF-8) in the image. Its character map
# comes from the host's list of supported locales; the `locales` package must be in the plan.
plan_locale() {
  local name=$1 charmap
  if ! plan_items package apt | grep -qxF locales; then
    plan_add locale host skip "$name" - no-locales-package
  elif charmap="$(locale_charmap "$name")"; then
    plan_add locale host generate "$name" "$charmap"
  else
    plan_add locale host skip "$name" - unsupported-locale
  fi
}

# locale_charmap NAME — print the character map of locale NAME from the host's list of supported
# locales (lines like "en_US.UTF-8 UTF-8"). Names are compared like glibc does: case and "-"
# in the code set don't matter, so en_US.utf8 finds en_US.UTF-8.
locale_charmap() {
  awk -v want="$1" '
    function normal(name) { name = tolower(name); gsub("-", "", name); return name }
    normal($1) == normal(want) { print $2; found = 1; exit }
    END { exit !found }' "${GOYOLO_LOCALES_SUPPORTED:-/usr/share/i18n/SUPPORTED}" 2>/dev/null
}

# True if an env variable looks like it holds a secret: by its name, or a URL with a password.
looks_secret() {
  local name=${1^^} value=$2
  case $name in
    *TOKEN*|*SECRET*|*PASSWORD*|*PASSWD*|*KEY*|*CREDENTIAL*|*AUTH*) return 0 ;;
  esac
  [[ $value =~ ://[^/@]*:[^/@]*@ ]]
}

# plan_env GROUP NAME [VALUE] — pass host variable NAME (one the setup picked) into the container.
# With VALUE (a value go-yolo works out itself, e.g. the time zone), NAME=VALUE is passed
# instead. The values of variables that look like secrets are never shown or stored, only a hash,
# so a change is still noticed.
plan_env() {
  local group=$1 name=$2 value
  if plan_has env "$name"; then return 0; fi
  if (($# >= 3)); then
    plan_add env "$group" env "$name" "${3:--}" derived
    return 0
  elif [[ ! -v $name ]]; then
    plan_add env "$group" skip "$name" - not-set
    return 0
  fi
  value=${!name}

  if [[ -z $value ]]; then
    plan_add env "$group" env "$name" - empty
  elif looks_secret "$name" "$value" || [[ $value == *[$'\t\n']* ]]; then
    plan_add env "$group" env "$name" "sha256:$(printf '%s' "$value" | sha256sum | cut -c1-12)" hidden
  else
    plan_add env "$group" env "$name" "$value"
  fi
}
