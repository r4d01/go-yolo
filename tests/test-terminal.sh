#!/usr/bin/env bash
# tmux selection and colors.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# tmux is only chosen on a terminal; script(1) provides one.
if command -v script >/dev/null 2>&1; then
  tmux_env() {
    local cmd
    printf -v cmd '%q ' "$@"
    TEST_CMD=$cmd timeout 60 script -qec 'bash -c "$TEST_CMD"' /dev/null </dev/null \
      | tr -d '\r' | grep -oE '^GOYOLO_TMUX=[01]$'
  }
  run_tty() {
    tmux_env env -i HOME="$TEST_HOME" PATH="$TEST_DIR/bin:/usr/bin:/bin" GOYOLO_TOOLS= GOENV=off \
      GOYOLO_OS_RELEASE="$REPO_DIR/tests/fixtures/os-release" GOYOLO_QUIET=1 \
      DOCKER_TEST_LOG="$TEST_DIR/docker.log" GOROOT="$TEST_HOME/toolchain" GOPATH="$TEST_HOME/go" \
      GOCACHE="$TEST_HOME/cache" GOMODCACHE="$TEST_HOME/go/pkg/mod" \
      bash -c 'cd "$1" && shift && exec "$@"' _ "$TEST_HOME/project" "$REPO_DIR/go-yolo.sh" --dry-run "$@"
  }
  [[ $(run_tty claude) == GOYOLO_TMUX=1 ]] || fail 'interactive claude did not use tmux'
  [[ $(run_tty claude --model opus "fix -p handling") == GOYOLO_TMUX=1 ]] || fail 'prompt text disabled tmux'
  [[ $(run_tty claude --model opus -p hi) == GOYOLO_TMUX=0 ]] || fail 'claude -p used tmux'
  [[ $(run_tty codex exec hi) == GOYOLO_TMUX=0 ]] || fail 'codex exec used tmux'
  [[ $(run_tty codex "exec") == GOYOLO_TMUX=0 ]] || fail 'codex exec used tmux'
  [[ $(run_tty codex hi exec) == GOYOLO_TMUX=1 ]] || fail 'a later "exec" word disabled tmux'
  [[ $(run_tty shell -c 'go version') == GOYOLO_TMUX=0 ]] || fail 'shell -c used tmux'
  [[ $(run_tty --tmux claude -p hi) == GOYOLO_TMUX=1 ]] || fail '--tmux did not force tmux'
  pass 'non-interactive agent runs skip tmux unless --tmux is given'

  # stderr on a terminal: colors by default, none with NO_COLOR or TERM=dumb.
  tty_error() {
    local cmd
    printf -v cmd '%q ' env -i HOME="$TEST_HOME" PATH="$TEST_DIR/bin:/usr/bin:/bin" "$@" \
      GOYOLO_OS_RELEASE="$REPO_DIR/tests/fixtures/os-release" \
      "$REPO_DIR/go-yolo.sh" --dry-run --mount /etc/passwd shell
    (cd "$TEST_HOME/project" && TEST_CMD=$cmd timeout 60 script -qec 'bash -c "$TEST_CMD"' /dev/null </dev/null | tr -d '\r') || true
  }
  [[ $(tty_error TERM=xterm) == *$'\e[31mgo-yolo: error:'* ]] || fail 'error on a terminal was not red'
  [[ $(tty_error TERM=xterm NO_COLOR=1) != *$'\e['* ]] || fail 'NO_COLOR did not turn colors off'
  [[ $(tty_error TERM=dumb) != *$'\e['* ]] || fail 'TERM=dumb did not turn colors off'
  pass 'colors follow the terminal, NO_COLOR and TERM=dumb'
else
  printf 'skip - script(1) unavailable; tmux selection not tested\n'
fi

if output="$(launch --color=always --dry-run --mount /etc/passwd shell 2>&1)"; then fail 'accepted /etc/passwd'; fi
[[ $output == *$'\e[31mgo-yolo: error:\e[0m refusing to mount'* ]] || fail "--color=always error not red: $output"
if output="$(launch --dry-run --mount /etc/passwd shell 2>&1)"; then fail 'accepted /etc/passwd'; fi
[[ $output != *$'\e['* ]] || fail 'colors were used without a terminal'
if output="$(launch --color=sometimes --dry-run shell 2>&1)"; then fail 'accepted --color=sometimes'; fi
[[ $output == *"invalid --color value 'sometimes'"* ]] || fail "unexpected error: $output"
dry_run --color=always shell
for arg in "${ARGS[@]}"; do [[ $arg != *$'\e['* ]] || fail 'color codes leaked into the docker command'; done
pass '--color always|never overrides detection and never touches stdout'
