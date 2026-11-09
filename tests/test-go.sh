#!/usr/bin/env bash
# The Go catalog.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

GO_PROJECT="$TEST_HOME/project"
mkdir -p "$TEST_HOME/go/bin" "$TEST_HOME/go/pkg/mod/cache/download" "$TEST_HOME/toolchain/bin" "$TEST_DIR/pc"
: >"$TEST_HOME/go/bin/gopls"
printf 'module example.com/p\n\ngo 1.99\n' >"$GO_PROJECT/go.mod"
rm -rf -- "$STATE"

TEST_GOCACHE="$TEST_HOME" reject shell
TEST_GOMODCACHE="$TEST_HOME" reject shell
TEST_GOMODCACHE="$TEST_HOME/links/home" reject shell
TEST_GOCACHE=/proc reject shell
TEST_GOROOT=/usr reject shell
pass 'Go caches and toolchains at system or home directories (or aliases) are refused'

plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "toolchain $TEST_HOME/toolchain (go1.99.0) [go]  owned by you, as on the host"
expect_plan "tools     $TEST_HOME/go/bin (1 files, "
expect_plan "cache     $TEST_HOME/go/pkg/mod (project volume go-mod) [go]"
expect_plan "cache     $TEST_HOME/cache (project volume go-build) [go]"
expect_plan 'env       GOPROXY=https://proxy.example.com,direct [go]'
[[ $plan_text != *seed* ]] || fail 'the plan still has a seed'
expect_plan 'domain    proxy.example.com [go]'
expect_plan 'domain    sum.golang.org [go]'
[[ $plan_text != *GOBIN* ]] || fail 'GOBIN was passed although the host does not set it'

slug="$(source "$REPO_DIR/lib/project.sh"; project_slug "$GO_PROJECT")"
dry_run shell
for expected in "type=volume,source=go-yolo-$slug-go-mod,target=$TEST_HOME/go/pkg/mod" \
                "type=volume,source=go-yolo-$slug-go-build,target=$TEST_HOME/cache" \
                "GOYOLO_VOLUMES=$TEST_HOME/cache"$'\n'"$TEST_HOME/go/pkg/mod"; do
  has_arg "$expected" || fail "the docker command lacks: $expected"
done
for arg in "${ARGS[@]}"; do
  case $arg in
    *"source=$TEST_HOME/go,"*|*"source=$TEST_HOME/go/pkg/mod,"*|*"source=$TEST_HOME/cache,"*|*"source=$TEST_HOME/toolchain,"*)
      fail "a host Go directory is mounted: $arg" ;;
  esac
done
printf '%s\n' "${ARGS[@]}" | grep -qxF "GOYOLO_TOOL_PATH=$TEST_HOME/toolchain/bin:$TEST_HOME/go/bin" \
  || fail 'the Go toolchain and tools are not first on PATH'
printf '%s\n' "${ARGS[@]}" | grep -qxF GOPROXY || fail "the host's GOPROXY is not passed"
pass "Go: caches are the project's Docker volumes at the host's paths; no host Go directory is mounted"

cp /dev/null "$TEST_DIR/docker.log"
TEST_IMAGE_STATUS=1 launch --yes shell 2>/dev/null
dockerfile="$(cat "$STATE/build/Dockerfile")"
[[ $dockerfile == *"COPY --from=copy1 --chown=$(id -u):$(id -g) [\"/\", \"$TEST_HOME/toolchain/\"]"* ]] \
  || fail "the toolchain is not copied with your ownership: $dockerfile"
[[ $dockerfile == *"COPY --from=copy2 --chown=$(id -u):$(id -g) [\"/\", \"$TEST_HOME/go/bin/\"]"* ]] \
  || fail 'the Go tools are not copied'
[[ $dockerfile == *"RUN install -d -o $(id -u) -g $(id -g) -m "*" $TEST_HOME/go"$'\n'* ]] \
  || fail 'the parents of copied directories are not created with your ownership'
grep -qxF -- "copy1=$TEST_HOME/toolchain" "$TEST_DIR/docker.log" && grep -qxF -- "copy2=$TEST_HOME/go/bin" "$TEST_DIR/docker.log" \
  || fail 'the copied directories are not passed as build contexts'
grep -qxF -- "go-yolo-$slug-go-mod" "$TEST_DIR/docker.log" && grep -qxF -- "go-yolo.cache=go-mod" "$TEST_DIR/docker.log" \
  || fail 'the go-mod cache volume was not created with its labels'
pass 'Go: GOROOT and GOBIN are copied into the image at the same paths, with the host ownership'

# cgo: "// #cgo pkg-config: sqlite3" → the package owning sqlite3.pc, plus pkg-config's own.
printf '// #cgo pkg-config: sqlite3 --static\nimport "C"\n' >"$GO_PROJECT/db.go"
: >"$TEST_DIR/pc/sqlite3.pc"
printf 'libsqlite3-dev: %s\npkgconf-bin: %s\n' "$TEST_DIR/pc/sqlite3.pc" "$TEST_DIR/bin/pkg-config" >"$TEST_DIR/dpkg-S"
# A go.work in a parent directory, using the repository and a module beside it.
mkdir -p "$TEST_HOME/shared"
: >"$TEST_HOME/go.work"
TEST_ENV=(GOWORK="$TEST_HOME/go.work" GO_TEST_WORK_JSON='{"Use": [{"DiskPath": "./project"}, {"DiskPath": "./shared"}]}'
          GOYOLO_GOPATH_MODE=rw)
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan 'package   libsqlite3-dev=3.46.1-2 [go]'
expect_plan 'package   pkgconf-bin=1.8.1-4 [go]'
expect_plan "mount     $TEST_HOME/go.work (read-only) [go]  ⚠ outside the repository: read-only in the container"
expect_plan "mount     $TEST_HOME/shared (read-only) [go]  ⚠ outside the repository"
[[ $plan_text != *"mount     $GO_PROJECT "* ]] || fail 'the repository itself was planned as a go.work mount'
expect_plan 'GOYOLO_GOPATH_MODE is no longer used'
rm -rf -- "$STATE" "$GO_PROJECT/go.mod" "$GO_PROJECT/db.go" "$TEST_HOME/go.work"
TEST_ENV=()
pass 'Go: cgo pkg-config libraries, and a go.work outside the repository, are planned'
