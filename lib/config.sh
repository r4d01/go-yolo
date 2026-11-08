# shellcheck shell=bash
# .go-yolo/config: the user's choices for this project.
#
# One item per line; `#` starts a comment:
#
#   extra    package  protobuf-compiler    also install this apt package
#   extra    env      GITHUB_TOKEN         also pass this host environment variable
#   exclude  package  libx11-dev           leave out an item the plan would include
#   exclude  cert     /usr/local/share/ca-certificates/old.crt
#   exclude  locale   cs_CZ.UTF-8
#
# The file is parsed, never sourced. The container can't see it (.go-yolo/ is hidden) and a
# repository can't ship it (tracked .go-yolo/ files are refused).
#
# Sets: CONFIG_ITEMS  one "verb kind name" string per config line

CONFIG_KINDS="package cert locale env"
CONFIG_ITEMS=()

config_file() { printf '%s/.go-yolo/config' "$PROJECT_DIR"; }

load_config() {
  local file line verb kind name rest number=0
  file="$(config_file)"
  CONFIG_ITEMS=()
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    line=${line%%#*}
    verb="" kind="" name="" rest=""
    read -r verb kind name rest <<<"$line" || true
    [[ -n $verb ]] || continue
    [[ $verb == extra || $verb == exclude ]] \
      || die "$file:$number: unknown '$verb' (use extra or exclude)"
    [[ " $CONFIG_KINDS " == *" $kind "* ]] \
      || die "$file:$number: unknown kind '$kind' (use one of: $CONFIG_KINDS)"
    [[ -n $name && -z $rest ]] || die "$file:$number: expected '$verb $kind <name>'"
    CONFIG_ITEMS+=("$verb $kind $name")
  done <"$file"
}

# config_has extra|exclude KIND NAME — true if the config has that line.
config_has() {
  local item
  for item in "${CONFIG_ITEMS[@]}"; do
    if [[ $item == "$1 $2 $3" ]]; then return 0; fi
  done
  return 1
}

# config_extras KIND — print the names of the `extra KIND` lines, one per line.
config_extras() {
  local item
  for item in "${CONFIG_ITEMS[@]}"; do
    if [[ $item == "extra $1 "* ]]; then printf '%s\n' "${item#"extra $1 "}"; fi
  done
}
