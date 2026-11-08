#!/usr/bin/env bash
# Launcher regressions: no Docker daemon, Go installation, or host config changes needed.
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d /tmp/go-yolo-tests.XXXXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
TEST_HOME="$TEST_DIR/home"
mkdir -p "$TEST_DIR/bin" "$TEST_HOME"/{bin,project/nested/deeper,go/pkg/mod,cache,toolchain,links,.gradle,.m2} \
  "$TEST_DIR/jdk/bin" "$TEST_DIR/java-config" "$TEST_HOME/with spaces"
cp "$REPO_DIR/tests/fixtures/"{go,docker} "$TEST_DIR/bin/"
chmod +x "$TEST_DIR/bin/"{go,docker}
cp "$REPO_DIR/tests/fixtures/go" "$TEST_DIR/jdk/bin/java"
chmod +x "$TEST_DIR/jdk/bin/java"
cp "$TEST_DIR/jdk/bin/java" "$TEST_HOME/bin/java"
cp "$REPO_DIR/tests/fixtures/os-release" "$TEST_DIR/java-config/security"
ln -s "$TEST_DIR/java-config/security" "$TEST_DIR/jdk/security"
ln -s "$TEST_HOME" "$TEST_HOME/links/home"
ln -s /run "$TEST_HOME/links/run"
ln -s "$TEST_HOME/project" "$TEST_HOME/links/home-hop"
ln -s "$TEST_HOME/project/nested/deeper" "$TEST_HOME/links/project-hop"
git -C "$TEST_HOME/project" init -q

passed=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'ok %d - %s\n' "$passed" "$*"; }
launch() (
  cd "$TEST_HOME/project"
  env -i HOME="$TEST_HOME" PATH="$TEST_DIR/bin:/usr/bin:/bin" \
    GOYOLO_OS_RELEASE="$REPO_DIR/tests/fixtures/os-release" GOYOLO_QUIET=1 \
    GOYOLO_TOOLS="${TEST_TOOLS-}" GOYOLO_GOPATH_MODE="${TEST_GOPATH_MODE-rw}" \
    GOYOLO_MOUNTS="${TEST_MOUNTS-}" GRADLE_USER_HOME="${TEST_GRADLE_HOME-$TEST_HOME/.gradle}" \
    JAVA_HOME="${TEST_JAVA_HOME-}" GOROOT="${TEST_GOROOT-$TEST_HOME/toolchain}" \
    GOPATH="${TEST_GOPATH-$TEST_HOME/go}" GOCACHE="${TEST_GOCACHE-$TEST_HOME/cache}" \
    GOMODCACHE="${TEST_GOMODCACHE-$TEST_HOME/go/pkg/mod}" GOENV=off \
    DOCKER_TEST_LOG="$TEST_DIR/docker.log" DOCKER_TEST_IMAGE_STATUS="${TEST_IMAGE_STATUS-0}" \
    "$REPO_DIR/go-yolo.sh" "$@"
)
reject() {
  local output
  if output="$(launch --dry-run "$@" 2>&1)"; then fail "accepted unsafe mount: $*"; fi
  [[ $output == *'refusing to mount'* ]] || fail "unexpected error: $output"
}
dry_run() {
  local output line arg
  output="$(launch --dry-run "$@")" || fail "dry run failed: $*"
  ARGS=()
  # The launcher emits one safely shell-quoted argument per line.
  while IFS= read -r line; do
    eval "arg=$line"
    ARGS+=("$arg")
  done <<<"$output"
}
assert_mount() {
  local source=$1 target=$2 mode=$3 expected arg
  expected="type=bind,source=$source,target=$target"
  if [[ $mode == ro ]]; then expected+=,readonly; fi
  for arg in "${ARGS[@]}"; do [[ $arg != "$expected" ]] || return 0; done
  fail "missing mount: $expected"
}

TEST_GOPATH="$TEST_HOME" reject shell
TEST_TOOLS=gradle TEST_GRADLE_HOME="$TEST_HOME" reject shell
TEST_GOCACHE="$TEST_HOME" reject shell
TEST_GOPATH_MODE=modcache TEST_GOMODCACHE="$TEST_HOME" reject shell
TEST_GOROOT=/usr reject shell
TEST_GOPATH="$TEST_HOME/links/home" reject shell
TEST_TOOLS=gradle TEST_GRADLE_HOME="$TEST_HOME/links/home" reject shell
pass 'automatic mounts reject home directories, system roots, and symlink aliases'

for path in /run /dev /proc /sys /run/lock /dev/null /proc/self/status /sys/kernel /var/run; do
  if [[ -e $path ]]; then reject --mount "$path" shell; fi
done
reject --mount "$TEST_HOME/links/run" shell
TEST_GOCACHE=/proc reject shell
pass 'sensitive system trees and aliases are refused'

for path in /usr/bin/env /bin/bash /etc/passwd /etc/profile.d /usr/lib; do
  if [[ -e $path ]]; then reject --mount "$path" shell; fi
done
ln -s /usr/bin/env "$TEST_HOME/links/startup-executable"
reject --mount "$TEST_HOME/links/startup-executable" shell
# Exercise reserved paths that may not exist on this host without creating them.
(
  # shellcheck source=lib/mounts.sh
  source "$REPO_DIR/lib/mounts.sh"
  HOME_DIR=$TEST_HOME HOME_REAL=$TEST_HOME
  die() { exit 1; }
  for path in /opt/go-yolo /opt/go-yolo/agents /usr/local/bin/curl /usr/local/lib/python3 /etc/profile.d; do
    if (validate_mount_path "$path"); then fail "accepted reserved path: $path"; fi
  done
) || fail 'reserved path checks failed'
pass 'privileged executable and configuration mounts and aliases are refused'

# Test ownership decisions with synthetic mount metadata and stubbed chown/stat,
# so this regression needs neither root nor Docker and cannot change ownership.
(
  source <(sed -n '/^claim_dir() {/,/^}/p' "$REPO_DIR/entrypoint.sh")
  declare -A IS_MOUNT=([/]=1 ["$TEST_HOME/project"]=1 ["$TEST_HOME/project/nested/deeper"]=1) CHECKED=()
  GOYOLO_UID=1000 GOYOLO_GID=1000
  stat() { printf '0\n'; }
  chown() { printf '%s\n' "$2" >>"$TEST_DIR/chown.log"; }
  : >"$TEST_DIR/chown.log"
  claim_dir "$TEST_HOME/project"
  claim_dir "$TEST_HOME/project/nested"
  claim_dir "$TEST_HOME/project/nested/deeper"
  claim_dir "$TEST_HOME/links/project-hop"
  [[ ! -s $TEST_DIR/chown.log ]] || fail 'ownership repair entered a mount or symlink'
  claim_dir "$TEST_HOME"
  claim_dir "$TEST_HOME"
  [[ $(cat "$TEST_DIR/chown.log") == "$TEST_HOME" ]] || fail 'container parent was not claimed exactly once'
) || fail 'ownership checks failed'
pass 'ownership repair skips mount descendants and still claims container parents'

reject --mount "$TEST_HOME/links/home-hop/.." shell
dry_run --mount "$TEST_HOME/links/project-hop/.." shell
assert_mount "$TEST_HOME/project/nested" "$TEST_HOME/links" ro
pass 'sources resolve symlinks before parent-directory components'

ln -s "$TEST_HOME" "$TEST_HOME/.claude"
reject claude
pass 'agent configuration mounts use the common safety checks'

dry_run --mount "$TEST_HOME/with spaces" --mount "$TEST_HOME/.m2:ro" shell
assert_mount "$TEST_HOME/with spaces" "$TEST_HOME/with spaces" ro
assert_mount "$TEST_HOME/project" "$TEST_HOME/project" rw
assert_mount "$TEST_HOME/go" "$TEST_HOME/go" rw
assert_mount "$TEST_HOME/cache" "$TEST_HOME/cache" rw
TEST_TOOLS='mvn gradle' dry_run --mount "$TEST_HOME/.m2:ro" --mount "$TEST_HOME/.gradle:ro" shell
assert_mount "$TEST_HOME/.m2" "$TEST_HOME/.m2" ro
assert_mount "$TEST_HOME/.gradle" "$TEST_HOME/.gradle" ro
pass 'normal mounts, spaces, and read-only cache overrides are preserved'

TEST_TOOLS=java TEST_JAVA_HOME="$TEST_DIR/jdk" dry_run shell
assert_mount "$TEST_DIR/jdk" "$TEST_DIR/jdk" ro
assert_mount "$TEST_DIR/java-config" "$TEST_DIR/java-config" ro
output="$(TEST_TOOLS=java TEST_JAVA_HOME="$TEST_HOME" launch --dry-run shell 2>&1)"
[[ $output == *'not mounting java'* ]] || fail 'unsafe tool installation was not skipped with a warning'
pass 'Java dependency directories mount safely and unsupported installations are skipped'

mkdir -p "$TEST_HOME/datasets"
TEST_MOUNTS="$TEST_HOME/.m2"$'\n'"$TEST_HOME/datasets:rw" dry_run shell
assert_mount "$TEST_HOME/.m2" "$TEST_HOME/.m2" ro
assert_mount "$TEST_HOME/datasets" "$TEST_HOME/datasets" rw
pass 'GOYOLO_MOUNTS entries on separate lines are all mounted'

mkdir -p "$TEST_HOME/.config/git"
: >"$TEST_HOME/.config/git/config"
: >"$TEST_HOME/.config/git/credentials"
dry_run shell
assert_mount "$TEST_HOME/.config/git/config" "$TEST_HOME/.config/git/config" ro
for arg in "${ARGS[@]}"; do [[ $arg != *credentials* ]] || fail 'git credential store was mounted'; done
pass 'XDG git config is mounted read-only without the credential store'

rm -f "$TEST_HOME/.claude"
mkdir -p "$TEST_HOME/.claude"
dry_run claude 2>/dev/null
[[ ! -e $TEST_HOME/.claude.json ]] || fail 'dry run created a config file'
launch claude 2>/dev/null
[[ $(cat "$TEST_HOME/.claude.json") == '{}' ]] || fail 'missing .claude.json was not created'
[[ $(stat -c %a "$TEST_HOME/.claude.json") == 600 ]] || fail '.claude.json is not mode 600'
dry_run claude
assert_mount "$TEST_HOME/.claude.json" "$TEST_HOME/.claude.json" rw
pass 'a missing JSON agent config file is created and mounted'

# tmux is only chosen on a terminal; script(1) provides one.
if command -v script >/dev/null 2>&1; then
  tmux_env() {
    local cmd
    printf -v cmd '%q ' "$@"
    TEST_CMD=$cmd script -qec 'bash -c "$TEST_CMD"' /dev/null </dev/null \
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
    (cd "$TEST_HOME/project" && TEST_CMD=$cmd script -qec 'bash -c "$TEST_CMD"' /dev/null </dev/null | tr -d '\r') || true
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

# launch_in DIR ARGS... — like launch, but from DIR; prints stderr, never fails.
launch_in() (
  cd "$1" && shift
  env -i HOME="$TEST_HOME" PATH="$TEST_DIR/bin:/usr/bin:/bin" GOYOLO_TOOLS= GOENV=off \
    GOYOLO_OS_RELEASE="$REPO_DIR/tests/fixtures/os-release" GOYOLO_QUIET=1 \
    DOCKER_TEST_LOG="$TEST_DIR/docker.log" GOROOT="$TEST_HOME/toolchain" GOPATH="$TEST_HOME/go" \
    GOCACHE="$TEST_HOME/cache" GOMODCACHE="$TEST_HOME/go/pkg/mod" \
    "$REPO_DIR/go-yolo.sh" "$@" 2>&1 >/dev/null || true
)
mkdir -p "$TEST_DIR/not-a-repo"
[[ $(launch_in "$TEST_DIR/not-a-repo" --dry-run shell) == *'not inside a git repository'* ]] \
  || fail 'ran outside a git repository'
[[ $(launch_in "$TEST_HOME/project/nested" --dry-run shell) == *"run go-yolo from the repository's root directory: cd $TEST_HOME/project"* ]] \
  || fail 'ran from a repository subdirectory'
pass 'go-yolo runs only from a git repository root'

STATE="$TEST_HOME/project/.go-yolo"
rm -rf -- "$STATE"   # earlier real runs created it
dry_run shell 2>/dev/null
[[ ! -e $STATE ]] || fail 'dry run created .go-yolo'
for arg in "${ARGS[@]}"; do [[ $arg != "type=tmpfs,destination=$STATE,tmpfs-mode=0555" ]] || break; done
[[ $arg == "type=tmpfs,destination=$STATE,tmpfs-mode=0555" ]] || fail '.go-yolo is not covered by a tmpfs'
launch claude 2>/dev/null
[[ -d $STATE && $(stat -c %a "$STATE") == 700 ]] || fail '.go-yolo was not created with mode 700'
[[ $(cat "$STATE/.gitignore") == '*' ]] || fail '.go-yolo/.gitignore does not ignore everything'
[[ -z $(git -C "$TEST_HOME/project" status --porcelain --ignored=no) ]] || fail 'git sees .go-yolo'
pass '.go-yolo is created on a real run, ignored by git and hidden from the container'

mv "$STATE" "$STATE.real"
ln -s "$STATE.real" "$STATE"
[[ $(launch_in "$TEST_HOME/project" --dry-run shell) == *'is a symlink'* ]] || fail 'accepted a .go-yolo symlink'
rm "$STATE" && mv "$STATE.real" "$STATE"
git -C "$TEST_HOME/project" add -f .go-yolo/.gitignore
[[ $(launch_in "$TEST_HOME/project" --dry-run shell) == *'tracks files in .go-yolo/ (.go-yolo/.gitignore)'* ]] \
  || fail 'accepted a tracked .go-yolo'
git -C "$TEST_HOME/project" rm -q --cached .go-yolo/.gitignore
pass 'a symlinked or git-tracked .go-yolo is refused'

: >"$TEST_HOME/project/Dockerfile"
[[ $(launch_in "$TEST_HOME/project" shell) == *'add .go-yolo/ to its .dockerignore'* ]] || fail 'no .dockerignore warning'
[[ $(launch_in "$TEST_HOME/project" shell) != *'.dockerignore'* ]] || fail '.dockerignore warning repeated'
rm -f "$STATE/warned-dockerignore"
printf '.go-yolo/\n' >"$TEST_HOME/project/.dockerignore"
[[ $(launch_in "$TEST_HOME/project" shell) != *'.dockerignore'* ]] || fail 'warned despite .dockerignore'
rm -f "$TEST_HOME/project/Dockerfile" "$TEST_HOME/project/.dockerignore"
pass 'a Dockerfile without .go-yolo/ in .dockerignore gets a one-time warning'

launch --rebuild shell
grep -qxF -- --pull "$TEST_DIR/docker.log" || fail 'rebuild did not pull the base'
grep -qxF -- --no-cache "$TEST_DIR/docker.log" || fail 'rebuild did not disable caching'
cp /dev/null "$TEST_DIR/docker.log"
TEST_IMAGE_STATUS=1 launch shell
if grep -qxE -- '--no-cache|--pull' "$TEST_DIR/docker.log"; then fail 'ordinary build disabled caching'; fi
grep -qxF build "$TEST_DIR/docker.log" || fail 'ordinary build was not exercised'
cp /dev/null "$TEST_DIR/docker.log"
launch shell
if grep -qxF build "$TEST_DIR/docker.log"; then fail 'existing image was rebuilt'; fi
pass 'explicit rebuilds refresh packages; ordinary builds and image reuse keep caching'

printf 'Passed %d launcher regression groups.\n' "$passed"
