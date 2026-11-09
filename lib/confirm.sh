# shellcheck shell=bash
# Showing the plan, diffing it against the confirmed one, and asking before going on.

# plan_key LINE — what identifies an item across plans: its kind and name. The base image is one
# item whatever its tag, so a new base shows as a change, not as a new item.
plan_key() {
  local kind group method name rest
  IFS=$'\t' read -r kind group method name rest <<<"$1"
  if [[ $kind == base ]]; then printf 'base'; else printf '%s\t%s' "$kind" "$name"; fi
}

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

# Show the plan in short: one line per group ("go: toolchain go1.27.0, 2 caches, 6 env"), then
# every item with a warning in full, so nothing that needs a look is hidden.
show_plan_summary() {
  local kind group method name value flags item groups=() line warned=()
  local -A parts=() counts=() left_out=() versions=()
  while IFS=$'\t' read -r kind group method name value flags; do
    if [[ -z ${parts[$group]+set} ]]; then groups+=("$group"); parts[$group]=""; fi
    if [[ $method == skip ]]; then
      left_out[$group]=$((${left_out[$group]:-0} + 1))
    else
      case $kind in
        base) item="base ${name##*:}" ;;
        toolchain) versions[$group]+="${versions[$group]:+, }$value"; item="" ;;
        tools) item="tools (${value%%,*})" ;;
        *) counts[$group/$kind]=$((${counts[$group/$kind]:-0} + 1)); item="" ;;
      esac
      if [[ -n $item ]]; then parts[$group]+="${parts[$group]:+, }$item"; fi
    fi
    if [[ $flags != - ]] && plan_line_warns "$flags"; then warned+=("$kind"$'\t'"$group"$'\t'"$method"$'\t'"$name"$'\t'"$value"$'\t'"$flags"); fi
  done < <(plan_lines)

  for group in "${groups[@]}"; do
    line=${parts[$group]}
    if [[ -n ${versions[$group]:-} ]]; then line="toolchain ${versions[$group]}${line:+, }$line"; fi
    for kind in package link cert locale parity mount cache domain env; do
      if [[ -n ${counts[$group/$kind]:-} ]]; then
        line+="${line:+, }$(count_of "${counts[$group/$kind]}" "$kind")"
      fi
    done
    if [[ -n ${left_out[$group]:-} ]]; then line+="${line:+, }${left_out[$group]} left out"; fi
    printf '  %-6s %s\n' "$group:" "$line" >&2
  done
  if ((${#warned[@]})); then
    printf '  warnings:\n' >&2
    for line in "${warned[@]}"; do plan_row ' ' "$line"; done
  fi
  note "every item: go-yolo.sh --plan (or [p] below)"
}

# count_of N KIND — "1 cache", "2 caches", "3 env", "2 parity notes".
count_of() {
  local n=$1 word=$2
  case $word in
    env) ;;
    parity) word="parity note" ;;
  esac
  if ((n != 1)) && [[ $word != env ]]; then word+=s; fi
  printf '%s %s' "$n" "$word"
}

# True if the comma-separated FLAGS have a warning.
plan_line_warns() {
  local flag
  for flag in ${1//,/ }; do
    if [[ ${FLAG_TYPE[${flag%%=*}]:-} == warning ]]; then return 0; fi
  done
  return 1
}

# True if PLAN exposes something CONFIRMED_PLAN didn't: an item that wasn't there, or one that was
# left out and is now included. Version, value and note changes, and removed items, expose
# nothing new (D20), so they don't need asking.
plan_exposes_more() {
  local line key kind group method rest
  local -A old=()
  for line in "${CONFIRMED_PLAN[@]}"; do
    IFS=$'\t' read -r kind group method rest <<<"$line"
    old[$(plan_key "$line")]=$method
  done
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method rest <<<"$line"
    # A skipped item, a base image or a parity note exposes nothing to the container.
    [[ $method != skip && $kind != base && $kind != parity ]] || continue
    key="$(plan_key "$line")"
    if [[ -z ${old[$key]+set} || ${old[$key]} == skip ]]; then return 0; fi
  done
  return 1
}

# One line saying what changed, for changes that need no asking: "package zlib1g-dev 1.3-1 →
# 1.3-2; removed: parity apt; 2 notes changed" (at most 4 items, then "and N more").
plan_update_line() {
  local line key kind group method name value flags rest old_value notes=0 more=0
  local items=()
  local -A old=() new=()
  local old_name
  for line in "${CONFIRMED_PLAN[@]}"; do old[$(plan_key "$line")]=$line; done
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name value flags <<<"$line"
    key="$(plan_key "$line")"
    new[$key]=1
    [[ -n ${old[$key]:-} && ${old[$key]} != "$line" ]] || continue
    IFS=$'\t' read -r _ _ _ old_name old_value _ <<<"${old[$key]}"
    if [[ $old_name != "$name" ]]; then
      items+=("$kind ${old_name##*:} → ${name##*:}")
    elif [[ $old_value == "$value" ]]; then
      notes=$((notes + 1))
    elif [[ $value == sha256:* ]]; then
      items+=("$kind ${name##*/}: value changed")
    else
      items+=("$kind ${name##*/} $old_value → $value")
    fi
  done
  for key in "${!old[@]}"; do
    if [[ -z ${new[$key]:-} ]]; then
      name=${key#*$'\t'}
      items+=("removed: ${key%%$'\t'*} ${name##*/}")
    fi
  done
  if ((notes)); then items+=("$(count_of "$notes" note) changed"); fi
  if ((${#items[@]} > 4)); then more=$((${#items[@]} - 4)); items=("${items[@]:0:4}"); fi
  line="$(printf '%s; ' "${items[@]}")"
  line=${line%; }
  if ((more)); then line+="; and $more more"; fi
  printf '%s' "$line"
}

# plan_change OLD_LINE NEW_LINE — what an item was before, in words ("" if only its notes changed).
plan_change() {
  local kind old_group old_method name old_value old_flags group method value flags
  IFS=$'\t' read -r kind old_group old_method name old_value old_flags <<<"$1"
  IFS=$'\t' read -r kind group method name value flags <<<"$2"
  local old_name
  IFS=$'\t' read -r _ _ _ old_name _ _ <<<"$1"
  if [[ $old_name != "$name" ]]; then printf 'was %s' "$old_name"
  elif [[ $old_method == skip && $method != skip ]]; then printf 'was left out'
  elif [[ $old_method != skip && $method == skip ]]; then printf 'was included'
  elif [[ $old_value != "$value" && $old_value == sha256:* ]]; then printf 'value changed'
  elif [[ $old_value != "$value" ]]; then printf 'was %s' "$old_value"
  elif [[ $old_group != "$group" ]]; then printf 'was from %s' "$old_group"
  fi
}

# Show what changed between CONFIRMED_PLAN and PLAN: + added, - removed, ~ changed.
show_plan_diff() {
  local line key
  local -A old=() new=()
  for line in "${CONFIRMED_PLAN[@]}"; do old[$(plan_key "$line")]=$line; done
  for line in "${PLAN[@]}"; do
    key="$(plan_key "$line")"
    new[$key]=$line
    if [[ -z ${old[$key]:-} ]]; then
      plan_row + "$line"
    elif [[ ${old[$key]} != "$line" ]]; then
      plan_row '~' "$line" "$(plan_change "${old[$key]}" "$line")"
    fi
  done
  for line in "${CONFIRMED_PLAN[@]}"; do
    if [[ -z ${new[$(plan_key "$line")]:-} ]]; then plan_row - "$line"; fi
  done
}

# Open .go-yolo/config in $VISUAL or $EDITOR (vi). (go-yolo.sh --setup is the picker for it.)
edit_config() {
  local file
  file="$(config_file)"
  if [[ ! -e $file ]]; then save_config "${CONFIG_ITEMS[@]}"; fi
  "${VISUAL:-${EDITOR:-vi}}" "$file" </dev/tty >/dev/tty
}

# Show the plan if it is new or exposes more than the confirmed one, and ask before going on.
# Changes that expose nothing new (D20) are taken with a one-line note. Without a terminal a
# plan that needs asking is never used (except with --yes); a dry run shows it and goes on.
# --plan (PLAN_DETAILS) shows every item instead of the summary.
confirm_plan() {
  local answer
  read_confirmed_plan
  while true; do
    if [[ "$(printf '%s\n' "${CONFIRMED_PLAN[@]}")" == "$(printf '%s\n' "${PLAN[@]}")" ]]; then
      if ((PLAN_DETAILS)); then show_plan; fi
      return 0
    fi

    if ((${#CONFIRMED_PLAN[@]})) && ! plan_exposes_more; then
      note "plan updated, nothing new exposed: $(plan_update_line)"
      if ((PLAN_DETAILS)); then show_plan_diff; fi
      if ((!DRY_RUN)); then save_plan; fi
      return 0
    fi

    if ((${#CONFIRMED_PLAN[@]})); then
      note "the plan for this project changed since it was confirmed ($PLAN_CONFIRMED):"
      show_plan_diff
    elif ((PLAN_DETAILS)); then
      note "plan for $PROJECT_DIR (new; go-yolo.sh --setup changes the picks):"
      show_plan
    else
      note "plan for $PROJECT_DIR (new; go-yolo.sh --setup changes the picks):"
      show_plan_summary
    fi

    if ((YES)); then save_plan; return 0; fi
    if ((DRY_RUN)); then note "dry run: the plan is not confirmed"; return 0; fi
    [[ -t 0 && -t 2 ]] \
      || die "the plan is new or changed; run go-yolo in a terminal to confirm it, or pass --yes"

    while true; do
      if plan_has_warnings; then warn "the plan has warnings (⚠); check them before you go on"; fi
      read -r -p "go-yolo: use this plan? [y]es [n]o [p]lan [s]etup [e]dit config [d]ockerfile: " answer
      case $answer in
        y|yes) save_plan; return 0 ;;
        n|no|'') note "aborted; nothing was built"; exit 1 ;;
        p|plan) show_plan ;;
        s|setup) run_setup ask; save_setup; resolve_plan; break ;;
        e|edit) edit_config; load_config; resolve_plan; break ;;
        d|dockerfile) project_dockerfile >&2 ;;
        *) note "y: build with this plan · n: stop · p: show every item · s: change the picks (e.g. leave out a ⚠ item) · e: edit .go-yolo/config · d: show the Dockerfile" ;;
      esac
    done
  done
}
