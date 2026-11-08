# shellcheck shell=bash
# The selected agent: its profile (agents/<agent>.conf) and its config mounts.
#
# Sets (from the profile): AGENT_MOUNTS          config paths, mounted read-write
#                          AGENT_BATCH_ARGS      flags (anywhere) of non-interactive runs
#                          AGENT_BATCH_COMMANDS  subcommands (first arg) of non-interactive runs
# The profile's other settings are used by the entrypoint, not the launcher.

AGENT_MOUNTS=()
AGENT_BATCH_ARGS=()
AGENT_BATCH_COMMANDS=()

load_agent_profile() {
  if [[ $AGENT == shell ]]; then
    AGENT_BATCH_ARGS=(-c)  # bash -c runs a command and exits
    return 0
  fi
  # shellcheck source=/dev/null
  source "$REPO_DIR/agents/$AGENT.conf"
}

# True if NAME (ignoring a leading dot) contains a dot, e.g. ".claude.json" or "config.toml".
looks_like_file() {
  local name=${1##*/}
  name=${name#.}
  [[ $name == *.* ]]
}

# Mount the selected agent's config, never another agent's. A missing config is created on
# the host so that a login inside the container persists.
add_agent_mounts() {
  local path
  for path in "${AGENT_MOUNTS[@]}"; do
    # Validate before creating a missing config directory on the host.
    validate_mount_path "$path"
    if [[ -e $path ]]; then
      add_mount "$path" rw
    elif [[ $path == *.json ]]; then
      # Without the mount the agent would write this file into the container's home and lose it.
      if ((DRY_RUN)); then
        note "would create $path (mode 600, containing {}) so it persists"
      else
        (umask 077 && printf '{}\n' >"$path")
        note "created $path (mode 600, containing {}) so it persists"
      fi
      add_mount "$path" rw
    elif looks_like_file "$path"; then
      note "skipping $path (does not exist)"
    elif ((DRY_RUN)); then
      note "would create $path (mode 700) so a login inside the container persists"
      add_mount "$path" rw
    else
      mkdir -p -- "$path"
      chmod 700 -- "$path"
      note "created $path (mode 700) so a login inside the container persists"
      add_mount "$path" rw
    fi
  done
}
