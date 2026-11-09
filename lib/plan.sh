# shellcheck shell=bash
# The plan: everything go-yolo puts into the project image or passes to the container, and
# how. You confirm it before anything is built; later runs show only what changed.
#
# A plan is a sorted list of lines with six tab-separated fields:
#
#   kind      group  method  name                      value          flags
#   base      host   image   go-yolo-base:debian-trixie-3f2a91c0  -     -
#   toolchain go     copy    /opt/go/1.27.0            go1.27.0       -
#   tools     go     copy    /home/me/go/bin           2 files, 1a2b3c4d  user-owned
#   link      java   link    /home/me/.sdkman/candidates/java/current  /home/me/.sdkman/candidates/java/21.0.5-tem  -
#   package   host   apt     libsqlite3-dev            3.46.1-2       -
#   package  extra  apt     protobuf-compiler          3.21.12-11     not-on-host
#   parity   host   check   zlib1g                     1:1.3-1+deb13u1  host-behind=1:1.3-1
#   cert     host   copy    /usr/local/share/ca-certificates/corp.crt  1a2b3c4d  -
#   locale   host   generate  en_US.UTF-8              UTF-8          -
#   env      host   env     TZ                         Europe/Prague  -
#   env      extra  env     GITHUB_TOKEN               sha256:5e6f..  hidden
#   env      host   skip    HTTPS_PROXY                -              secret
#   mount    go     ro      /home/me/.config/go/env    1a2b3c4d       -
#   cache    go     volume  /home/me/go/pkg/mod        go-mod         -
#   domain   go     allow   proxy.golang.org           -              -
#
#   kind    built into the image: base, toolchain and tools (host directories copied at the
#           same path), link, package, cert, locale;
#           passed when the container starts: env; mount (a host file or directory, read-only, at
#           the same path); cache (the project's Docker volume <value>, at the host's cache
#           path); domain (allowed
#           with --net allowlist);
#           parity: a base image package whose version differs from the host's (a warning)
#   group   who asks for it: host (every project), extra (.go-yolo/config); later go, rust, ...
#   method  how: image, apt, copy, env; or skip: shown so you see it, but left out
#   value   a version, a content hash or an env value ("-" when there is none)
#   flags   comma-separated notes, explained by plan_note ("-" when there are none)
#
# The packs (packs/*.sh) fill the plan through the plan_* helpers below.
#
# Sets: PLAN            the resolved plan lines, sorted
#       PLAN_HASH       hash of the lines that go into the image (8 hex digits); part of the tag
#       PLAN_CONFIRMED  when the plan in .go-yolo/plan was confirmed ("" if never)

PLAN=()
PLAN_HASH=""
PLAN_CONFIRMED=""
CONFIRMED_PLAN=()

plan_file() { printf '%s/.go-yolo/plan' "$PROJECT_DIR"; }

# ---------------------------------------------------------------------------
# Building the plan
# ---------------------------------------------------------------------------

# plan_add KIND GROUP METHOD NAME [VALUE] [FLAGS] — add one line ("-" for a missing value).
plan_add() {
  local field
  for field in "$@"; do
    [[ $field != *[$'\t\n']* ]] || die "internal error: plan field with a tab or newline: $field"
  done
  PLAN+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"${5:--}"$'\t'"${6:--}")
}

# plan_has KIND NAME — true if the plan already has an item of KIND called NAME.
plan_has() {
  local line kind group method name rest
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name rest <<<"$line"
    if [[ $kind == "$1" && $name == "$2" ]]; then return 0; fi
  done
  return 1
}

# apt_versions NAME... — for each apt package print five tab-separated fields:
#   name, installed version, candidate version, installed_ok, candidate_ok
# "(none)" stands for no version; *_ok is 1 if that version is in the distro archive, the
# only place the image can install from (not third-party repositories, not backports).
# Names apt doesn't know are not printed.
apt_versions() {
  # apt-cache policy prints, per package:
  #   libsqlite3-dev:
  #     Installed: 3.46.1-2
  #     Candidate: 3.46.1-3
  #     Version table:
  #        3.46.1-3 500
  #           500 http://deb.debian.org/debian trixie-security/main amd64 Packages
  #    *** 3.46.1-2 500
  #           500 http://deb.debian.org/debian trixie/main amd64 Packages
  #           100 /var/lib/dpkg/status
  # A version is in the distro archive if one of its sources is this release, its -updates
  # or its -security suite, in a distro component (main, contrib, ..., universe).
  apt-cache policy -- "$@" 2>/dev/null | awk -v codename="$HOST_CODENAME" '
    function flush() {
      if (name != "") print name "\t" installed "\t" candidate "\t" (installed in ok) + 0 "\t" (candidate in ok) + 0
      name = ""
      split("", ok)
    }
    /^[^ ].*:$/ { flush(); name = substr($0, 1, length($0) - 1); installed = candidate = "(none)"; next }
    $1 == "Installed:" { installed = $2; next }
    $1 == "Candidate:" { candidate = $2; next }
    /^ \*\*\* / { version = $2; next }
    /^     [^ ]/ { version = $1; next }
    $2 ~ /^[a-z]+:\/\// {
      suite = "^" codename "(-updates|-security)?/(main|contrib|non-free|non-free-firmware|restricted|universe|multiverse)$"
      if ($3 ~ suite) ok[version] = 1
    }
    END { flush() }'
}

# plan_packages GROUP NAME... — apt packages, at the host's version where possible.
#
# The image never downgrades a package. So if the host is behind the archive, the image gets
# the archive's newer version, with a warning in the plan: apt upgrade the host to match.
plan_packages() {
  local group=$1 name installed candidate installed_ok candidate_ok
  shift
  local wanted=() resolved=()
  for name in "$@"; do
    if plan_has package "$name"; then continue; fi
    if config_has exclude package "$name"; then
      plan_add package "$group" skip "$name" - excluded
      continue
    fi
    wanted+=("$name")
  done
  ((${#wanted[@]})) || return 0

  while IFS=$'\t' read -r name installed candidate installed_ok candidate_ok; do
    resolved+=("$name")
    if [[ $installed != "(none)" && $installed == "$candidate" ]] && ((installed_ok)); then
      plan_add package "$group" apt "$name" "$installed"
    elif [[ $installed != "(none)" ]] && ((candidate_ok)) \
      && dpkg --compare-versions "$installed" lt "$candidate"; then
      plan_add package "$group" apt "$name" "$candidate" "host-older=$installed"
    elif [[ $installed == "(none)" ]] && ((candidate_ok)); then
      plan_add package "$group" apt "$name" "$candidate" not-on-host
    elif [[ $installed != "(none)" ]]; then
      plan_add package "$group" skip "$name" "$installed" not-in-archive
    else
      plan_add package "$group" skip "$name" "$candidate" not-in-archive
    fi
  done < <(apt_versions "${wanted[@]}")

  for name in "${wanted[@]}"; do
    if [[ " ${resolved[*]} " != *" $name "* ]]; then plan_add package "$group" skip "$name" - not-found; fi
  done
}

# plan_cert PATH — a CA certificate to add to the image's trust store, at the same path.
plan_cert() {
  local path=$1
  if config_has exclude cert "$path"; then
    plan_add cert host skip "$path" - excluded
    return 0
  fi
  plan_add cert host copy "$path" "$(sha256sum <"$path" | cut -c1-8)"
}

# plan_copy KIND GROUP DIR VALUE [FLAGS] — copy host directory DIR into the image at the same path,
# owned as on the host: by root, or by you (then `go install` and the like work there too, but
# their results don't outlive the container). KIND is what it is (toolchain, tools); VALUE
# shows a change (a version, or dir_fingerprint). A symlinked DIR is copied at its real path,
# plus a link item for the symlink. FLAGS: on-path puts DIR/bin on PATH (for a toolchain).
plan_copy() {
  local kind=$1 group=$2 dir=$3 value=$4 extra=${5:-} real flags=-
  real="$(realpath -- "$dir")"
  if is_system_dir "$real"; then
    die "refusing to copy $dir into the image: it is a system directory, your home directory or one of its parents"
  fi
  if is_under "$PROJECT_DIR" "$real"; then
    die "refusing to copy $dir into the image: it contains the project"
  fi
  if config_has exclude "$kind" "$real"; then
    plan_add "$kind" "$group" skip "$real" "$value" excluded
    return 0
  fi
  if plan_has "$kind" "$real"; then return 0; fi
  if [[ $(stat -c %u -- "$real") == "$HOST_UID" ]]; then flags=user-owned; fi
  if [[ -n $extra && $extra != - ]]; then
    if [[ $flags == - ]]; then flags=$extra; else flags+=",$extra"; fi
  fi
  plan_add "$kind" "$group" copy "$real" "$value" "$flags"
  if [[ $real != "$(realpath -ms -- "$dir")" ]]; then plan_add link "$group" link "$dir" "$real"; fi
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
  if config_has exclude mount "$path"; then
    plan_add mount "$group" skip "$path" - excluded
    return 0
  fi
  validate_mount_path "$path"
  if [[ -f $path ]]; then
    value="$(sha256sum <"$path" | cut -c1-8)"
    # Repository credentials in settings.xml, tokens in gradle.properties or .npmrc, ...
    if grep -qiE 'password|passwd|secret|token|credential|_auth' -- "$path" 2>/dev/null; then
      if [[ $flags == - ]]; then flags=may-hold-secrets; else flags+=",may-hold-secrets"; fi
    fi
  fi
  plan_add mount "$group" ro "$path" "$value" "$flags"
}

# plan_cache GROUP PATH NAME — the project's cache NAME: a Docker volume (see cache_volume),
# mounted at the host's cache path PATH. It starts empty; the host's own cache at PATH is never
# read or written.
plan_cache() {
  local group=$1 path=$2 name=$3
  if config_has exclude cache "$path"; then
    plan_add cache "$group" skip "$path" "$name" excluded
    return 0
  fi
  validate_mount_path "$path"
  plan_add cache "$group" volume "$path" "$name"
}

# apt_owners PATH — print the apt packages that own PATH on the host, one per line (without a
# ":amd64"-style suffix); fail if none does.
apt_owners() {
  local owners
  owners="$(dpkg -S -- "$1" 2>/dev/null | head -n 1)" || return 1
  [[ -n $owners ]] || return 1
  owners=${owners%%: *}            # "openjdk-21-jre:amd64, openjdk-21-jre-headless:amd64"
  owners=${owners//, /$'\n'}
  sed 's/:[a-z0-9]*$//' <<<"$owners"
}

# plan_tool GROUP NAME — the host's install of command NAME: its apt packages, or its install
# directory (the parent of the bin/ that holds NAME), copied and put on PATH. An SDKMAN-style
# "current" symlink is kept as a link.
plan_tool() {
  local group=$1 name=$2 bin real home owners
  if ! bin="$(command -v -- "$name" 2>/dev/null)" || [[ $bin != /* ]]; then
    plan_add tools "$group" skip "$name" - not-on-path
    return 0
  fi
  real="$(readlink -f -- "$bin")"
  if owners="$(apt_owners "$real")"; then
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
  plan_copy toolchain "$group" "$home" "$(basename -- "$(realpath -- "$home")")" on-path
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
  if config_has exclude locale "$name"; then
    plan_add locale host skip "$name" - excluded
  elif ! plan_items package apt | grep -qxF locales; then
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

# plan_env GROUP NAME [VALUE] — pass host variable NAME into the container. With VALUE (a value
# go-yolo works out itself, e.g. the time zone), NAME=VALUE is passed instead. Looks-secret variables
# are only passed when .go-yolo/config asks for them (extra env NAME); their values are never
# shown or stored, only a hash, so a change is still noticed.
plan_env() {
  local group=$1 name=$2 value
  if plan_has env "$name"; then return 0; fi
  if config_has exclude env "$name"; then
    plan_add env "$group" skip "$name" - excluded
    return 0
  fi
  if (($# >= 3)); then
    plan_add env "$group" env "$name" "${3:--}" derived
    return 0
  elif [[ ! -v $name ]]; then
    if [[ $group == extra ]]; then plan_add env "$group" skip "$name" - not-set; fi
    return 0
  fi
  value=${!name}

  if looks_secret "$name" "$value" && ! config_has extra env "$name"; then
    plan_add env "$group" skip "$name" - secret
  elif [[ -z $value ]]; then
    plan_add env "$group" env "$name" - empty
  elif looks_secret "$name" "$value" || [[ $value == *[$'\t\n']* ]]; then
    plan_add env "$group" env "$name" "sha256:$(printf '%s' "$value" | sha256sum | cut -c1-12)" hidden
  else
    plan_add env "$group" env "$name" "$value"
  fi
}

# Sort PLAN (base, packages, certs, env; then by name) and compute PLAN_HASH.
plan_finish() {
  local line kind rank
  local ranked=()
  for line in "${PLAN[@]}"; do
    kind=${line%%$'\t'*}
    case $kind in
      base) rank=10 ;; toolchain) rank=11 ;; tools) rank=12 ;; link) rank=13 ;; package) rank=14 ;;
      parity) rank=15 ;; cert) rank=16 ;; locale) rank=17 ;;
      mount) rank=20 ;; cache) rank=21 ;; domain) rank=23 ;; *) rank=29 ;;
    esac
    ranked+=("$rank"$'\t'"$line")
  done
  mapfile -t PLAN < <(printf '%s\n' "${ranked[@]}" | LC_ALL=C sort -t $'\t' -k1,1n -k5,5 | cut -f2-)
  PLAN_HASH="$(plan_build_hash "${PLAN[@]}")"
}

# plan_build_hash LINE... — hash of the lines that go into the image (8 hex digits).
plan_build_hash() {
  local line build_lines=""
  for line in "$@"; do
    if is_build_line "$line"; then build_lines+="$line"$'\n'; fi
  done
  printf '%s' "$build_lines" | sha256sum | cut -c1-8
}

# confirmed_plan_hash DIR — the build hash of DIR's confirmed plan; nothing if it has none.
confirmed_plan_hash() {
  local file="$1/.go-yolo/plan" line lines=()
  [[ -f $file ]] || return 0
  while IFS= read -r line; do
    if [[ -n $line && $line != '#'* ]]; then lines+=("$line"); fi
  done <"$file"
  plan_build_hash "${lines[@]}"
}

# True if LINE goes into the image (as opposed to runtime settings and skipped items).
is_build_line() {
  local kind group method rest
  IFS=$'\t' read -r kind group method rest <<<"$1"
  [[ $method != skip ]] && case $kind in base|toolchain|tools|link|package|cert|locale) true ;; *) false ;; esac
}

# Load .go-yolo/config and let every pack add its items.
resolve_plan() {
  local pack
  load_config
  PLAN=()
  for pack in "${PACKS[@]}"; do
    if "${pack}_detect"; then "${pack}_resolve"; fi
  done
  plan_finish
}

# docker run -e arguments for the plan's env items: NAME=VALUE for values go-yolo works out
# itself, otherwise NAME alone, so docker takes the value from the environment (and a secret
# never appears on a command line).
plan_env_args() {
  local line kind group method name value flags
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name value flags <<<"$line"
    [[ $kind == env && $method == env ]] || continue
    if [[ $flags == derived ]]; then
      printf '%s\n' -e "$name=${value#-}"
    else
      printf '%s\n' -e "$name"
    fi
  done
}

# plan_items KIND [METHOD] — print the names of the plan's KIND items (with that METHOD).
plan_items() {
  local line kind group method name rest
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name rest <<<"$line"
    if [[ $kind == "$1" && ( -z ${2:-} || $method == "$2" ) ]]; then printf '%s\n' "$name"; fi
  done
}

# plan_value KIND NAME — print the value of the plan's KIND item called NAME.
plan_value() {
  local line kind group method name value rest
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name value rest <<<"$line"
    if [[ $kind == "$1" && $name == "$2" ]]; then printf '%s' "$value"; return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Showing the plan
# ---------------------------------------------------------------------------

# plan_note FLAG NAME — explain one flag in words. Warnings start with "⚠".
plan_note() {
  case $1 in
    excluded) printf 'excluded in .go-yolo/config' ;;
    secret) printf 'not passed: looks like a secret (to pass it: extra env %s)' "$2" ;;
    hidden) printf 'value not shown' ;;
    derived) printf 'set by go-yolo' ;;
    empty) printf 'empty value' ;;
    not-set) printf 'not passed: not set on the host' ;;
    host-behind=*) printf "⚠ the base image has this newer version, the host has %s (apt upgrade the host to match)" "${1#host-behind=}" ;;
    host-ahead=*) printf "⚠ the base image has this older version, the host has %s (go-yolo.sh --rebuild updates the base image)" "${1#host-ahead=}" ;;
    host-older=*) printf "⚠ the host has %s, an older version: the image gets the archive's version (apt upgrade the host to match)" "${1#host-older=}" ;;
    not-on-host) printf '⚠ not installed on the host: a build that needs it works here but fails on the host' ;;
    not-in-archive) printf "⚠ not installed: the host's version isn't in the %s archive (third-party repository, or apt upgrade the host)" "$HOST_ID" ;;
    not-found) printf '⚠ no such apt package' ;;
    user-owned) printf 'owned by you, as on the host' ;;
    on-path) printf 'first on PATH' ;;
    may-hold-secrets) printf '⚠ may hold credentials: the agent can read it' ;;
    not-on-path) printf "⚠ not on the host's PATH: neither side has it" ;;
    not-in-bin-dir) printf "⚠ not copied: it isn't installed as <dir>/bin/<name>" ;;
    outside-repo) printf '⚠ outside the repository: read-only in the container' ;;
    no-locales-package) printf "⚠ not generated: the locales package isn't in the plan" ;;
    unsupported-locale) printf "⚠ not generated: not in the host's list of supported locales" ;;
    *) printf '%s' "$1" ;;
  esac
}

# plan_row MARK LINE [CHANGE] — print one plan line for people: "  + package  zlib1g-dev=1.3-1  note".
# CHANGE says what the item was before (see plan_change).
plan_row() {
  local mark=$1 change=${3:-} kind group method name value flags text note notes="" color="" flag
  local flag_list=()
  IFS=$'\t' read -r kind group method name value flags <<<"$2"
  case $kind in
    package|parity) text="$name${value:+=$value}"; text=${text%=-} ;;
    toolchain|tools) text="$name ($value)" ;;
    link) text="$name → $value" ;;
    cache) text="$name (project volume $value)" ;;
    mount) text="$name (read-only)" ;;
    env) if [[ $value == - || $value == sha256:* ]]; then text=$name; else text="$name=$value"; fi ;;
    *) text=$name ;;
  esac
  if [[ $group != host ]]; then text+=" [$group]"; fi

  if [[ $flags != - ]]; then
    IFS=, read -ra flag_list <<<"$flags"
    for flag in "${flag_list[@]}"; do
      note="$(plan_note "$flag" "$name")"
      notes+="${notes:+; }$note"
    done
  fi
  if [[ -n $change ]]; then notes+="${notes:+; }$change"; fi
  if [[ $mark == - ]]; then notes=""; fi  # a removed item's notes no longer matter

  case $mark in
    +) color=green ;;
    -) color=red ;;
    \~) color=yellow ;;
  esac
  printf '  %s %-9s %s' "$(ui_paint "$color" "$mark")" "$kind" "$(if [[ $method == skip ]]; then ui_paint dim "$text"; else printf '%s' "$text"; fi)" >&2
  if [[ -n $notes ]]; then
    if [[ $notes == *⚠* ]]; then printf '  %s' "$(ui_paint yellow "$notes")" >&2
    else printf '  %s' "$(ui_paint dim "$notes")" >&2; fi
  fi
  printf '\n' >&2
}

# True if a plan line has a flag whose note is a warning (⚠).
plan_has_warnings() {
  local line kind group method name value flags flag
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name value flags <<<"$line"
    [[ $flags != - ]] || continue
    for flag in ${flags//,/ }; do
      if [[ $(plan_note "$flag" "$name") == ⚠* ]]; then return 0; fi
    done
  done
  return 1
}

# Show the whole plan.
show_plan() {
  local line
  for line in "${PLAN[@]}"; do plan_row ' ' "$line"; done
}

# plan_change OLD_LINE NEW_LINE — what an item was before, in words ("" if only its notes changed).
plan_change() {
  local kind old_group old_method name old_value old_flags group method value flags
  IFS=$'\t' read -r kind old_group old_method name old_value old_flags <<<"$1"
  IFS=$'\t' read -r kind group method name value flags <<<"$2"
  if [[ $old_method == skip && $method != skip ]]; then printf 'was left out'
  elif [[ $old_method != skip && $method == skip ]]; then printf 'was included'
  elif [[ $old_value != "$value" && $old_value == sha256:* ]]; then printf 'value changed'
  elif [[ $old_value != "$value" ]]; then printf 'was %s' "$old_value"
  elif [[ $old_group != "$group" ]]; then printf 'was from %s' "$old_group"
  fi
}

# Show what changed between CONFIRMED_PLAN and PLAN: + added, - removed, ~ changed.
show_plan_diff() {
  local line key kind group method name value rest
  local -A old=() new=()
  for line in "${CONFIRMED_PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name rest <<<"$line"
    old[$kind$'\t'$name]=$line
  done
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name rest <<<"$line"
    key=$kind$'\t'$name
    new[$key]=$line
    if [[ -z ${old[$key]:-} ]]; then
      plan_row + "$line"
    elif [[ ${old[$key]} != "$line" ]]; then
      plan_row '~' "$line" "$(plan_change "${old[$key]}" "$line")"
    fi
  done
  for line in "${CONFIRMED_PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name rest <<<"$line"
    if [[ -z ${new[$kind$'\t'$name]:-} ]]; then plan_row - "$line"; fi
  done
}

# ---------------------------------------------------------------------------
# Confirming the plan
# ---------------------------------------------------------------------------

# Read .go-yolo/plan into CONFIRMED_PLAN and PLAN_CONFIRMED.
read_confirmed_plan() {
  local file line
  file="$(plan_file)"
  CONFIRMED_PLAN=()
  PLAN_CONFIRMED=""
  [[ -f $file ]] || return 0
  while IFS= read -r line; do
    case $line in
      '# confirmed: '*) PLAN_CONFIRMED=${line#'# confirmed: '} ;;
      '#'*|'') ;;
      *) CONFIRMED_PLAN+=("$line") ;;
    esac
  done <"$file"
}

save_plan() {
  local file
  file="$(plan_file)"
  PLAN_CONFIRMED="$(date '+%Y-%m-%d %H:%M')"
  {
    printf '# go-yolo plan for %s. Written by go-yolo: edit .go-yolo/config instead.\n' "$PROJECT_DIR"
    printf '# confirmed: %s\n' "$PLAN_CONFIRMED"
    printf '%s\n' "${PLAN[@]}"
  } >"$file"
}

# Open .go-yolo/config in $VISUAL or $EDITOR (vi), starting it with a short guide if new.
edit_config() {
  local file
  file="$(config_file)"
  if [[ ! -e $file ]]; then
    cat >"$file" <<'EOF'
# go-yolo settings for this project. One item per line:
#
#   extra    package  protobuf-compiler    also install this apt package
#   extra    env      GITHUB_TOKEN         also pass this host environment variable
#   exclude  package  libx11-dev           leave out an item the plan would include
#   exclude  cert     /usr/local/share/ca-certificates/old.crt
#   exclude  env      HTTPS_PROXY
EOF
  fi
  "${VISUAL:-${EDITOR:-vi}}" "$file" </dev/tty >/dev/tty
}

# Show the plan if it is new or changed, and ask before going on. Without a terminal an
# unconfirmed plan is never used (except with --yes); a dry run shows it and goes on.
confirm_plan() {
  local answer
  read_confirmed_plan
  while true; do
    if [[ "$(printf '%s\n' "${CONFIRMED_PLAN[@]}")" == "$(printf '%s\n' "${PLAN[@]}")" ]]; then
      return 0
    fi

    if ((${#CONFIRMED_PLAN[@]})); then
      note "the plan for this project changed since it was confirmed ($PLAN_CONFIRMED):"
      show_plan_diff
    else
      note "plan for $PROJECT_DIR (new; edit .go-yolo/config to change it):"
      show_plan
    fi

    if ((YES)); then save_plan; return 0; fi
    if ((DRY_RUN)); then note "dry run: the plan is not confirmed"; return 0; fi
    [[ -t 0 && -t 2 ]] \
      || die "the plan is new or changed; run go-yolo in a terminal to confirm it, or pass --yes"

    while true; do
      if plan_has_warnings; then warn "the plan has warnings (⚠); check them before you go on"; fi
      read -r -p "go-yolo: use this plan? [y]es [n]o [e]dit config [d]ockerfile: " answer
      case $answer in
        y|yes) save_plan; return 0 ;;
        n|no|'') note "aborted; nothing was built"; exit 1 ;;
        e|edit) edit_config; resolve_plan; break ;;
        d|dockerfile) project_dockerfile >&2 ;;
        *) note "y: build with this plan · n: stop · e: edit .go-yolo/config · d: show the Dockerfile" ;;
      esac
    done
  done
}
