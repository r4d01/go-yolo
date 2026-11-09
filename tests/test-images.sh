#!/usr/bin/env bash
# Image builds: --rebuild, the build cache, reuse.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

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
