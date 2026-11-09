#!/usr/bin/env bash
# Mount safety, extra mounts, git and agent config mounts.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

for path in /run /dev /proc /sys /run/lock /dev/null /proc/self/status /sys/kernel /var/run; do
  if [[ -e $path ]]; then reject --mount "$path" shell; fi
done
reject --mount "$TEST_HOME/links/run" shell
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
dry_run --mount "$TEST_HOME/.m2:ro" --mount "$TEST_HOME/.gradle:ro" shell
assert_mount "$TEST_HOME/.m2" "$TEST_HOME/.m2" ro
assert_mount "$TEST_HOME/.gradle" "$TEST_HOME/.gradle" ro
pass 'normal mounts, spaces, and explicit read-only mounts are preserved'

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
