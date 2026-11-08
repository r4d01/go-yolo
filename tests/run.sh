#!/usr/bin/env bash
# Launcher regressions: no Docker daemon, Go installation, or host config changes needed.
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d /tmp/go-yolo-tests.XXXXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
TEST_HOME="$TEST_DIR/home"
mkdir -p "$TEST_DIR/bin" "$TEST_HOME"/{bin,project/nested/deeper,go/pkg/mod,cache,toolchain,links,.gradle,.m2} \
  "$TEST_DIR/jdk/bin" "$TEST_DIR/java-config" "$TEST_HOME/with spaces"
cp "$REPO_DIR/tests/fixtures/"{go,docker,apt-cache,dpkg-query} "$TEST_DIR/bin/"
chmod +x "$TEST_DIR/bin/"{go,docker,apt-cache,dpkg-query}
mkdir -p "$TEST_DIR/ca/corp"
printf 'not really a certificate\n' >"$TEST_DIR/ca/corp/root.crt"
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
  cd "${LAUNCH_DIR:-$TEST_HOME/project}"
  env -i HOME="$TEST_HOME" PATH="$TEST_DIR/bin:/usr/bin:/bin" \
    GOYOLO_OS_RELEASE="$REPO_DIR/tests/fixtures/os-release" GOYOLO_QUIET=1 \
    GOYOLO_TOOLS="${TEST_TOOLS-}" GOYOLO_GOPATH_MODE="${TEST_GOPATH_MODE-rw}" \
    GOYOLO_MOUNTS="${TEST_MOUNTS-}" GRADLE_USER_HOME="${TEST_GRADLE_HOME-$TEST_HOME/.gradle}" \
    JAVA_HOME="${TEST_JAVA_HOME-}" GOROOT="${TEST_GOROOT-$TEST_HOME/toolchain}" \
    GOPATH="${TEST_GOPATH-$TEST_HOME/go}" GOCACHE="${TEST_GOCACHE-$TEST_HOME/cache}" \
    GOMODCACHE="${TEST_GOMODCACHE-$TEST_HOME/go/pkg/mod}" GOENV=off \
    DOCKER_TEST_LOG="$TEST_DIR/docker.log" DOCKER_TEST_IMAGE_STATUS="${TEST_IMAGE_STATUS-0}" \
    TZ=Europe/Prague GOYOLO_CA_DIR="$TEST_DIR/ca" APT_POLICY_FIXTURE="$REPO_DIR/tests/fixtures/apt-policy" \
    DPKG_HOST_FIXTURE="${TEST_DPKG_HOST-}" DPKG_BASE_FIXTURE="$REPO_DIR/tests/fixtures/dpkg-base" \
    DOCKER_TEST_IMAGES="$TEST_DIR/images" \
    "${TEST_ENV[@]}" "$REPO_DIR/go-yolo.sh" "$@"
)
TEST_ENV=()   # extra VAR=value settings for launch
reject() {
  local output
  if output="$(launch --dry-run "$@" 2>&1)"; then fail "accepted unsafe mount: $*"; fi
  [[ $output == *'refusing to mount'* ]] || fail "unexpected error: $output"
}
dry_run() {
  local output line arg
  output="$(launch --dry-run "$@" 2>"$TEST_DIR/stderr")" || fail "dry run failed: $*: $(cat "$TEST_DIR/stderr")"
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
launch --yes claude 2>/dev/null
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
launch_in() {
  LAUNCH_DIR=$1 launch "${@:2}" 2>&1 >/dev/null || true
}
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
launch --yes claude 2>/dev/null
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
[[ $(launch_in "$TEST_HOME/project" --yes shell) == *'add .go-yolo/ to its .dockerignore'* ]] || fail 'no .dockerignore warning'
[[ $(launch_in "$TEST_HOME/project" --yes shell) != *'.dockerignore'* ]] || fail '.dockerignore warning repeated'
rm -f "$STATE/warned-dockerignore"
printf '.go-yolo/\n' >"$TEST_HOME/project/.dockerignore"
[[ $(launch_in "$TEST_HOME/project" --yes shell) != *'.dockerignore'* ]] || fail 'warned despite .dockerignore'
rm -f "$TEST_HOME/project/Dockerfile" "$TEST_HOME/project/.dockerignore"
pass 'a Dockerfile without .go-yolo/ in .dockerignore gets a one-time warning'

# --- The plan ---------------------------------------------------------------

rm -rf -- "$STATE"
mkdir -p "$STATE"
CONFIG="$STATE/config"
cat >"$CONFIG" <<'CONF'
# packages: current, host behind the archive, not on the host, third-party, backports, unknown
extra package libfoo-dev
extra package libold-dev
extra package protobuf-compiler
extra package vendor-tool
extra package libbpo-dev
extra package no-such-package
extra package libx11-dev
exclude package libx11-dev
extra env API_TOKEN
extra env NOT_SET_ANYWHERE
CONF
TEST_ENV=(API_TOKEN=s3cr3t-value HTTPS_PROXY=http://user:pw@proxy.example:3128 NO_PROXY=localhost)

plan_text="$(launch --dry-run shell 2>&1 >/dev/null)"
expect_plan() {
  [[ $plan_text == *"$1"* ]] || fail "plan lacks '$1':"$'\n'"$plan_text"
}
expect_plan 'package  libfoo-dev=1.0-1 (extra)'
expect_plan "package  libold-dev=1.0-1+deb13u1 (extra)  ⚠ the host has 1.0-1, an older version"
expect_plan 'protobuf-compiler=3.21.12-11 (extra)  ⚠ not installed on the host'
expect_plan "vendor-tool=2.0-1 (extra)  ⚠ not installed: the host's version isn't in the debian archive"
expect_plan "libbpo-dev=5.0-1~bpo13+1 (extra)  ⚠ not installed: the host's version isn't in the debian archive"
expect_plan 'no-such-package (extra)  ⚠ no such apt package'
expect_plan 'libx11-dev (extra)  excluded in .go-yolo/config'
expect_plan "cert     $TEST_DIR/ca/corp/root.crt"
expect_plan 'env      TZ=Europe/Prague'
expect_plan 'env      NO_PROXY=localhost'
expect_plan 'env      HTTPS_PROXY  not passed: looks like a secret (to pass it: extra env HTTPS_PROXY)'
expect_plan 'env      API_TOKEN (extra)  value not shown'
expect_plan 'NOT_SET_ANYWHERE (extra)  not passed: not set on the host'
[[ $plan_text != *s3cr3t* && $plan_text != *user:pw* ]] || fail 'the plan shows a secret value'
[[ ! -e $STATE/plan ]] || fail 'a dry run confirmed the plan'
pass 'the plan resolves packages, certificates and env, and never shows secrets'

output="$(launch shell 2>&1)" && fail 'an unconfirmed plan was used without a terminal'
[[ $output == *'run go-yolo in a terminal to confirm it, or pass --yes'* ]] || fail "unexpected error: $output"
[[ ! -e $STATE/plan ]] || fail 'the plan was saved without confirmation'
cp /dev/null "$TEST_DIR/docker.log"
TEST_IMAGE_STATUS=1 launch --yes shell 2>/dev/null
[[ -f $STATE/plan ]] || fail '--yes did not save the plan'
! grep -q s3cr3t "$STATE/plan" || fail 'the saved plan holds a secret value'
pass 'an unconfirmed plan needs a terminal or --yes'

dockerfile="$(cat "$STATE/build/Dockerfile")"
[[ $dockerfile == *'FROM go-yolo-base:debian-trixie-'* ]] || fail 'project image is not built FROM the base'
for pinned in libfoo-dev=1.0-1 libold-dev=1.0-1+deb13u1 protobuf-compiler=3.21.12-11; do
  [[ $dockerfile == *"      $pinned \\"* ]] || fail "Dockerfile does not install $pinned"
done
for left_out in vendor-tool libbpo-dev no-such-package libx11-dev; do
  [[ $dockerfile != *"$left_out"* ]] || fail "Dockerfile installs $left_out"
done
[[ $dockerfile != *allow-downgrades* ]] || fail 'Dockerfile allows downgrades'
[[ $dockerfile == *'COPY files/ /'* && -f $STATE/build/files$TEST_DIR/ca/corp/root.crt ]] \
  || fail 'the CA certificate is not staged at its host path'
grep -qxF -- "$STATE/build/Dockerfile" "$TEST_DIR/docker.log" || fail 'the project image was not built'
pass 'the project image installs exactly the planned packages, never downgrading, plus the CAs'

[[ -z $(launch --yes shell 2>&1 >/dev/null) ]] || fail 'an unchanged plan was shown again'
dry_run shell
image_before=${ARGS[-1]}
for arg in "${ARGS[@]}"; do [[ $arg != *s3cr3t* ]] || fail 'a secret value is on the docker command line'; done
printf '%s\n' "${ARGS[@]}" | grep -qxF API_TOKEN || fail 'API_TOKEN is not passed by name'
TEST_ENV=(API_TOKEN=rotated HTTPS_PROXY=http://user:pw@proxy.example:3128 NO_PROXY=localhost)
plan_text="$(launch --dry-run shell 2>&1 >/dev/null)"
expect_plan '~ env      API_TOKEN (extra)  value not shown; value changed'
dry_run shell
[[ ${ARGS[-1]} == "$image_before" ]] || fail 'a runtime-only change changed the image'
printf 'extra package libfoo-dev\n' >"$CONFIG"
plan_text="$(launch --dry-run shell 2>&1 >/dev/null)"
expect_plan '- package  libold-dev'
dry_run shell
[[ ${ARGS[-1]} != "$image_before" ]] || fail 'a package change kept the image'
pass 'changes are shown as a diff; only build-time changes change the image'

printf 'extra package ok\ninstall package nope\n' >"$CONFIG"
[[ $(launch_in "$TEST_HOME/project" --dry-run shell) == *"$CONFIG:2: unknown 'install' (use extra or exclude)"* ]] \
  || fail 'a bad config line was accepted'
printf 'extra thing x\n' >"$CONFIG"
[[ $(launch_in "$TEST_HOME/project" --dry-run shell) == *"unknown kind 'thing'"* ]] || fail 'a bad kind was accepted'
rm -f "$CONFIG" "$STATE/plan"
TEST_ENV=()
pass '.go-yolo/config errors name the file and line'

# Base image packages vs the host: zlib1g is older on the host, tzdata newer; libc6 is the
# same, tini isn't on the host, "removed" was removed from the host (status rc).
TEST_DPKG_HOST="$REPO_DIR/tests/fixtures/dpkg-host"
plan_text="$(launch --dry-run shell 2>&1 >/dev/null)"
expect_plan 'parity   zlib1g=1:1.3-1+deb13u1  ⚠ the base image has this newer version, the host has 1:1.3-1 (apt upgrade the host to match)'
expect_plan 'parity   tzdata=2026e-1  ⚠ the base image has this older version, the host has 2026f-1 (go-yolo.sh --rebuild updates the base image)'
for name in libc6 tini removed only-on-host; do
  [[ $plan_text != *"parity   $name="* ]] || fail "parity warning for $name"
done
pass 'base image packages whose version differs from the host are warnings in the plan'

# First run: the base image doesn't exist yet, so the comparison comes after it is built, as a
# change to the plan that is confirmed before the project image is built.
rm -f "$STATE/plan" "$TEST_DIR/docker.log.built"
cp /dev/null "$TEST_DIR/docker.log"
output="$(TEST_IMAGE_STATUS=built-on-build launch --yes shell 2>&1 >/dev/null)"
[[ $output == *'plan for '*'(new;'* ]] || fail "first run did not show the new plan: $output"
[[ $output == *'+ parity   zlib1g=1:1.3-1+deb13u1'* ]] || fail "the base comparison was not shown as a change: $output"
grep -q '^parity	host	check	zlib1g	' "$STATE/plan" || fail 'the confirmed plan lacks the base comparison'
[[ $(grep -c '^build$' "$TEST_DIR/docker.log") == 2 ]] || fail 'expected a base and a project build'
rm -f "$TEST_DIR/docker.log.built" "$STATE/plan"
TEST_DPKG_HOST=""
pass 'on a first run the base comparison is confirmed before the project image is built'

# --- --prune ----------------------------------------------------------------

# Images: the current base (and its alias), an older base, a project's image for its confirmed
# plan and for an older one, a project that is gone, and an image from before go-yolo-base.
base_tag="go-yolo-base:debian-trixie-$(REPO_DIR=$REPO_DIR; source "$REPO_DIR/lib/image.sh"; compute_hash)"
mkdir -p "$TEST_DIR/projects/kept/.go-yolo"
printf '# confirmed: today\nbase\thost\timage\t%s\t-\t-\n' "$base_tag" >"$TEST_DIR/projects/kept/.go-yolo/plan"
kept_hash="$(source "$REPO_DIR/lib/plan.sh"; confirmed_plan_hash "$TEST_DIR/projects/kept")"
{
  printf '%s\tid1\t1 hour ago\t2GB\t\t\n' "$base_tag" go-yolo-base:debian-trixie
  printf 'go-yolo-base:debian-trixie-0ld0ba5e\tid0\t2 days ago\t2GB\t\t\n'
  printf 'go-yolo:kept-1-%s\tid2\t1 hour ago\t2GB\t%s\t%s\n' "$kept_hash" "$TEST_DIR/projects/kept" "$kept_hash"
  printf 'go-yolo:kept-1-0ldp1an0\tid3\t2 days ago\t2GB\t%s\t0ldp1an0\n' "$TEST_DIR/projects/kept"
  printf 'go-yolo:gone-2-11111111\tid4\t3 days ago\t2GB\t%s\t11111111\n' "$TEST_DIR/projects/gone"
  printf 'go-yolo:debian-trixie-5ebfa50a\tid5\t4 days ago\t2GB\t\t\n'
} >"$TEST_DIR/images"
current_tags=("$base_tag" go-yolo-base:debian-trixie "go-yolo:kept-1-$kept_hash")
stale_tags=(go-yolo-base:debian-trixie-0ld0ba5e go-yolo:kept-1-0ldp1an0 go-yolo:gone-2-11111111 go-yolo:debian-trixie-5ebfa50a)

cp /dev/null "$TEST_DIR/docker.log"
output="$(launch --prune 2>&1)"
for tag in "${current_tags[@]}"; do [[ $output == *"✓ $tag "* ]] || fail "$tag not listed as current: $output"; done
for tag in "${stale_tags[@]}"; do [[ $output == *"✗ $tag "* ]] || fail "$tag not listed as stale: $output"; done
[[ $output == *'an older plan of'* && $output == *'project is gone'* && $output == *'before go-yolo-base'* ]] \
  || fail "--prune does not say why images are stale: $output"
! grep -qxF rmi "$TEST_DIR/docker.log" || fail '--prune removed images without a terminal or --yes'
pass '--prune lists current and stale images with the reason, and only lists without a terminal'

mkdir -p "$TEST_HOME/.cache/go-yolo"
: >"$TEST_HOME/.cache/go-yolo/base-packages-gone"
cp /dev/null "$TEST_DIR/docker.log"
TEST_IMAGE_STATUS=1 launch --prune --yes >/dev/null 2>&1
removed="$(grep -A2 -xF rmi "$TEST_DIR/docker.log" | grep -v -e '^rmi$' -e '^--$' -e '^CALL$')"
[[ $removed == "$(printf '%s\n' "${stale_tags[@]}")" ]] || fail "--prune --yes removed: $removed"
[[ ! -e $TEST_HOME/.cache/go-yolo/base-packages-gone ]] || fail 'the package list of a removed base image was kept'
pass '--prune --yes removes exactly the stale images and their cached package lists'

# --- --parity ---------------------------------------------------------------

rm -rf -- "$STATE"
mkdir -p "$STATE"
printf 'extra env API_TOKEN\n' >"$STATE/config"
TEST_ENV=(DOCKER_TEST_RUN_SCRIPT=1 API_TOKEN=s3cr3t-value)
output="$(launch --yes --parity 2>&1)" || fail "--parity found differences where there are none: $output"
for probe in user home directory umask architecture glibc 'time zone' 'tool git' 'env TZ' \
  "cert $TEST_DIR/ca/corp/root.crt"; do
  [[ $output == *"✓ $probe "* ]] || fail "--parity lacks a matching '$probe' probe: $output"
done
[[ $output == *'✓ env API_TOKEN'*'sha256:'* && $output != *s3cr3t* ]] || fail "--parity shows a secret: $output"
[[ $output == *'all '*' probes match'* ]] || fail "--parity did not sum up: $output"

TEST_ENV+=(DOCKER_TEST_PARITY_SED='s/^umask\t.*/umask\t0077/')
if output="$(launch --yes --parity 2>&1)"; then fail '--parity exited 0 despite a difference'; fi
[[ $output == *'✗ umask'*'host: '*'container: 0077'* && $output == *'1 of '*' probes differ'* ]] \
  || fail "--parity did not show the difference: $output"
[[ $(launch_in "$TEST_HOME/project" --parity claude) == *"don't name an agent"* ]] || fail '--parity accepted an agent'
rm -rf -- "$STATE"
TEST_ENV=()
pass '--parity runs the same probes on both sides, shows differences and exits 1 for them'

# The prompt needs a terminal; script(1) provides one and feeds it our answers.
if command -v script >/dev/null 2>&1; then
  answer_prompt() {
    local cmd
    printf -v cmd '%q ' env -i HOME="$TEST_HOME" PATH="$TEST_DIR/bin:/usr/bin:/bin" TERM=dumb \
      GOYOLO_TOOLS= GOENV=off GOYOLO_QUIET=1 GOYOLO_OS_RELEASE="$REPO_DIR/tests/fixtures/os-release" \
      GOROOT="$TEST_HOME/toolchain" GOPATH="$TEST_HOME/go" GOCACHE="$TEST_HOME/cache" \
      GOMODCACHE="$TEST_HOME/go/pkg/mod" DOCKER_TEST_LOG="$TEST_DIR/docker.log" TZ=UTC \
      GOYOLO_CA_DIR="$TEST_DIR/ca" "$REPO_DIR/go-yolo.sh" shell -c true
    (cd "$TEST_HOME/project" && printf '%s\n' "$@" | TEST_CMD=$cmd script -qec 'bash -c "$TEST_CMD"' /dev/null) \
      | tr -d '\r' || true
  }
  output="$(answer_prompt '?' n)"
  [[ $output == *'y: build with this plan'* && $output == *'aborted; nothing was built'* ]] \
    || fail "the prompt did not explain itself and abort: $output"
  [[ ! -e $STATE/plan ]] || fail 'the plan was saved after answering n'
  answer_prompt y >/dev/null
  grep -q 'TZ	UTC' "$STATE/plan" || fail 'the plan was not saved after answering y'
  pass 'the plan prompt explains its choices, aborts on n and saves on y'

  # --prune [p]ick with fzf (a stub that picks the lines containing $FZF_TEST_PICK).
  cp "$REPO_DIR/tests/fixtures/fzf" "$TEST_DIR/bin/fzf"
  printf -v cmd '%q ' env -i HOME="$TEST_HOME" PATH="$TEST_DIR/bin:/usr/bin:/bin" TERM=dumb \
    GOYOLO_OS_RELEASE="$REPO_DIR/tests/fixtures/os-release" DOCKER_TEST_LOG="$TEST_DIR/docker.log" \
    DOCKER_TEST_IMAGES="$TEST_DIR/images" FZF_TEST_PICK="$kept_hash" "$REPO_DIR/go-yolo.sh" --prune
  cp /dev/null "$TEST_DIR/docker.log"
  printf 'p\n' | TEST_CMD=$cmd script -qec 'bash -c "$TEST_CMD"' /dev/null >/dev/null
  removed="$(grep -A2 -xF rmi "$TEST_DIR/docker.log" | grep -v -e '^rmi$' -e '^--$' -e '^CALL$')"
  [[ $removed == "go-yolo:kept-1-$kept_hash" ]] || fail "[p]ick removed: $removed"
  rm -f "$TEST_DIR/bin/fzf"
  pass '--prune [p]ick removes exactly the picked images, current ones included'
fi

launch --yes --rebuild shell
grep -qxF -- --pull "$TEST_DIR/docker.log" || fail 'rebuild did not pull the base'
grep -qxF -- --no-cache "$TEST_DIR/docker.log" || fail 'rebuild did not disable caching'
cp /dev/null "$TEST_DIR/docker.log"
TEST_IMAGE_STATUS=1 launch --yes shell
if grep -qxE -- '--no-cache|--pull' "$TEST_DIR/docker.log"; then fail 'ordinary build disabled caching'; fi
grep -qxF build "$TEST_DIR/docker.log" || fail 'ordinary build was not exercised'
cp /dev/null "$TEST_DIR/docker.log"
launch --yes shell
if grep -qxF build "$TEST_DIR/docker.log"; then fail 'existing image was rebuilt'; fi
pass 'explicit rebuilds refresh packages; ordinary builds and image reuse keep caching'

printf 'Passed %d launcher regression groups.\n' "$passed"
