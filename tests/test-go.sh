#!/usr/bin/env bash
# The Go catalog.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

GO_PROJECT="$TEST_HOME/project"
mkdir -p "$TEST_HOME/go/bin" "$TEST_HOME/go/pkg/mod/cache/download" "$TEST_HOME/toolchain/bin" "$TEST_DIR/pc"
# The toolchain is a go.dev release; the tools are fake Go binaries (see the go stub): gopls from
# go install, one built in a checkout, one built with an older Go, one with -ldflags.
printf 'go1.99.0\ntime 2026-08-18T21:24:23Z\n' >"$TEST_HOME/toolchain/VERSION"
printf 'not really go\n' >"$TEST_HOME/toolchain/bin/go"
go_tool() {
  local file="$TEST_HOME/go/bin/$1" go=$2 path=$3 version=$4
  printf '%s\n\tpath\t%s\n\tmod\t%s\t%s\th1:abc=\n\tdep\tgolang.org/x/mod\tv0.30.0\th1:def=\n' "$go" "$path" "$path" "$version" >"$file"
  printf '\tbuild\t-buildmode=exe\n\tbuild\t-compiler=gc\n\tbuild\tDefaultGODEBUG=x=0\n\tbuild\tCGO_ENABLED=1\n' >>"$file"
  printf '\tbuild\tCGO_CFLAGS=\n\tbuild\tGOARCH=amd64\n\tbuild\tGOOS=linux\n\tbuild\tGOAMD64=v1\n%s' "${5:-}" >>"$file"
}
go_tool gopls go1.99.0 golang.org/x/tools/gopls v0.23.0 $'\tbuild\t-trimpath=true\n'
go_tool local-tool go1.99.0 example.com/local-tool '(devel)' $'\tbuild\tvcs=git\n'
go_tool old-tool go1.98.2 example.com/old-tool v1.0.0
go_tool flagged-tool go1.99.0 example.com/flagged-tool v1.0.0 $'\tbuild\t-ldflags="-s -w"\n'
printf 'module example.com/p\n\ngo 1.99\n' >"$GO_PROJECT/go.mod"
rm -rf -- "$STATE"

TEST_GOCACHE="$TEST_HOME" reject shell
TEST_GOMODCACHE="$TEST_HOME" reject shell
TEST_GOMODCACHE="$TEST_HOME/links/home" reject shell
TEST_GOCACHE=/proc reject shell
TEST_GOROOT=/usr reject shell
pass 'Go caches and toolchains at system or home directories (or aliases) are refused'

plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
toolchain_hash="$(cd "$TEST_HOME/toolchain" && sha256sum bin/go VERSION | sha256sum | cut -c1-16)"
gopls_hash="$(cd "$TEST_HOME/go/bin" && sha256sum gopls | sha256sum | cut -c1-16)"
expect_plan "toolchain $TEST_HOME/toolchain (go1.99.0, $toolchain_hash) [go]  owned by you, as on the host; first on PATH; installed from dl.google.com, checked against its checksum and the host's files"
expect_plan "tool      $TEST_HOME/go/bin/gopls (golang.org/x/tools/gopls@v0.23.0, $gopls_hash) [go]  owned by you, as on the host; built in the image, checked against the host's file"
expect_plan "tool      $TEST_HOME/go/bin/local-tool ("
expect_plan "copied from the host: built from local sources"
expect_plan "copied from the host: built with go1.98.2, not with the host's Go"
expect_plan "copied from the host: built with settings go install can't repeat"
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
uid_gid="$(id -u):$(id -g)"
expected="USER $uid_gid
RUN /opt/go-yolo/scripts/install-archive.sh https://dl.google.com/go/go1.99.0.linux-amd64.tar.gz sha256 https://dl.google.com/go/go1.99.0.linux-amd64.tar.gz.sha256 $TEST_HOME/toolchain $toolchain_hash -- bin/go VERSION
USER root"
[[ $dockerfile == *"$expected"* ]] || fail "the toolchain is not installed from go.dev as you: $dockerfile"
[[ $dockerfile == *"RUN install -d -o $(id -u) -g $(id -g) -m "*" $TEST_HOME/go"$'\n'* ]] \
  || fail "the parents of installed directories are not created with your ownership: $dockerfile"
[[ $dockerfile == *'FROM go-yolo-base:'*' AS project'* && $dockerfile == *$'FROM project AS build\n'* ]] \
  || fail "no build stage: $dockerfile"
expected=' && GOBIN="$OUT" env GOTOOLCHAIN=local GOENV=off GOFLAGS= GOPATH='"$TEST_HOME/go GOMODCACHE=$TEST_HOME/go/pkg/mod"
expected+=" GOCACHE=/tmp/go-yolo-build/go-build GOPROXY=https://proxy.example.com,direct CGO_ENABLED=1"
expected+=" CGO_CFLAGS= GOARCH=amd64 GOOS=linux GOAMD64=v1 $TEST_HOME/toolchain/bin/go install -trimpath golang.org/x/tools/gopls@v0.23.0"
[[ $dockerfile == *"$expected"* ]] || fail "gopls is not built with the host's paths and settings: $dockerfile"
[[ $dockerfile == *" && /opt/go-yolo/scripts/verify.sh \"\$OUT\" $gopls_hash gopls"* ]] || fail 'the built gopls is not checked'
[[ $dockerfile == *$'\nFROM project\n'*"COPY --from=build --chown=$uid_gid [\"/tmp/go-yolo-build/1/gopls\", \"$TEST_HOME/go/bin/gopls\"]"* ]] \
  || fail 'the built gopls is not copied into the image'
[[ $dockerfile == *"COPY --chown=$uid_gid [\"files-copied/2\", \"$TEST_HOME/go/bin/local-tool\"]"* ]] \
  || fail 'a tool built from local sources is not copied'
cmp -s "$STATE/build/files-copied/2" "$TEST_HOME/go/bin/local-tool" || fail 'the copied tool is not in the build context'
[[ $dockerfile != *"--build-context"* && $(grep -c -- '--build-context' "$TEST_DIR/docker.log") == 0 ]] \
  || fail 'something is still copied as a host directory'
grep -qxF -- "go-yolo-$slug-go-mod" "$TEST_DIR/docker.log" && grep -qxF -- "go-yolo.cache=go-mod" "$TEST_DIR/docker.log" \
  || fail 'the go-mod cache volume was not created with its labels'
pass 'Go: the toolchain comes from go.dev and gopls from go install, both checked against the host; other tools are copied, saying why'

# The copy mode: the toolchain copied although go.dev has it; a tool with another Go copied too.
rm -f -- "$STATE/plan"
printf 'copy go toolchain -\nimage go tool gopls\nimage go tool old-tool\n' >"$STATE/config"
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "toolchain $TEST_HOME/toolchain (go1.99.0) [go]  owned by you, as on the host; first on PATH; copied from the host, as .go-yolo/config asks"
expect_plan "tool      $TEST_HOME/go/bin/gopls (golang.org/x/tools/gopls@v0.23.0, $gopls_hash) [go]  owned by you, as on the host; built in the image"
cp /dev/null "$TEST_DIR/docker.log"
TEST_IMAGE_STATUS=1 launch --yes shell 2>/dev/null
grep -qxF -- "copy1=$TEST_HOME/toolchain" "$TEST_DIR/docker.log" || fail 'the copied toolchain is not a build context'
launch --yes --setup shell 2>/dev/null
grep -qxF 'copy   go       toolchain  -' "$STATE/config" || fail "--setup lost the copy mode: $(cat "$STATE/config")"
printf 'image go toolchain -\nimage go tool gopls\n' >"$STATE/config"
rm -f -- "$STATE/plan"
TEST_ENV=(GOVERSION=go1.99.1)
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "toolchain $TEST_HOME/toolchain (go1.99.1) [go]  owned by you, as on the host; first on PATH; copied from the host: no recipe knows how to install it"
expect_plan "copied from the host: built with go1.99.0, not with the host's Go"
TEST_ENV=()
rm -rf -- "$STATE"
pass 'Go: the copy mode copies an item a recipe could install; a toolchain that is not the go.dev release is copied'

# A go.work in a parent directory, using the repository and a module beside it, on a first setup.
rm -f -- "$STATE/config"
mkdir -p "$TEST_HOME/shared"
: >"$TEST_HOME/go.work"
TEST_ENV=(GOWORK="$TEST_HOME/go.work" GO_TEST_WORK_JSON='{"Use": [{"DiskPath": "./project"}, {"DiskPath": "./shared"}]}'
          GOYOLO_GOPATH_MODE=rw)
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "mount     $TEST_HOME/go.work (read-only) [go]  ⚠ outside the repository: read-only in the container"
expect_plan "mount     $TEST_HOME/shared (read-only) [go]  ⚠ outside the repository"
[[ $plan_text != *"mount     $GO_PROJECT "* ]] || fail 'the repository itself was planned as a go.work mount'
expect_plan 'GOYOLO_GOPATH_MODE is no longer used'
rm -rf -- "$STATE" "$GO_PROJECT/go.mod" "$TEST_HOME/go.work"
TEST_ENV=()
pass 'Go: a go.work outside the repository is mounted read-only, with the modules it uses outside it'
