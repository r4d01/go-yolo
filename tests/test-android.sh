#!/usr/bin/env bash
# The Android catalog: an SDK the host doesn't have (D23), and one it has.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { printf 'skip - the Android catalog needs python3\n'; exit 0; }
ANDROID_PROJECT="$TEST_HOME/project"
SDK="$TEST_HOME/Android/Sdk"
mkdir -p "$ANDROID_PROJECT/app" "$TEST_HOME/.android"
printf 'plugins { id("com.android.application") }\nandroid {\n    compileSdk = 30\n}\n' >"$ANDROID_PROJECT/app/build.gradle.kts"
printf 'fake keystore\n' >"$TEST_HOME/.android/debug.keystore"
CONFIG="$STATE/config"
TEST_ENV=(GOYOLO_ANDROID_MANIFEST="$REPO_DIR/tests/fixtures/android-repository.xml")

# No SDK on the host: the manifest's packages are offered, none pre-selected; --yes takes none.
rm -rf -- "$STATE"
launch --yes --setup 2>/dev/null
grep -q 'android' "$CONFIG" && [[ $(grep -c 'android  *component' "$CONFIG") == 0 ]] \
  || fail "a package the host doesn't have was pre-selected, or the keystore wasn't: $(cat "$CONFIG")"
grep -qxF 'mount  android  mount      debug-keystore' "$CONFIG" || fail "the debug keystore isn't suggested: $(cat "$CONFIG")"
if command -v script >/dev/null 2>&1; then
  cp "$REPO_DIR/tests/fixtures/fzf" "$TEST_DIR/bin/fzf"
  rm -rf -- "$STATE"
  # The picker offers the stable platforms (the project's compileSdk among them) and build-tools.
  TEST_ENV+=(FZF_TEST_PICK='platforms;android-30 3')
  output="$(in_terminal '' n -- --setup)"
  [[ $output == *'licence android-sdk-license above. Accept it? [y/N]'* && $output == *'Terms and Conditions (test fixture).'* ]] \
    || fail "the licence was not shown and asked for: $output"
  grep -qxF 'image  android  component  platforms;android-30@3' "$CONFIG" || fail "the pick is not pinned: $(cat "$CONFIG")"
  grep -qxF 'image  android  component  cmdline-tools;latest@23.0' "$CONFIG" || fail "cmdline-tools was not pinned too"
  ! grep -q 'license' "$CONFIG" || fail 'a licence answered with "n" was saved'
  plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
  expect_plan 'component platforms;android-30 (3) [android]  ⚠ needs the licence android-sdk-license, not accepted'
  rm -rf -- "$STATE"
  output="$(in_terminal '' y '' y -- --setup)"
  grep -qxF 'image  android  license    android-sdk-license' "$CONFIG" || fail "an accepted licence was not saved: $(cat "$CONFIG")"
  # The numbered list shows what is offered.
  rm -f -- "$STATE/plan"
  TEST_ENV=(GOYOLO_ANDROID_MANIFEST="$REPO_DIR/tests/fixtures/android-repository.xml" FZF_TEST_OLD=1)
  output="$(in_terminal '' '' n -- --setup)"
  [[ $output == *'○ platforms;android-30 3 (not on the host, suggested: the project'* ]] || fail "compileSdk is not suggested: $output"
  [[ $output == *'○ build-tools;36.0.0 36.0.0'* && $output == *'○ platform-tools 37.0.1'* ]] || fail "stable packages are missing: $output"
  [[ $output != *'android-36-ext19'* && $output != *'ndk;'* && $output != *'37.0.2'* ]] || fail "unstable or unasked-for packages offered: $output"
  TEST_ENV=(GOYOLO_ANDROID_MANIFEST="$REPO_DIR/tests/fixtures/android-repository.xml")
  pass "without an SDK on the host, packages are picked from Google's manifest, pinned, and their licence asked for"
fi

mkdir -p "$STATE"
printf '%s\n' 'image android component cmdline-tools;latest@23.0' 'image android component platforms;android-30@3' \
  'image android component build-tools;36.0.0@36.0.0' 'image android license android-sdk-license' \
  'mount android mount debug-keystore' >"$CONFIG"
rm -f -- "$STATE/plan"
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "toolchain $SDK (Android SDK, 3 packages) [android]  owned by you, as on the host; ⚠ not installed on the host"
expect_plan 'component build-tools;36.0.0 (36.0.0) [android]  ⚠ not installed on the host'
expect_plan 'license   licence android-sdk-license [android]'
expect_plan "env       ANDROID_HOME=$SDK [android]"
expect_plan 'domain    maven.google.com [android]'
expect_plan "mount     $TEST_HOME/.android/debug.keystore (read-only) [android]"
cp /dev/null "$TEST_DIR/docker.log"
TEST_IMAGE_STATUS=1 launch --yes shell 2>/dev/null
dockerfile="$(cat "$STATE/build/Dockerfile")"
[[ $dockerfile == *"RUN install -d -o $(id -u) -g $(id -g) $TEST_HOME /tmp/go-yolo-build $SDK"* ]] || fail "the SDK directory isn't made in the build stage: $dockerfile"
expected="RUN /opt/go-yolo/scripts/android-sdk.sh $SDK android-sdk-license -- 'cmdline-tools;latest@23.0' 'platforms;android-30@3' 'build-tools;36.0.0@36.0.0'"
[[ $dockerfile == *"$expected"* ]] || fail "the SDK isn't installed by android-sdk.sh: $dockerfile"
[[ $dockerfile != *'-m  '* ]] || fail "a directory without a mode: $dockerfile"
[[ $dockerfile == *"COPY --from=build --chown=$(id -u):$(id -g) [\"$SDK/\", \"$SDK/\"]"* ]] || fail 'the SDK is not copied into the image'
pass "an SDK the host doesn't have is installed in the build stage at the pinned revisions, with a warning"

# --parity: the packages the host doesn't have are only in the container, not differences.
TEST_ENV+=(DOCKER_TEST_RUN_SCRIPT=1)
mkdir -p "$SDK/platforms/android-30"
output="$(launch --parity 2>&1)" || true
[[ $output == *'○ component platforms;android-30'*'only in the container'* && $output != *'✗ component'* ]] \
  || fail "--parity counts packages the host doesn't have as differences: $output"
rm -rf -- "$SDK"
pass '--parity shows the packages the host does not have as container-only'

# An SDK on the host: its packages at the host's revisions, its licences; a pinned pick is stale.
mkdir -p "$SDK/build-tools/35.0.0" "$SDK/licenses"
printf '<ns2:repository xmlns:ns2="x"><localPackage path="build-tools;35.0.0"><revision><major>35</major><minor>0</minor><micro>0</micro></revision></localPackage></ns2:repository>\n' \
  >"$SDK/build-tools/35.0.0/package.xml"
printf 'abc\n' >"$SDK/licenses/android-sdk-license"
printf '%s\n' 'image android component build-tools;35.0.0' 'image android component platforms;android-30@3' >"$CONFIG"
rm -f -- "$STATE/plan"
TEST_ENV=(GOYOLO_ANDROID_MANIFEST="$REPO_DIR/tests/fixtures/android-repository.xml")
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "toolchain $SDK (Android SDK, 1 packages) [android]  owned by you, as on the host"
expect_plan 'component build-tools;35.0.0 (35.0.0) [android]'
expect_plan 'component platforms;android-30 (3) [android]  ⚠ picked when the host had no Android SDK'
[[ $plan_text != *'build-tools;35.0.0 (35.0.0) [android]  ⚠'* ]] || fail 'a host package got a warning'
TEST_IMAGE_STATUS=1 launch --yes shell 2>/dev/null
grep -qF "android-sdk.sh $SDK android-sdk-license -- 'build-tools;35.0.0@35.0.0'" "$STATE/build/Dockerfile" \
  || fail "the host's packages are not installed at its revision with its licences: $(cat "$STATE/build/Dockerfile")"
rm -rf -- "$STATE" "$TEST_HOME/Android" "$ANDROID_PROJECT/app"
pass "with an SDK on the host, its packages are installed at the host's revisions, with its licences"
