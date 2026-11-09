#!/usr/bin/env bash
# --prune: images and cache volumes.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# Images: the current base (and its alias), an older base, a project's image for its confirmed
# plan and for an older one, a project that is gone, and an image from before go-yolo-base.
base_tag="go-yolo-base:debian-trixie-$(REPO_DIR=$REPO_DIR; source "$REPO_DIR/lib/image.sh"; compute_hash)"
mkdir -p "$TEST_DIR/projects/kept/.go-yolo"
printf '# confirmed: today\nbase\thost\timage\t%s\t-\t-\ncache\tgo\tvolume\t/x/go/pkg/mod\tgo-mod\t-\n' \
  "$base_tag" >"$TEST_DIR/projects/kept/.go-yolo/plan"
kept_hash="$(source "$REPO_DIR/lib/kinds.sh"; source "$REPO_DIR/lib/plan.sh"; confirmed_plan_hash "$TEST_DIR/projects/kept")"
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
# Volumes: a cache in the kept project's plan, one it no longer has, one of the gone project.
printf '%s\t%s\t%s\t2026-11-09T10:00:00Z\t%s\n' \
  go-yolo-kept-1-go-mod "$TEST_DIR/projects/kept" go-mod 50MB \
  go-yolo-kept-1-npm "$TEST_DIR/projects/kept" npm 10MB \
  go-yolo-gone-2-go-mod "$TEST_DIR/projects/gone" go-mod 70MB >"$TEST_DIR/volumes"


cp /dev/null "$TEST_DIR/docker.log"
output="$(launch --prune 2>&1)"
for tag in "${current_tags[@]}"; do [[ $output == *"✓ image  $tag "* ]] || fail "$tag not listed as current: $output"; done
for tag in "${stale_tags[@]}"; do [[ $output == *"✗ image  $tag "* ]] || fail "$tag not listed as stale: $output"; done
[[ $output == *'✓ volume go-yolo-kept-1-go-mod '*'50MB'*'go-mod cache of'* ]] || fail "the kept volume is not current: $output"
[[ $output == *'✗ volume go-yolo-kept-1-npm '*'npm cache, no longer in the plan of'* ]] || fail "a dropped cache is not stale: $output"
[[ $output == *'✗ volume go-yolo-gone-2-go-mod '*'project is gone'* ]] || fail "a gone project's volume is not stale: $output"
[[ $output == *'an older plan of'* && $output == *'project is gone'* && $output == *'before go-yolo-base'* ]] \
  || fail "--prune does not say why images are stale: $output"
[[ -z $(removed_items) ]] || fail '--prune removed something without a terminal or --yes'
pass '--prune lists current and stale images and cache volumes with the reason, and only lists without a terminal'

mkdir -p "$TEST_HOME/.cache/go-yolo"
: >"$TEST_HOME/.cache/go-yolo/base-packages-gone"
cp /dev/null "$TEST_DIR/docker.log"
TEST_IMAGE_STATUS=1 launch --prune --yes >/dev/null 2>&1
removed="$(removed_items)"
[[ $removed == "$(printf '%s\n' "${stale_tags[@]}" 'volume go-yolo-kept-1-npm' 'volume go-yolo-gone-2-go-mod')" ]] \
  || fail "--prune --yes removed: $removed"
[[ ! -e $TEST_HOME/.cache/go-yolo/base-packages-gone ]] || fail 'the package list of a removed base image was kept'
pass '--prune --yes removes exactly the stale images and volumes, and stale cached package lists'


# --prune [p]ick needs a terminal; script(1) provides one.
if command -v script >/dev/null 2>&1; then
  # --prune [p]ick with fzf (a stub that picks the lines containing $FZF_TEST_PICK).
  cp "$REPO_DIR/tests/fixtures/fzf" "$TEST_DIR/bin/fzf"
  printf -v cmd '%q ' env -i HOME="$TEST_HOME" PATH="$TEST_DIR/bin:/usr/bin:/bin" TERM=dumb \
    GOYOLO_OS_RELEASE="$REPO_DIR/tests/fixtures/os-release" DOCKER_TEST_LOG="$TEST_DIR/docker.log" \
    DOCKER_TEST_IMAGES="$TEST_DIR/images" FZF_TEST_PICK="$kept_hash" "$REPO_DIR/go-yolo.sh" --prune
  cp /dev/null "$TEST_DIR/docker.log"
  printf 'p\n' | TEST_CMD=$cmd script -qec 'bash -c "$TEST_CMD"' /dev/null >/dev/null
  removed="$(removed_items)"
  [[ $removed == "go-yolo:kept-1-$kept_hash" ]] || fail "[p]ick removed: $removed"
  rm -f "$TEST_DIR/bin/fzf"
  pass '--prune [p]ick removes exactly the picked images, current ones included'
fi
