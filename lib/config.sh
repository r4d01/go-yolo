# shellcheck shell=bash
# .go-yolo/config: what this project's container gets, as picked in the setup picker.
#
# One picked item per line, "mode catalog kind id"; `#` starts a comment:
#
#   image  go    toolchain  -                  the Go toolchain (installed in the image)
#   image  go    tool       gopls              a tool in GOBIN (built with go install)
#   copy   go    tool       my-tool            ... copied from the host instead
#   cache  go    cache      modules            the module cache (a project volume)
#   mount  go    mount      goenv              the GOENV file (read-only)
#   env    go    env        GOPRIVATE          a host environment variable
#   image  java  jdk        /usr/lib/jvm/java-21-openjdk-amd64
#   image  host  package    protobuf-compiler  an apt package
#   image  host  tool       kotlin             a host command (its install directory)
#   mount  host  mount      /home/me/notes     a host path (read-only)
#   env    host  env        GITHUB_TOKEN       a host environment variable
#
# Modes: image (installed in the image from its source, or copied where no recipe knows how),
# copy (copied from the host even where a recipe would install it), mount (read-only), cache (a
# project volume), env.
#
# The config says *what*; versions are read from the host on every run. go-yolo.sh --setup
# writes it (the setup picker, lib/setup.sh); editing it by hand works too. It is parsed, never
# sourced. The container can't see it (.go-yolo/ is hidden) and a repository can't ship it
# (tracked .go-yolo/ files are refused).
#
# An old config ("extra KIND NAME" / "exclude KIND NAME" lines) is converted by the setup,
# which keeps it as config.old.
#
# Sets: CONFIG_ITEMS  one "mode<TAB>catalog<TAB>kind<TAB>id" string per picked item
#       CONFIG_OLD    the lines of an old-format config (empty for a new-format one)

CONFIG_MODES="image copy mount cache env"
CONFIG_ITEMS=()
CONFIG_OLD=()

config_file() { printf '%s/.go-yolo/config' "$PROJECT_DIR"; }

# True if this project has a config in the current format (its setup has been done).
have_config() { [[ -f $(config_file) ]] && ((${#CONFIG_OLD[@]} == 0)); }

load_config() {
  local file line mode catalog kind id number=0
  file="$(config_file)"
  CONFIG_ITEMS=()
  CONFIG_OLD=()
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    line=${line%%#*}
    mode="" catalog="" kind="" id=""
    read -r mode catalog kind id <<<"$line" || true
    [[ -n $mode ]] || continue
    if [[ $mode == extra || $mode == exclude ]]; then
      CONFIG_OLD+=("$mode $catalog $kind")   # old format: verb, kind, name
      continue
    fi
    [[ " $CONFIG_MODES " == *" $mode "* ]] \
      || die "$file:$number: unknown mode '$mode' (use one of: $CONFIG_MODES)"
    [[ " ${CATALOGS[*]} " == *" $catalog "* ]] \
      || die "$file:$number: unknown catalog '$catalog' (one of: ${CATALOGS[*]})"
    [[ -n $kind && -n $id ]] || die "$file:$number: expected '$mode $catalog <kind> <id>'"
    CONFIG_ITEMS+=("$mode"$'\t'"$catalog"$'\t'"$kind"$'\t'"$id")
  done <"$file"
}

# picked CATALOG KIND ID — true if the config picks that item.
picked() {
  local item
  for item in "${CONFIG_ITEMS[@]}"; do
    if [[ ${item#*$'\t'} == "$1"$'\t'"$2"$'\t'"$3" ]]; then return 0; fi
  done
  return 1
}

# picked_mode CATALOG KIND ID — print the mode the config picks that item with (image, copy, ...).
picked_mode() {
  local item mode rest
  for item in "${CONFIG_ITEMS[@]}"; do
    IFS=$'\t' read -r mode rest <<<"$item"
    if [[ $rest == "$1"$'\t'"$2"$'\t'"$3" ]]; then printf '%s' "$mode"; return 0; fi
  done
  return 1
}

# catalog_picked CATALOG — true if the config picks anything from CATALOG.
catalog_picked() {
  local item mode catalog rest
  for item in "${CONFIG_ITEMS[@]}"; do
    IFS=$'\t' read -r mode catalog rest <<<"$item"
    if [[ $catalog == "$1" ]]; then return 0; fi
  done
  return 1
}

# picked_ids CATALOG KIND — print the ids of the picked items of that kind, one per line.
picked_ids() {
  local item mode catalog kind id
  for item in "${CONFIG_ITEMS[@]}"; do
    IFS=$'\t' read -r mode catalog kind id <<<"$item"
    if [[ $catalog == "$1" && $kind == "$2" ]]; then printf '%s\n' "$id"; fi
  done
}

# save_config ITEM... — write .go-yolo/config with these "mode<TAB>catalog<TAB>kind<TAB>id" items.
save_config() {
  local item mode catalog kind id
  {
    printf '# go-yolo setup for %s: what the container gets.\n' "$PROJECT_DIR"
    printf '# One item per line, "mode catalog kind id"; go-yolo.sh --setup picks them, editing\n'
    printf '# by hand works too. Versions are read from the host on every run.\n'
    for item in "$@"; do
      IFS=$'\t' read -r mode catalog kind id <<<"$item"
      printf '%-6s %-8s %-10s %s\n' "$mode" "$catalog" "$kind" "$id"
    done
  } >"$(config_file)"
}
