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
