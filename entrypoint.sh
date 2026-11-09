#!/usr/bin/env bash
# go-yolo container entrypoint. Runs as root: creates a user matching the host user,
# sets up the firewall (--net allowlist), then drops all privileges and execs the agent.
set -euo pipefail

# Root must never search host-mounted (and potentially agent-writable) executables.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
GOYOLO_DIR=/opt/go-yolo

die() { printf 'go-yolo[entrypoint]: error: %s\n' "$*" >&2; exit 1; }
note() { printf 'go-yolo[entrypoint]: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Validate input and load the agent profile
# ---------------------------------------------------------------------------

[[ $(id -u) == 0 ]] || die "must start as root"
for var in GOYOLO_UID GOYOLO_GID GOYOLO_USER GOYOLO_HOME GOYOLO_AGENT GOYOLO_NET; do
  [[ -n ${!var:-} ]] || die "$var is not set (start the container with go-yolo.sh)"
done
# shellcheck disable=SC2153 # set by the launcher
[[ $GOYOLO_UID =~ ^[0-9]+$ && $GOYOLO_GID =~ ^[0-9]+$ ]] || die "GOYOLO_UID/GOYOLO_GID must be numeric"
[[ ${GOYOLO_UMASK:-0022} =~ ^0?[0-7]{3}$ ]] || die "invalid GOYOLO_UMASK '$GOYOLO_UMASK'"
((GOYOLO_UID != 0 && GOYOLO_GID != 0)) || die "refusing to run the agent as root (UID/GID 0)"
[[ $GOYOLO_USER =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die "invalid GOYOLO_USER '$GOYOLO_USER'"
[[ $GOYOLO_HOME == /?* && $GOYOLO_HOME != *$'\n'* ]] || die "invalid GOYOLO_HOME '$GOYOLO_HOME'"
# An agent is agents/<name>.conf (or the built-in shell).
[[ $GOYOLO_AGENT =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid agent name '$GOYOLO_AGENT'"
[[ $GOYOLO_AGENT == shell || -f $GOYOLO_DIR/agents/$GOYOLO_AGENT.conf ]] || die "unknown agent '$GOYOLO_AGENT'"
case $GOYOLO_NET in
  open|allowlist|none) ;;
  *) die "invalid GOYOLO_NET '$GOYOLO_NET'" ;;
esac
# Anything other than exactly "1" means no YOLO mode.
YOLO=0
if [[ ${GOYOLO_YOLO:-0} == 1 ]]; then YOLO=1; fi
USE_TMUX=0
if [[ ${GOYOLO_TMUX:-0} == 1 ]]; then USE_TMUX=1; fi

export HOME=$GOYOLO_HOME USER=$GOYOLO_USER LOGNAME=$GOYOLO_USER SHELL=/bin/bash

AGENT_BIN="" AGENT_ARGS=() AGENT_YOLO_ARGS=() AGENT_ENV=() AGENT_YOLO_ENV=() AGENT_DOMAINS=()
if [[ $GOYOLO_AGENT != shell ]]; then
  # shellcheck source=/dev/null
  source "$GOYOLO_DIR/agents/$GOYOLO_AGENT.conf"
  [[ -n $AGENT_BIN ]] || die "AGENT_BIN not set in $GOYOLO_AGENT.conf"
fi

# ---------------------------------------------------------------------------
# 2. User and group matching the host
# ---------------------------------------------------------------------------

group_name="$(getent group "$GOYOLO_GID" | cut -d: -f1 || true)"
if [[ -z $group_name ]]; then
  if getent group "$GOYOLO_USER" >/dev/null; then
    groupadd -g "$GOYOLO_GID" "go-yolo-$GOYOLO_GID"
  else
    groupadd -g "$GOYOLO_GID" "$GOYOLO_USER"
  fi
elif [[ $group_name != "$GOYOLO_USER" ]] && ((GOYOLO_GID >= 1000)) && ! getent group "$GOYOLO_USER" >/dev/null; then
  # e.g. the "ubuntu" group (GID 1000) in Ubuntu >= 23.04 images.
  groupmod -n "$GOYOLO_USER" "$group_name"
fi

existing_user="$(getent passwd "$GOYOLO_UID" | cut -d: -f1 || true)"
if [[ -n $existing_user && $existing_user != "$GOYOLO_USER" ]]; then
  # An image user already has our UID (e.g. "ubuntu", UID 1000): take it over.
  if getent passwd "$GOYOLO_USER" >/dev/null; then userdel "$GOYOLO_USER"; fi
  # Also drop its supplementary groups (adm, sudo, ... for "ubuntu").
  usermod -l "$GOYOLO_USER" -d "$GOYOLO_HOME" -g "$GOYOLO_GID" -G "" -s /bin/bash "$existing_user"
elif [[ -n $existing_user ]]; then
  usermod -d "$GOYOLO_HOME" -g "$GOYOLO_GID" -G "" -s /bin/bash "$GOYOLO_USER"
else
  # The name may exist with another UID; the image user is expendable.
  if getent passwd "$GOYOLO_USER" >/dev/null; then userdel "$GOYOLO_USER"; fi
  useradd -M -u "$GOYOLO_UID" -g "$GOYOLO_GID" -d "$GOYOLO_HOME" -s /bin/bash "$GOYOLO_USER"
fi

# Docker creates missing parents of mount points as root ($HOME, $HOME/.config, ...).
# Walk from $HOME down to each mount point and chown every root-owned directory on the
# way that is outside host mounts. Never recurse into a mount or a symlink.
declare -A IS_MOUNT=() CHECKED=()
while read -r _ _ _ _ mount_point _; do
  mount_point=${mount_point//\\040/ }
  mount_point=${mount_point//\\011/$'\t'}
  mount_point=${mount_point//\\012/$'\n'}
  mount_point=${mount_point//\\134/\\}
  IS_MOUNT[$mount_point]=1
done </proc/self/mountinfo

claim_dir() {
  local dir=$1 ancestor=$1
  [[ -z ${CHECKED[$dir]:-} ]] || return 0
  CHECKED[$dir]=1
  # A non-mount directory can still belong to a host bind mount. Exclude
  # ancestors too (except /, which is the container's own root filesystem).
  while [[ $ancestor != / && -n $ancestor ]]; do
    [[ -z ${IS_MOUNT[$ancestor]:-} && ! -L $ancestor ]] || return 0
    ancestor=${ancestor%/*}
  done
  [[ -d $dir ]] || return 0
  if [[ $(stat -c %u "$dir") == 0 ]]; then chown "$GOYOLO_UID:$GOYOLO_GID" "$dir"; fi
}

if [[ ! -e $GOYOLO_HOME ]]; then
  mkdir -p "$GOYOLO_HOME"
  chmod 700 "$GOYOLO_HOME"
fi
claim_dir "$GOYOLO_HOME"
# Under /tmp and /var/tmp too (e.g. a workdir in /tmp/claude-1000/...), but not the
# shared temp directories themselves.
for root in "$GOYOLO_HOME" /tmp /var/tmp; do
  for mount_point in "${!IS_MOUNT[@]}"; do
    [[ $mount_point == "$root"/* ]] || continue
    rel=${mount_point#"$root"/}
    dir=$root
    while [[ $rel == */* ]]; do
      [[ -z ${IS_MOUNT[$dir]:-} && ! -L $dir ]] || break
      dir+="/${rel%%/*}"
      rel=${rel#*/}
      claim_dir "$dir"
    done
  done
done

# The project's cache volumes: a new volume is owned by root; hand it to the user. Only its top
# directory, and only paths that really are mount points.
while IFS= read -r volume_dir; do
  [[ -n $volume_dir ]] || continue
  [[ -n ${IS_MOUNT[$volume_dir]:-} && -d $volume_dir && ! -L $volume_dir ]] \
    || die "GOYOLO_VOLUMES: $volume_dir is not a mounted directory"
  if [[ $(stat -c %u "$volume_dir") == 0 ]]; then chown "$GOYOLO_UID:$GOYOLO_GID" "$volume_dir"; fi
done <<<"${GOYOLO_VOLUMES:-}"
unset GOYOLO_VOLUMES

# ---------------------------------------------------------------------------
# 3. Environment for the user
# ---------------------------------------------------------------------------

AGENT_PATH=$PATH
# The plan's toolchains and tools (and GOYOLO_TOOLS), first on PATH as on the host.
if [[ -n ${GOYOLO_TOOL_PATH:-} ]]; then AGENT_PATH="$GOYOLO_TOOL_PATH:$AGENT_PATH"; fi
unset GOYOLO_TOOL_PATH

# Login shells reset PATH in /etc/profile; restore ours afterwards.
printf 'export PATH=%q\n' "$AGENT_PATH" >/etc/profile.d/zz-go-yolo.sh

# The host's locales are generated in the project image, unless the plan left one out. Then
# LANG falls back to C.UTF-8 and an LC_* variable is dropped, so programs don't complain.
# Locale names are compared like glibc does: case and "-" don't matter (en_US.UTF-8 = en_US.utf8).
available_locales="$(locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d -)"
for var in LANG LC_ALL LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY LC_MESSAGES LC_PAPER \
           LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION; do
  wanted=${!var:-}
  [[ -n $wanted ]] || continue
  wanted=${wanted,,}
  if grep -qxF -- "${wanted//-/}" <<<"$available_locales"; then continue; fi
  if [[ $var == LANG ]]; then
    export LANG=C.UTF-8
  else
    unset "$var"
  fi
done

# Install the host's terminfo entry if the image lacks one for $TERM; failing that, fall
# back to a generic entry (tmux won't start with an unknown terminal).
if [[ -n ${TERM:-} ]] && ! infocmp "$TERM" >/dev/null 2>&1; then
  if [[ -n ${GOYOLO_TERMINFO:-} ]]; then
    terminfo_src="$(mktemp)"
    printf '%s\n' "$GOYOLO_TERMINFO" >"$terminfo_src"
    tic -x -o /etc/terminfo "$terminfo_src" 2>/dev/null || true
    rm -f "$terminfo_src"
  fi
  if ! infocmp "$TERM" >/dev/null 2>&1; then
    note "no terminfo entry for TERM=$TERM; using xterm-256color"
    export TERM=xterm-256color
  fi
fi
unset GOYOLO_TERMINFO

export_pairs() {
  local pair
  for pair in "$@"; do
    [[ $pair =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "invalid KEY=VALUE in $GOYOLO_AGENT.conf: $pair"
    export "${pair?}"
  done
}
# ---------------------------------------------------------------------------
# 4. Firewall
# ---------------------------------------------------------------------------

if [[ $GOYOLO_NET == allowlist ]]; then
  domains=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    read -r line <<<"$line" || true
    if [[ -n $line ]]; then domains+=("$line"); fi
  done <"$GOYOLO_DIR/firewall/allowlist.txt"

  if [[ $GOYOLO_AGENT == shell ]]; then
    # The debug shell gets every agent's domains.
    for conf in "$GOYOLO_DIR"/agents/*.conf; do
      mapfile -t -O "${#domains[@]}" domains < <(
        AGENT_DOMAINS=()
        # shellcheck source=/dev/null
        source "$conf"
        printf '%s\n' "${AGENT_DOMAINS[@]}"
      )
    done
  else
    domains+=("${AGENT_DOMAINS[@]}")
  fi

  extra_domains=${GOYOLO_EXTRA_DOMAINS:-}
  read -d '' -r -a extra <<<"${extra_domains//,/ }" || true
  domains+=("${extra[@]}")

  "$GOYOLO_DIR/scripts/init-firewall.sh" "${domains[@]}" \
    || die "firewall setup failed; refusing to start with open networking"
fi

# ---------------------------------------------------------------------------
# 5. Drop privileges and exec
# ---------------------------------------------------------------------------

# Agent environment overrides must not influence privileged firewall commands.
export_pairs "${AGENT_ENV[@]}"
if ((YOLO)); then export_pairs "${AGENT_YOLO_ENV[@]}"; fi

if [[ $GOYOLO_AGENT == shell ]]; then
  cmd=(bash -l)
else
  cmd=("$AGENT_BIN" "${AGENT_ARGS[@]}")
  if ((YOLO)); then cmd+=("${AGENT_YOLO_ARGS[@]}"); fi
fi
cmd+=("$@")

if ((USE_TMUX)); then
  # Read by tmux.conf for the status bar.
  if ((YOLO)); then GOYOLO_YOLO_LABEL=ON; else GOYOLO_YOLO_LABEL=off; fi
  export GOYOLO_YOLO_LABEL
  # tmux treats an argument ending in ';' as a command separator; "\;" is a literal ';'.
  tmux_cmd=()
  for arg in "${cmd[@]}"; do
    if [[ $arg == *';' ]]; then arg="${arg%;}\\;"; fi
    tmux_cmd+=("$arg")
  done
  cmd=(tmux -f "$GOYOLO_DIR/tmux/tmux.conf" new-session -s go-yolo -n "$GOYOLO_AGENT" -- "${tmux_cmd[@]}")
fi

# The host user's umask, so files get the same permissions as on the host. Set only now: the
# root steps above keep the default.
umask "${GOYOLO_UMASK:-0022}"

# tini runs as PID 1 *after* the privilege drop (instead of docker run --init), so no
# process in the container keeps root or NET_ADMIN.
exec /usr/bin/setpriv --reuid="$GOYOLO_UID" --regid="$GOYOLO_GID" --init-groups \
  --inh-caps=-all --bounding-set=-all --no-new-privs \
  -- /usr/bin/env "PATH=$AGENT_PATH" /usr/bin/tini -g -- "${cmd[@]}"
