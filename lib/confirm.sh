# shellcheck shell=bash
# Showing the plan, diffing it against the confirmed one, and asking before going on.

# plan_row MARK LINE [CHANGE] — print one plan line for people: "  + package  zlib1g-dev=1.3-1  note".
# CHANGE says what the item was before (see plan_change).
plan_row() {
  local mark=$1 change=${3:-} kind group method name value flags text flag notes="" color=""
  IFS=$'\t' read -r kind group method name value flags <<<"$2"
  text="$(kind_text "$kind" "$name" "$value")"
  if [[ $group != host ]]; then text+=" [$group]"; fi

  if [[ $flags != - ]]; then
    for flag in ${flags//,/ }; do
      notes+="${notes:+; }$(flag_note "$flag" "$name")"
    done
  fi
  if [[ -n $change ]]; then notes+="${notes:+; }$change"; fi
  if [[ $mark == - ]]; then notes=""; fi  # a removed item's notes no longer matter

  case $mark in
    +) color=green ;;
    -) color=red ;;
    \~) color=yellow ;;
  esac
  if [[ $method == skip ]]; then text="$(ui_paint dim "$text")"; fi
  printf '  %s %-9s %s' "$(ui_paint "$color" "$mark")" "$kind" "$text" >&2
  if [[ $notes == *⚠* ]]; then
    printf '  %s' "$(ui_paint yellow "$notes")" >&2
  elif [[ -n $notes ]]; then
    printf '  %s' "$(ui_paint dim "$notes")" >&2
  fi
  printf '\n' >&2
}

# True if a plan line has a warning flag (one whose note starts with "⚠").
plan_has_warnings() {
  local kind group method name value flags flag
  while IFS=$'\t' read -r kind group method name value flags; do
    for flag in ${flags//,/ }; do
      if [[ ${FLAG_TYPE[${flag%%=*}]:-} == warning ]]; then return 0; fi
    done
  done < <(plan_lines)
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
  local line key kind group method name rest
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
