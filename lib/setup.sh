# shellcheck shell=bash
# The setup: you pick what the project's container gets, from what the host has.
#
# Every catalog's <catalog>_discover lists candidates, one per line:
#
#   mode   kind       id       hint  name                description
#   image  toolchain  -        1     /opt/go/1.27.0      Go go1.27.0 (/opt/go/1.27.0)
#   cache  cache      modules  1     /home/me/go/pkg/mod module cache (a project volume at ...)
#
# "hint" pre-selects the candidate on a first setup (a go.mod pre-selects the Go items); after
# that the saved picks are the only source of truth, and nothing is detected again. Items added
# by name (apt packages, host commands, mounts, env variables) are kept as candidates too.
#
# Sets: SETUP_CANDIDATES  "catalog<TAB>mode<TAB>kind<TAB>id<TAB>hint<TAB>name<TAB>description"
#       SETUP_SELECTED    the indexes of the candidates picked to begin with

SETUP_CANDIDATES=()
SETUP_SELECTED=()

# Collect every catalog's candidates, plus the picked items no catalog lists (added by name).
collect_candidates() {
  local catalog line item mode kind id
  SETUP_CANDIDATES=()
  for catalog in "${CATALOGS[@]}"; do
    declare -F "${catalog}_discover" >/dev/null || continue
    while IFS= read -r line; do
      [[ -n $line ]] && SETUP_CANDIDATES+=("$catalog"$'\t'"$line")
    done < <("${catalog}_discover")
  done
  for item in "${CONFIG_ITEMS[@]}"; do
    IFS=$'\t' read -r mode catalog kind id <<<"$item"
    if ! candidate_index "$catalog" "$kind" "$id" >/dev/null; then
      SETUP_CANDIDATES+=("$catalog"$'\t'"$mode"$'\t'"$kind"$'\t'"$id"$'\t'1$'\t'"$id"$'\t'"$kind $id (added by name)")
    fi
  done
}

# candidate_index CATALOG KIND ID — print the index of that candidate; fail if there is none.
candidate_index() {
  local i catalog mode kind id rest
  for i in "${!SETUP_CANDIDATES[@]}"; do
    IFS=$'\t' read -r catalog mode kind id rest <<<"${SETUP_CANDIDATES[i]}"
    if [[ $catalog == "$1" && $kind == "$2" && $id == "$3" ]]; then printf '%s' "$i"; return 0; fi
  done
  return 1
}

# Set SETUP_SELECTED to the candidates to start with: the current picks; on a first setup the
# hints; for an old config ("extra"/"exclude" lines) the hints plus its extras minus its excludes.
initial_selection() {
  local i catalog mode kind id hint name rest line verb old_kind old_name
  local -A on=()
  if have_config; then
    for line in "${CONFIG_ITEMS[@]}"; do
      IFS=$'\t' read -r mode catalog kind id <<<"$line"
      if i="$(candidate_index "$catalog" "$kind" "$id")"; then on[$i]=1; fi
    done
  else
    for i in "${!SETUP_CANDIDATES[@]}"; do
      IFS=$'\t' read -r catalog mode kind id hint rest <<<"${SETUP_CANDIDATES[i]}"
      if [[ $hint == 1 ]]; then on[$i]=1; fi
    done
    for line in "${CONFIG_OLD[@]}"; do
      read -r verb old_kind old_name <<<"$line"
      if [[ $verb == extra ]]; then
        add_by_name "$old_kind" "$old_name"
        on[$((${#SETUP_CANDIDATES[@]} - 1))]=1
        if i="$(candidate_index host "$old_kind" "$old_name")"; then on[$i]=1; fi
      else
        # An exclude unpicks whatever candidate stands for that path or name.
        for i in "${!SETUP_CANDIDATES[@]}"; do
          IFS=$'\t' read -r catalog mode kind id hint name rest <<<"${SETUP_CANDIDATES[i]}"
          if [[ $name == "$old_name" || $id == "$old_name" ]]; then unset 'on[$i]'; fi
        done
      fi
    done
  fi
  SETUP_SELECTED=("${!on[@]}")
}

# add_by_name KIND NAME — add a host candidate typed in by name (package, tool, mount, env),
# unless a catalog already lists it.
add_by_name() {
  local kind=$1 name=$2 mode=image
  case $kind in
    mount) mode=mount; name="${name/#\~/$HOME_DIR}" ;;
    env) mode=env ;;
    package|tool) ;;
    *) warn "can't add '$kind $name': use package, tool, mount or env"; return 1 ;;
  esac
  if candidate_index host "$kind" "$name" >/dev/null; then return 0; fi
  SETUP_CANDIDATES+=("host"$'\t'"$mode"$'\t'"$kind"$'\t'"$name"$'\t'1$'\t'"$name"$'\t'"$kind $name (added by name)")
}

# How a candidate is shown in the picker: "go     image  Go go1.27.0 (/opt/go/1.27.0)".
candidate_label() {
  local catalog mode kind id hint name description
  IFS=$'\t' read -r catalog mode kind id hint name description <<<"$1"
  printf '%-6s %-6s %s' "$catalog" "$mode" "$description"
}

# run_setup [ask] — pick the project's items and set CONFIG_ITEMS: with "ask" in the picker,
# otherwise the initial selection as it is (--yes, or a dry run's preview).
run_setup() {
  local labels=() indexes=() items=() i catalog mode kind id rest answer kind_word name picked
  collect_candidates
  initial_selection
  indexes=("${SETUP_SELECTED[@]}")

  if [[ ${1:-} == ask ]]; then
    for i in "${!SETUP_CANDIDATES[@]}"; do labels+=("$(candidate_label "${SETUP_CANDIDATES[i]}")"); done
    note "pick what this project's container gets (versions always come from the host):"
    picked="$(ui_pick_list 'pick:' "${indexes[*]}" "${labels[@]}")" || die "setup cancelled; nothing changed"
    mapfile -t indexes < <(printf '%s' "$picked" | grep .)
    while true; do
      read -r -p "go-yolo: add more, e.g. 'package protobuf-compiler', 'tool kotlin', 'mount ~/notes', 'env GITHUB_TOKEN' (Enter: done): " answer
      [[ -n $answer ]] || break
      read -r kind_word name <<<"$answer"
      if [[ -n $name ]] && add_by_name "$kind_word" "$name"; then
        indexes+=("$(candidate_index host "$kind_word" "${name/#\~/$HOME_DIR}")")
      fi
    done
  fi

  for i in $(printf '%s\n' "${indexes[@]}" | sort -n -u); do
    IFS=$'\t' read -r catalog mode kind id rest <<<"${SETUP_CANDIDATES[i]}"
    items+=("$mode"$'\t'"$catalog"$'\t'"$kind"$'\t'"$id")
  done
  CONFIG_ITEMS=("${items[@]}")
}

# Make sure the project has a setup: run the picker for --setup, or when there is no config yet
# (or an old one). Without a terminal, --yes takes the suggestions; a dry run previews them.
ensure_setup() {
  local file interactive=0
  file="$(config_file)"
  load_config
  if ((!SETUP)) && have_config; then return 0; fi

  if [[ -t 0 && -t 2 ]] && ((!YES && !DRY_RUN)); then interactive=1; fi
  if ((SETUP && !interactive && !YES && !DRY_RUN)); then die "--setup needs a terminal (or --yes to take the suggested picks)"; fi

  if ((interactive)); then
    if ((${#CONFIG_OLD[@]})); then note "the config is in an older format; the picks start from it (it is kept as config.old)"; fi
    run_setup ask
  elif ((DRY_RUN)); then
    note "no setup yet: this is what the suggested picks would give"
    run_setup
    return 0
  elif ((YES)); then
    note "no setup yet: taking the suggested picks (--yes); go-yolo.sh --setup changes them"
    run_setup
  else
    die "this project has no setup yet: run go-yolo.sh --setup in a terminal (or pass --yes to take the suggested picks)"
  fi

  if ((DRY_RUN)); then return 0; fi
  if ((${#CONFIG_OLD[@]})); then cp -- "$file" "$file.old"; fi
  save_config "${CONFIG_ITEMS[@]}"
  CONFIG_OLD=()
  note "saved the picks in $file"
}
