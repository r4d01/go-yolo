# shellcheck shell=bash
# Shared setup for the test files (tests/test-*.sh): a fresh fixture host and project in a temp
# directory, stub commands, and the helpers. Sourced first by every test file, so each file
# starts from scratch. See tests/README.md.
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d /tmp/go-yolo-tests.XXXXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
TEST_HOME="$TEST_DIR/home"
mkdir -p "$TEST_DIR/bin" "$TEST_HOME"/{bin,project/nested/deeper,go/pkg/mod,cache,toolchain,links,.gradle,.m2} \
  "$TEST_HOME/with spaces"
cp "$REPO_DIR/tests/fixtures/"{go,docker,apt-cache,dpkg-query,dpkg,pkg-config} "$TEST_DIR/bin/"
chmod +x "$TEST_DIR/bin/"{go,docker,apt-cache,dpkg-query,dpkg,pkg-config}
cp "$REPO_DIR/tests/fixtures/apt-policy" "$TEST_DIR/apt-policy"   # tests may add packages
mkdir -p "$TEST_DIR/ca/corp"
printf 'not really a certificate\n' >"$TEST_DIR/ca/corp/root.crt"
ln -s "$TEST_HOME" "$TEST_HOME/links/home"
ln -s /run "$TEST_HOME/links/run"
ln -s "$TEST_HOME/project" "$TEST_HOME/links/home-hop"
ln -s "$TEST_HOME/project/nested/deeper" "$TEST_HOME/links/project-hop"
git -C "$TEST_HOME/project" init -q

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
# launch_command ARGS... — set LAUNCH_COMMAND to the go-yolo command a test runs: a clean
# environment (env -i) pointing at the stubs, plus TEST_ENV.
launch_command() {
  LAUNCH_COMMAND=(env -i HOME="$TEST_HOME" PATH="$TEST_DIR/bin:/usr/bin:/bin"
    GOYOLO_OS_RELEASE="$REPO_DIR/tests/fixtures/os-release" GOYOLO_QUIET=1
    GOPROXY=https://proxy.example.com,direct GOYOLO_JVM_DIR="$TEST_DIR/jvm"
    GOYOLO_MOUNTS="${TEST_MOUNTS-}" GRADLE_USER_HOME="${TEST_GRADLE_HOME-$TEST_HOME/.gradle}"
    JAVA_HOME="${TEST_JAVA_HOME-}" GOROOT="${TEST_GOROOT-$TEST_HOME/toolchain}"
    GOPATH="${TEST_GOPATH-$TEST_HOME/go}" GOCACHE="${TEST_GOCACHE-$TEST_HOME/cache}"
    GOMODCACHE="${TEST_GOMODCACHE-$TEST_HOME/go/pkg/mod}" GOENV=off
    DOCKER_TEST_LOG="$TEST_DIR/docker.log" DOCKER_TEST_IMAGE_STATUS="${TEST_IMAGE_STATUS-0}"
    TZ=Europe/Prague GOYOLO_CA_DIR="$TEST_DIR/ca" APT_POLICY_FIXTURE="$TEST_DIR/apt-policy"
    DPKG_HOST_FIXTURE="${TEST_DPKG_HOST-}" DPKG_BASE_FIXTURE="$REPO_DIR/tests/fixtures/dpkg-base"
    DPKG_S_FIXTURE="$TEST_DIR/dpkg-S" PC_PATH_FIXTURE="$TEST_DIR/pc"
    DOCKER_TEST_IMAGES="$TEST_DIR/images" DOCKER_TEST_VOLUMES="$TEST_DIR/volumes"
    GOYOLO_LOCALES_SUPPORTED="$REPO_DIR/tests/fixtures/locales-supported"
    "${TEST_ENV[@]}" "$REPO_DIR/go-yolo.sh" "$@")
}
launch() (
  cd "${LAUNCH_DIR:-$TEST_HOME/project}"
  launch_command "$@"
  "${LAUNCH_COMMAND[@]}"
)
# in_terminal ANSWER... -- ARGS... — launch go-yolo ARGS in a terminal (script(1)), typing the
# ANSWERs (one line each); print what it shows. Gives up after 60 seconds.
in_terminal() {
  local answers=() command
  while (($#)) && [[ $1 != -- ]]; do answers+=("$1"); shift; done
  shift
  launch_command "$@"
  printf -v command '%q ' "${LAUNCH_COMMAND[@]}"
  (cd "${LAUNCH_DIR:-$TEST_HOME/project}" && printf '%s\n' "${answers[@]}" \
     | TEST_CMD=$command timeout 60 script -qec 'bash -c "$TEST_CMD"' /dev/null) | tr -d '\r' || true
}
TEST_ENV=()   # extra VAR=value settings for launch
reject() {
  local output
  if output="$(launch --dry-run "$@" 2>&1)"; then fail "accepted unsafe mount: $*"; fi
  [[ $output == *'refusing to '* ]] || fail "unexpected error: $output"
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
# has_arg VALUE — true if the last dry run's docker command has VALUE as one argument.
has_arg() {
  local arg
  for arg in "${ARGS[@]}"; do [[ $arg != "$1" ]] || return 0; done
  return 1
}
assert_mount() {
  local source=$1 target=$2 mode=$3 expected arg
  expected="type=bind,source=$source,target=$target"
  if [[ $mode == ro ]]; then expected+=,readonly; fi
  for arg in "${ARGS[@]}"; do [[ $arg != "$expected" ]] || return 0; done
  fail "missing mount: $expected"
}
# launch_in DIR ARGS... — like launch, but from DIR; prints stderr, never fails.
launch_in() {
  LAUNCH_DIR=$1 launch "${@:2}" 2>&1 >/dev/null || true
}
STATE="$TEST_HOME/project/.go-yolo"   # the fixture project's .go-yolo
# expect_plan TEXT — fail unless the last captured plan_text contains TEXT.
expect_plan() {
  [[ $plan_text == *"$1"* ]] || fail "plan lacks '$1':"$'\n'"$plan_text"
}
# removed_items — the images and volumes the docker stub was asked to remove, one per line.
removed_items() {
  # The log has one "CALL" line per call, then one argument per line.
  awk '$0 == "CALL" { flush(); n = 0; next } { arg[++n] = $0 } END { flush() }
       function flush() {
         if (arg[1] == "rmi") print arg[3]
         if (arg[1] == "volume" && arg[2] == "rm") print "volume " arg[4]
         split("", arg)
       }' "$TEST_DIR/docker.log"
}
