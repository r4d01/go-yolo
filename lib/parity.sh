# shellcheck shell=bash
# --parity: run the same probes on the host and in the container, and show the differences.
#
# A probe is a function <pack>_probe (in packs/<pack>.sh) that prints "name<TAB>value" lines.
# The probes and the plan are copied into the container as text (declare -f / declare -p), so
# both sides run exactly the same code. --parity exits with 1 if anything differs.

# The probe script: the plan, the pack probes, and a call to each of them.
parity_script() {
  local pack
  declare -p PLAN
  for pack in "${PACKS[@]}"; do
    if declare -F "${pack}_probe" >/dev/null; then
      declare -f "${pack}_probe"
      printf '%s_probe\n' "$pack"
    fi
  done
}

# Make this run execute the probe script in a shell container instead of an agent.
prepare_parity() {
  AGENT=shell
  PASSTHROUGH_ARGS=(-c "$(parity_script)")
  USE_TMUX=0
  TMUX_FORCED=0
}

# Run the probes on both sides, show each result, exit 0 if all match and 1 otherwise.
run_parity() {
  local name value host_value container_value differences=0
  local -A host=() container=()
  local names=()

  while IFS=$'\t' read -r name value; do
    host[$name]=$value
    names+=("$name")
  done < <(bash -c "$(parity_script)")
  while IFS=$'\t' read -r name value; do
    container[$name]=$value
    if [[ -z ${host[$name]+set} ]]; then names+=("$name"); fi
  done < <("${CMD[@]}" </dev/null)

  note "the same probes on the host and in the container ($IMAGE):"
  for name in "${names[@]}"; do
    host_value=${host[$name]-(no result)}
    container_value=${container[$name]-(no result)}
    if [[ $host_value == "$container_value" ]]; then
      printf '  %s %-28s %s\n' "$(ui_paint green ✓)" "$name" "$(ui_paint dim "$host_value")" >&2
    else
      differences=$((differences + 1))
      printf '  %s %-28s host: %s\n' "$(ui_paint red ✗)" "$name" "$host_value" >&2
      printf '    %-28s container: %s\n' "" "$container_value" >&2
    fi
  done

  if ((differences)); then
    warn "$differences of ${#names[@]} probes differ"
    return 1
  fi
  note "all ${#names[@]} probes match"
}
