# shellcheck shell=bash
# Terminal output: colors and the die/warn/note message helpers.
#
# Colors are on only when stderr is a terminal, TERM isn't "dumb" and NO_COLOR is unset or
# empty (https://no-color.org). --color=always|never overrides that. All launcher messages go
# to stderr, so the agent's stdout (claude -p ...) is never colored by go-yolo.
#
# Sets: UI_RED UI_YELLOW UI_GREEN UI_DIM UI_RESET (empty when colors are off)

UI_RED="" UI_YELLOW="" UI_GREEN="" UI_DIM="" UI_RESET=""

# ui_set_color auto|always|never — turn colors on or off for all later output.
ui_set_color() {
  local enable=0
  case $1 in
    always) enable=1 ;;
    never) enable=0 ;;
    auto)
      if [[ -t 2 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then enable=1; fi
      ;;
    *) die "invalid --color value '$1' (use auto, always or never)" ;;
  esac

  if ((enable)); then
    UI_RED=$'\e[31m' UI_YELLOW=$'\e[33m' UI_GREEN=$'\e[32m' UI_DIM=$'\e[2m' UI_RESET=$'\e[0m'
  else
    UI_RED="" UI_YELLOW="" UI_GREEN="" UI_DIM="" UI_RESET=""
  fi
}

# ui_paint red|yellow|green|dim TEXT — print TEXT in that color (plain when colors are off).
ui_paint() {
  local color
  case $1 in
    red) color=$UI_RED ;;
    yellow) color=$UI_YELLOW ;;
    green) color=$UI_GREEN ;;
    dim) color=$UI_DIM ;;
    *) color="" ;;
  esac
  printf '%s%s%s' "$color" "$2" "${color:+$UI_RESET}"
}

# ui_pick_many PROMPT ITEM... — let the user pick any number of ITEMs; print the picked ones,
# one per line. Uses fzf if it is installed, otherwise asks y/n for each item. Needs a terminal.
ui_pick_many() {
  local prompt=$1 item answer
  shift
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$@" \
      | fzf --multi --reverse --height=50% --prompt="$prompt " \
          --header='TAB: pick/unpick · Enter: done · Esc: pick nothing' || true
    return 0
  fi
  for item in "$@"; do
    read -r -p "$item · $prompt [y/N] " answer
    if [[ $answer == y || $answer == yes ]]; then printf '%s\n' "$item"; fi
  done
}

# ui_pick_list PROMPT SELECTED ITEM... — let the user pick any of the ITEMs, starting with the
# ones whose index (0-based) is in the space-separated SELECTED list; print the indexes of the
# picked items, one per line. fzf if it is installed (TAB toggles), otherwise a numbered list
# to toggle by number. Fails if the user cancels (Esc in fzf). Needs a terminal.
ui_pick_list() {
  local prompt=$1 selected=" $2 " i answer bind="" status picked token from to
  shift 2
  local items=("$@") on=() lines=()
  for i in "${!items[@]}"; do
    on[i]=0
    if [[ $selected == *" $i "* ]]; then on[i]=1; fi
    lines+=("$i"$'\t'"${items[i]}")
  done

  if command -v fzf >/dev/null 2>&1; then
    # Start with the selected items toggled: "start:pos(2)+toggle+pos(5)+toggle+first".
    for i in "${!items[@]}"; do
      if ((on[i])); then bind+="pos($((i + 1)))+toggle+"; fi
    done
    status=0
    picked="$(printf '%s\n' "${lines[@]}" \
      | fzf --multi --reverse --height=80% --prompt="$prompt " --delimiter=$'\t' --with-nth=2.. \
          --header='TAB: pick/unpick · Enter: done · Esc: cancel' --bind "start:${bind}first")" || status=$?
    case $status in
      0) cut -f1 <<<"$picked"; return 0 ;;
      1) return 0 ;;       # nothing picked
      130) return 1 ;;     # Esc
    esac
    # Any other status: this fzf can't do it (too old for "start"); use the list below.
  fi

  while true; do
    for i in "${!items[@]}"; do
      if ((on[i])); then printf '  [x] %2d  %s\n' $((i + 1)) "${items[i]}" >&2
      else printf '  [ ] %2d  %s\n' $((i + 1)) "${items[i]}" >&2; fi
    done
    read -r -p "$prompt toggle numbers (e.g. 3 5-7), a: all, n: none, Enter: done: " answer
    [[ -n $answer ]] || break
    for token in $answer; do
      case $token in
        a) for i in "${!items[@]}"; do on[i]=1; done ;;
        n) for i in "${!items[@]}"; do on[i]=0; done ;;
        *-*) from=${token%-*} to=${token#*-} ;;
        *) from=$token to=$token ;;
      esac
      [[ $token == a || $token == n ]] && continue
      if [[ $from =~ ^[0-9]+$ && $to =~ ^[0-9]+$ ]]; then
        for ((i = from - 1; i < to && i < ${#items[@]}; i++)); do
          if ((i >= 0)); then on[i]=$((1 - on[i])); fi
        done
      fi
    done
  done
  for i in "${!items[@]}"; do
    if ((on[i])); then printf '%s\n' "$i"; fi
  done
}

die() {
  printf '%s %s\n' "$(ui_paint red 'go-yolo: error:')" "$*" >&2
  exit 1
}

warn() {
  printf '%s %s\n' "$(ui_paint yellow 'go-yolo: warning:')" "$*" >&2
}

note() {
  printf 'go-yolo: %s\n' "$*" >&2
}
