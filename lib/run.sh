# shellcheck shell=bash
# The docker run command: network, tmux, environment and the banner.
#
# Sets: NET_ARGS  docker run arguments for the network mode
#       TTY_ARGS  -it on a terminal, -i otherwise
#       CMD       the complete docker run command

# The locale settings passed into the container (the plan generates their locales).
LOCALE_VARS=(LANG LC_ALL LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY LC_MESSAGES LC_PAPER
             LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION)
NET_ARGS=()
TTY_ARGS=()
CMD=()

set_network_args() {
  case $NET in
    open) NET_ARGS=() ;;
    # The entrypoint needs these to set up the firewall and drops them before the agent starts.
    allowlist) NET_ARGS=(--cap-add=NET_ADMIN --cap-add=NET_RAW) ;;
    none) NET_ARGS=(--network none) ;;
  esac
}

# True if the agent args ask for a non-interactive run (claude -p, codex exec, --help, ...).
is_batch_run() {
  local arg batch
  (($#)) || return 1
  for batch in "${AGENT_BATCH_COMMANDS[@]}"; do
    if [[ $1 == "$batch" ]]; then return 0; fi
  done
  for arg in "$@"; do
    for batch in --help --version "${AGENT_BATCH_ARGS[@]}"; do
      if [[ $arg == "$batch" ]]; then return 0; fi
    done
  done
  return 1
}

# Decide USE_TMUX and TTY_ARGS.
decide_tmux() {
  # A non-interactive run would print into a tmux window that closes as soon as the agent
  # exits, so run it directly unless --tmux was given.
  if ((USE_TMUX && !TMUX_FORCED)) && is_batch_run "${PASSTHROUGH_ARGS[@]}"; then
    USE_TMUX=0
  fi

  # --parity reads the container's output, so it gets no terminal.
  if ((PARITY)); then
    TTY_ARGS=()
    return 0
  fi
  if [[ -t 0 && -t 1 ]]; then
    TTY_ARGS=(-it)
    return 0
  fi
  # tmux needs a terminal. It is the default, so fall back to running the agent directly
  # (e.g. for piped or scripted runs) unless --tmux was given explicitly.
  if ((TMUX_FORCED && !DRY_RUN)); then die "--tmux needs a terminal (stdin and stdout must be a TTY)"; fi
  if ((!TMUX_FORCED)); then USE_TMUX=0; fi
  TTY_ARGS=(-i)
}

build_docker_command() {
  local pwd_hash rand_suffix var terminfo env_args
  pwd_hash="$(printf '%s' "$WORKDIR" | sha256sum | cut -c1-8)"
  rand_suffix="$(printf '%04x' $((RANDOM % 65536)))"

  CMD=(docker run --rm "${TTY_ARGS[@]}"
    --name "go-yolo-$AGENT-$pwd_hash-$rand_suffix"
    --hostname go-yolo
    --security-opt no-new-privileges
    -w "$WORKDIR"
    -e "GOYOLO_UID=$HOST_UID"
    -e "GOYOLO_GID=$HOST_GID"
    -e "GOYOLO_USER=$HOST_USER"
    -e "GOYOLO_HOME=$HOME_DIR"
    -e "GOYOLO_AGENT=$AGENT"
    -e "GOYOLO_NET=$NET"
    -e "GOYOLO_YOLO=$YOLO"
    -e "GOYOLO_TMUX=$USE_TMUX"
    -e "GOYOLO_EXTRA_DOMAINS=${GOYOLO_EXTRA_DOMAINS:-}"
    -e "GOYOLO_UMASK=$(umask)"
  )
  # Nested tmux: the container's tmux switches its prefix to C-a.
  if [[ -n ${TMUX:-} ]]; then CMD+=(-e GOYOLO_HOST_TMUX=1); fi
  # LANGUAGE is gettext's list of message languages (e.g. en_US:en), not a locale name.
  for var in TERM COLORTERM LANGUAGE "${LOCALE_VARS[@]}"; do
    if [[ -n ${!var:-} ]]; then CMD+=(-e "$var"); fi
  done
  # The image may lack the host terminal's terminfo entry (xterm-ghostty, xterm-kitty, ...)
  # and tmux refuses to start without it; pass the host's entry along.
  if [[ -n ${TERM:-} ]] && command -v infocmp >/dev/null 2>&1 \
    && terminfo="$(infocmp -x "$TERM" 2>/dev/null)"; then
    CMD+=(-e "GOYOLO_TERMINFO=$terminfo")
  fi
  mapfile -t env_args < <(plan_env_args)
  CMD+=("${env_args[@]}" "${GO_ENV[@]}" "${TOOL_ENV[@]}" "${MOUNTS[@]}")
  # Hide .go-yolo/ behind an empty tmpfs that only root could write to.
  CMD+=(--mount "type=tmpfs,$(csv_field "destination=$STATE_DIR"),tmpfs-mode=0555")
  CMD+=("${NET_ARGS[@]}" "$IMAGE" "${PASSTHROUGH_ARGS[@]}")
}

warn_yolo() {
  ((YOLO)) || return 0
  if [[ $NET == open ]]; then
    warn "YOLO mode: $AGENT runs without permission prompts and network access is unrestricted (consider --net allowlist)"
  else
    warn "YOLO mode: $AGENT runs without permission prompts"
  fi
}

# One line on stderr, so the agent's stdout stays clean. GOYOLO_QUIET=1 turns it off.
print_banner() {
  [[ ${GOYOLO_QUIET:-0} != 1 ]] || return 0
  local path mode rw="" ro="" yolo net line
  for path in "${MOUNT_ORDER[@]}"; do
    mode=${MOUNTED[$path]}
    if [[ $path == "$HOME_DIR"/* ]]; then path=\~/${path#"$HOME_DIR"/}; fi
    if [[ $mode == ro ]]; then ro+="${ro:+, }$path"; else rw+="${rw:+, }$path"; fi
  done
  if ((YOLO)); then yolo="$(ui_paint red ON)"; else yolo=off; fi
  if [[ $NET == open ]]; then net="$(ui_paint yellow open)"; else net="$(ui_paint green "$NET")"; fi

  line="go-yolo: $AGENT in container $IMAGE · plan $PLAN_HASH ($PLAN_CONFIRMED) · net=$net · yolo=$yolo"
  if ((USE_TMUX)); then line+=" · tmux"; fi
  if [[ -n $rw ]]; then line+=" · rw: $rw"; fi
  if [[ -n $ro ]]; then line+=" · ro: $ro"; fi
  printf '%s\n' "$line" >&2
}
