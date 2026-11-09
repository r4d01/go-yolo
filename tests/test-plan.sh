#!/usr/bin/env bash
# The plan: packages, certificates, env, confirmation, base comparison, the prompt.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

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

plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan 'package   libfoo-dev=1.0-1 [extra]'
expect_plan "package   libold-dev=1.0-1+deb13u1 [extra]  ⚠ the host has 1.0-1, an older version"
expect_plan 'protobuf-compiler=3.21.12-11 [extra]  ⚠ not installed on the host'
expect_plan "vendor-tool=2.0-1 [extra]  ⚠ not installed: the host's version isn't in the debian archive"
expect_plan "libbpo-dev=5.0-1~bpo13+1 [extra]  ⚠ not installed: the host's version isn't in the debian archive"
expect_plan 'no-such-package [extra]  ⚠ no such apt package'
[[ $plan_text != *libx11-dev* ]] || fail 'an unpicked package is in the plan'
expect_plan "cert      $TEST_DIR/ca/corp/root.crt"
expect_plan 'env       TZ=Europe/Prague'
expect_plan 'env       NO_PROXY=localhost'
[[ $plan_text != *HTTPS_PROXY* ]] || fail 'a secret-looking proxy was picked without asking for it'
expect_plan 'env       API_TOKEN [extra]  value not shown'
expect_plan 'NOT_SET_ANYWHERE [extra]  ⚠ picked, but not set on the host: not passed'
[[ $plan_text != *s3cr3t* && $plan_text != *user:pw* ]] || fail 'the plan shows a secret value'
[[ ! -e $STATE/plan ]] || fail 'a dry run confirmed the plan'
pass 'the plan resolves packages, certificates and env, and never shows secrets'

output="$(launch shell 2>&1)" && fail 'a project without a setup ran without a terminal'
[[ $output == *'no setup yet: run go-yolo.sh --setup in a terminal (or pass --yes'* ]] || fail "unexpected error: $output"
[[ ! -e $STATE/plan ]] || fail 'the plan was saved without a setup'
cp /dev/null "$TEST_DIR/docker.log"
TEST_IMAGE_STATUS=1 launch --yes shell 2>/dev/null
[[ -f $STATE/plan ]] || fail '--yes did not save the plan'
! grep -q s3cr3t "$STATE/plan" || fail 'the saved plan holds a secret value'
pass 'without a terminal, a project needs a setup and a confirmed plan, or --yes'

# The --yes run converted the old config: its extras are picks, its exclude unpicked a candidate.
[[ -f $CONFIG.old ]] || fail 'the old config was not kept as config.old'
for picked_line in 'image  host     package    libfoo-dev' 'image  host     package    libold-dev' 'env    host     env        API_TOKEN'; do
  grep -qxF "$picked_line" "$CONFIG" || fail "the converted config lacks '$picked_line': $(cat "$CONFIG")"
done
grep -q libx11-dev "$CONFIG" && fail 'an excluded package was picked'
pass 'an old config is converted once: extras become picks, excludes unpick, the old file is kept'

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
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan '~ env       API_TOKEN [extra]  value not shown; value changed'
dry_run shell
[[ ${ARGS[-1]} == "$image_before" ]] || fail 'a runtime-only change changed the image'
printf 'extra package libfoo-dev\n' >"$CONFIG"
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan '- package   libold-dev'
dry_run shell
[[ ${ARGS[-1]} != "$image_before" ]] || fail 'a package change kept the image'
pass 'changes are shown as a diff; only build-time changes change the image'

printf 'image host package ok\ninstall host package nope\n' >"$CONFIG"
[[ $(launch_in "$TEST_HOME/project" --dry-run shell) == *"$CONFIG:2: unknown mode 'install' (use one of: image copy mount cache env)"* ]] \
  || fail 'a bad config line was accepted'
printf 'image nosuch thing x\n' >"$CONFIG"
[[ $(launch_in "$TEST_HOME/project" --dry-run shell) == *"unknown catalog 'nosuch'"* ]] || fail 'a bad catalog was accepted'
rm -f "$CONFIG" "$STATE/plan"
TEST_ENV=()
pass '.go-yolo/config errors name the file and line'

# The default plan view: one line per group, then every warning in full.
rm -rf -- "$STATE"
mkdir -p "$STATE"
printf 'image host package libfoo-dev\nimage host package libold-dev\nimage host cert %s\nenv host tz -\n' \
  "$TEST_DIR/ca/corp/root.crt" >"$CONFIG"
summary="$(launch --dry-run shell 2>&1 >/dev/null)"
[[ $summary == *'  host:  base '*'1 cert'*'1 env'* && $summary == *'  extra: 2 packages'* ]] \
  || fail "the summary lacks the group lines: $summary"
[[ $summary == *'  warnings:'*'package   libold-dev=1.0-1+deb13u1 [extra]  ⚠ the host has 1.0-1'* ]] \
  || fail "the summary lacks a warning: $summary"
[[ $summary != *'libfoo-dev=1.0-1'* && $summary == *'every item: go-yolo.sh --plan'* ]] \
  || fail "the summary lists items without warnings: $summary"
pass 'the plan is shown as a summary with every warning in full; --plan shows every item'

# D20: a change that exposes nothing new (a version bump) is taken with a note, even without a
# terminal; one that exposes something new (an env variable) asks.
cat >>"$TEST_DIR/apt-policy" <<'POLICY'
libbump-dev:
  Installed: 2.0-1
  Candidate: 2.0-1
  Version table:
 *** 2.0-1 500
        500 http://deb.debian.org/debian trixie/main amd64 Packages
        100 /var/lib/dpkg/status
POLICY
printf 'image host package libbump-dev\n' >"$CONFIG"
launch --yes shell 2>/dev/null
sed -i 's/2\.0-1/2.0-2/' "$TEST_DIR/apt-policy"
output="$(launch shell 2>&1)" || fail "a version bump needed confirmation: $output"
[[ $output == *'plan updated, nothing new exposed: package libbump-dev 2.0-1 → 2.0-2'* ]] \
  || fail "the version bump was not noted: $output"
grep -q '^package	extra	apt	libbump-dev	2.0-2	' "$STATE/plan" || fail 'the updated plan was not saved'
printf 'image host package libbump-dev\nenv host env NEW_VAR\n' >"$CONFIG"
TEST_ENV=(NEW_VAR=x)
if output="$(launch shell 2>&1)"; then fail 'a newly exposed env variable was taken without asking'; fi
TEST_ENV=()
[[ $output == *'run go-yolo in a terminal to confirm it'* ]] || fail "unexpected error: $output"
rm -rf -- "$STATE"
pass 'changes that expose nothing new are taken with a note; new exposure is asked'

# Base image packages vs the host: zlib1g is older on the host, tzdata newer; libc6 is the
# same, tini isn't on the host, "removed" was removed from the host (status rc).
TEST_DPKG_HOST="$REPO_DIR/tests/fixtures/dpkg-host"
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan 'parity    zlib1g=1:1.3-1+deb13u1  ⚠ the base image has this newer version, the host has 1:1.3-1 (apt upgrade the host to match)'
expect_plan 'parity    tzdata=2026e-1  ⚠ the base image has this older version, the host has 2026f-1 (go-yolo.sh --rebuild updates the base image)'
for name in libc6 tini removed only-on-host; do
  [[ $plan_text != *"parity    $name="* ]] || fail "parity warning for $name"
done
pass 'base image packages whose version differs from the host are warnings in the plan'

# First run: the base image doesn't exist yet. It is built first, without asking (it holds
# nothing from the host), so the one plan shown already compares its packages with the host's.
rm -f "$STATE/plan" "$TEST_DIR/docker.log.built"
cp /dev/null "$TEST_DIR/docker.log"
output="$(TEST_IMAGE_STATUS=built-on-build launch --yes shell 2>&1 >/dev/null)"
[[ $output == *'building go-yolo-base:'*'plan for '*'(new;'* ]] || fail "the base was not built before the plan was shown: $output"
[[ $output == *'parity    zlib1g=1:1.3-1+deb13u1  ⚠'* ]] || fail "the new plan lacks the base comparison: $output"
[[ $(grep -c 'plan for\|plan for this project changed' <<<"$output") == 1 ]] || fail "the plan was shown more than once: $output"
grep -q '^parity	host	check	zlib1g	' "$STATE/plan" || fail 'the confirmed plan lacks the base comparison'
[[ $(grep -c '^build$' "$TEST_DIR/docker.log") == 2 ]] || fail 'expected a base and a project build'
rm -f "$TEST_DIR/docker.log.built" "$STATE/plan"
TEST_DPKG_HOST=""
pass 'a first run builds the base image without asking and shows one plan, with the base comparison'


rm -rf -- "$STATE"
mkdir -p "$STATE"
printf 'env host tz -\n' >"$STATE/config"   # a setup, so the run goes straight to the plan
# The prompt needs a terminal; script(1) provides one and feeds it our answers.
if command -v script >/dev/null 2>&1; then
  answer_prompt() {
    local cmd
    printf -v cmd '%q ' env -i HOME="$TEST_HOME" PATH="$TEST_DIR/bin:/usr/bin:/bin" TERM=dumb \
      GOYOLO_TOOLS= GOENV=off GOYOLO_QUIET=1 GOYOLO_OS_RELEASE="$REPO_DIR/tests/fixtures/os-release" \
      GOROOT="$TEST_HOME/toolchain" GOPATH="$TEST_HOME/go" GOCACHE="$TEST_HOME/cache" \
      GOMODCACHE="$TEST_HOME/go/pkg/mod" DOCKER_TEST_LOG="$TEST_DIR/docker.log" TZ=UTC \
      GOYOLO_CA_DIR="$TEST_DIR/ca" "$REPO_DIR/go-yolo.sh" shell -c true
    (cd "$TEST_HOME/project" && printf '%s\n' "$@" | TEST_CMD=$cmd timeout 60 script -qec 'bash -c "$TEST_CMD"' /dev/null) \
      | tr -d '\r' || true
  }
  output="$(answer_prompt '?' n)"
  [[ $output == *'y: build with this plan'* && $output == *'aborted; nothing was built'* ]] \
    || fail "the prompt did not explain itself and abort: $output"
  [[ ! -e $STATE/plan ]] || fail 'the plan was saved after answering n'
  answer_prompt y >/dev/null
  grep -q 'TZ	UTC' "$STATE/plan" || fail 'the plan was not saved after answering y'
  pass 'the plan prompt explains its choices, aborts on n and saves on y'
fi
