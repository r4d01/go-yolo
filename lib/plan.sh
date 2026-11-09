# shellcheck shell=bash
# The plan: everything go-yolo puts into the project image or passes to the container, and
# how. You confirm it before anything is built; later runs show only what changed.
#
# A plan is a sorted list of lines with six tab-separated fields:
#
#   kind      group  method  name                      value          flags
#   base      host   image   go-yolo-base:debian-trixie-3f2a91c0  -     -
#   toolchain go     copy    /opt/go/1.27.0            go1.27.0       on-path
#   tools     go     copy    /home/me/go/bin           2 files, 1a2b3c4d  user-owned
#   link      java   link    /home/me/.sdkman/candidates/java/current  /home/me/.sdkman/candidates/java/21.0.5-tem  -
#   package   host   apt     libsqlite3-dev            3.46.1-2       -
#   package   extra  apt     protobuf-compiler         3.21.12-11     not-on-host
#   parity    host   check   zlib1g                    1:1.3-1+deb13u1  host-behind=1:1.3-1
#   cert      host   copy    /usr/local/share/ca-certificates/corp.crt  1a2b3c4d  -
#   locale    host   generate  en_US.UTF-8             UTF-8          -
#   mount     go     ro      /home/me/.config/go/env   1a2b3c4d       -
#   cache     go     volume  /home/me/go/pkg/mod       go-mod         -
#   domain    go     allow   proxy.golang.org          -              -
#   env       host   env     TZ                        Europe/Prague  derived
#   env       extra  env     GITHUB_TOKEN              sha256:5e6f..  hidden
#   env       host   skip    HTTPS_PROXY               -              secret
#
#   kind    what it is; lib/kinds.sh says which kinds go into the image and how each is shown
#   group   who asks for it: host (every project), extra (.go-yolo/config), go, java, ...
#   method  how: image, copy, link, apt, generate, check, ro, volume, allow, env; or skip: shown
#           so you see it, but left out
#   value   a version, a content hash, a cache name or an env value ("-" when there is none)
#   flags   comma-separated, declared in lib/kinds.sh: behaviour flags change what go-yolo does,
#           the rest only explain ("-" when there are none)
#
# The catalogs (catalogs/*.sh) fill the plan through the helpers in lib/items.sh and lib/apt.sh;
# lib/confirm.sh shows and confirms it.
#
# Sets: PLAN            the resolved plan lines, sorted
#       PLAN_HASH       hash of the lines that go into the image (8 hex digits); part of the tag
#       PLAN_CONFIRMED  when the plan in .go-yolo/plan was confirmed ("" if never)
#       CONFIRMED_PLAN  the lines of .go-yolo/plan

PLAN=()
PLAN_HASH=""
PLAN_CONFIRMED=""
CONFIRMED_PLAN=()

plan_file() { printf '%s/.go-yolo/plan' "$PROJECT_DIR"; }

# plan_add KIND GROUP METHOD NAME [VALUE] [FLAGS] — add one line ("-" for a missing value).
plan_add() {
  local field
  for field in "$@"; do
    [[ $field != *[$'\t\n']* ]] || die "internal error: plan field with a tab or newline: $field"
  done
  PLAN+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"${5:--}"$'\t'"${6:--}")
}

# plan_lines [KIND [METHOD]] — print the plan's lines, or only those of KIND (and METHOD).
# Read them with: while IFS=$'\t' read -r kind group method name value flags; do ...
plan_lines() {
  local line kind group method rest
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method rest <<<"$line"
    if [[ -n ${1:-} && $kind != "$1" ]] || [[ -n ${2:-} && $method != "$2" ]]; then continue; fi
    printf '%s\n' "$line"
  done
}

# plan_has KIND NAME — true if the plan already has an item of KIND called NAME.
plan_has() {
  local kind group method name rest
  while IFS=$'\t' read -r kind group method name rest; do
    if [[ $name == "$2" ]]; then return 0; fi
  done < <(plan_lines "$1")
  return 1
}

# plan_items KIND [METHOD] — print the names of the plan's KIND items (with that METHOD).
plan_items() {
  local kind group method name rest
  while IFS=$'\t' read -r kind group method name rest; do
    printf '%s\n' "$name"
  done < <(plan_lines "$1" "${2:-}")
}

# plan_value KIND NAME — print the value of the plan's KIND item called NAME.
plan_value() {
  local kind group method name value rest
  while IFS=$'\t' read -r kind group method name value rest; do
    if [[ $name == "$2" ]]; then printf '%s' "$value"; return 0; fi
  done < <(plan_lines "$1")
  return 1
}

# Load .go-yolo/config and let every catalog add its items.
resolve_plan() {
  local catalog
  load_config
  PLAN=()
  for catalog in "${CATALOGS[@]}"; do
    if "${catalog}_detect"; then "${catalog}_resolve"; fi
  done
  plan_finish
}

# Sort PLAN (by kind rank, then by name) and compute PLAN_HASH.
plan_finish() {
  local line ranked=()
  for line in "${PLAN[@]}"; do
    ranked+=("$(kind_rank "${line%%$'\t'*}")"$'\t'"$line")
  done
  mapfile -t PLAN < <(printf '%s\n' "${ranked[@]}" | LC_ALL=C sort -t $'\t' -k1,1n -k5,5 | cut -f2-)
  PLAN_HASH="$(plan_build_hash "${PLAN[@]}")"
}

# True if LINE goes into the image (as opposed to runtime settings and skipped items).
is_build_line() {
  local kind group method rest
  IFS=$'\t' read -r kind group method rest <<<"$1"
  [[ $method != skip && ${KIND_IMAGE[$kind]:-0} == 1 ]]
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
