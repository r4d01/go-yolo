# shellcheck shell=bash
# --parity: run the same probes on the host and in the container, and show the differences.
#
# A probe is a function <catalog>_probe (in catalogs/<catalog>.sh) that prints "name<TAB>value" lines.
# The probes and the plan are copied into the container as text (declare -f / declare -p), so
# both sides run exactly the same code. --parity exits with 1 if anything differs.

# The probe script: the plan, the probes of the catalogs this project has picks from (and the
# host catalog's), and a call to each.
parity_script() {
  local catalog
  declare -p PLAN
  for catalog in "${CATALOGS[@]}"; do
    if declare -F "${catalog}_probe" >/dev/null && { [[ $catalog == host ]] || catalog_picked "$catalog"; }; then
      declare -f "${catalog}_probe"
      printf '%s_probe\n' "$catalog"
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
  local name value host_value container_value differences=0 line kind group method item flags
  local -A host=() container=() container_only=()
  local names=()

  # Probes of items the host doesn't have (D23) can only run in the container: "kind name".
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method item value flags <<<"$line"
    if [[ ,$flags, == *,not-on-host,* ]]; then container_only["$kind $item"]=1; fi
  done

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
    if [[ -n ${container_only[$name]:-} ]]; then
      printf '  %s %-28s %s\n' "$(ui_paint yellow ○)" "$name" "only in the container (not on the host): $container_value" >&2
    elif [[ $host_value == "$container_value" ]]; then
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
