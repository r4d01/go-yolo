#!/usr/bin/env bash
# The setup picker: what a project's container gets, picked from what the host has.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# A Go project, so the Go candidates are suggested.
mkdir -p "$TEST_HOME/go/bin"
: >"$TEST_HOME/go/bin/gopls"
printf 'module example.com/p\n\ngo 1.99\n' >"$TEST_HOME/project/go.mod"
cat >>"$TEST_DIR/apt-policy" <<'POLICY'
protobuf-compiler-x:
  Installed: (none)
  Candidate: 3.21.12-11
  Version table:
     3.21.12-11 500
        500 http://deb.debian.org/debian trixie/main amd64 Packages
POLICY
CONFIG="$STATE/config"

# Without a terminal, --setup takes the suggested picks (--yes); a dry run only previews them.
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
[[ $plan_text == *'no setup yet: this is what the suggested picks would give'* ]] || fail "no preview: $plan_text"
[[ ! -e $CONFIG ]] || fail 'a dry run saved the setup'
expect_plan "toolchain $TEST_HOME/toolchain (go1.99.0) [go]"
launch --yes --setup 2>/dev/null
for line in 'image  go       toolchain  -' 'image  go       tool       gopls' 'cache  go       cache      modules' \
            'cache  go       cache      build' 'env    go       env        GOPROXY' 'env    host     tz         -' \
            "image  host     cert       $TEST_DIR/ca/corp/root.crt"; do
  grep -qxF -- "$line" "$CONFIG" || fail "the suggested picks lack '$line': $(cat "$CONFIG")"
done
[[ -f $STATE/plan ]] || fail '--setup --yes did not confirm the plan'
pass 'a first setup suggests the items a project hints at; --yes takes them, a dry run previews them'

# A picked item the host no longer has is a warning in the plan.
rm -f -- "$STATE/plan"
printf 'image host cert /no/such/root.crt\nimage host tool no-such-tool\n' >"$CONFIG"
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "cert      /no/such/root.crt  ⚠ picked, but the host doesn't have it (any more): go-yolo.sh --setup"
expect_plan "tools     no-such-tool (-) [extra]  ⚠ not on the host's PATH"
[[ $plan_text != *toolchain* ]] || fail "an item that is not picked is in the plan: $plan_text"
pass "only picked items are planned; a picked item the host doesn't have gets a warning"

if command -v script >/dev/null 2>&1; then
  cp "$REPO_DIR/tests/fixtures/fzf" "$TEST_DIR/bin/fzf"

  # fzf: the stub picks the lines matching FZF_TEST_PICK; then a package added by name.
  rm -f -- "$CONFIG" "$STATE/plan"
  TEST_ENV=(FZF_TEST_PICK='module cache')
  output="$(in_terminal 'package protobuf-compiler-x' '' y -- --setup)"
  [[ $output == *'pick what this project'* ]] || fail "the picker was not shown: $output"
  [[ $(grep -v '^#' "$CONFIG") == $'cache  go       cache      modules\nimage  host     package    protobuf-compiler-x' ]] \
    || fail "the picks are not what was picked: $(cat "$CONFIG")"
  grep -q '^package	extra	apt	protobuf-compiler-x	' "$STATE/plan" || fail 'the confirmed plan lacks the added package'
  pass 'the setup picker saves what was picked, plus items added by name, then confirms the plan'

  # An fzf too old for the picker: a numbered list instead. "n" unpicks everything.
  rm -f -- "$CONFIG" "$STATE/plan"
  TEST_ENV=(FZF_TEST_OLD=1)
  output="$(in_terminal n '' 'env FOO_SETUP' '' y -- --setup)"
  [[ $output == *'[x]  1'* && $output == *'[ ]  1'* ]] || fail "no numbered list, or it didn't toggle: $output"
  [[ $(grep -v '^#' "$CONFIG") == 'env    host     env        FOO_SETUP' ]] || fail "unexpected picks: $(cat "$CONFIG")"
  pass 'without a usable fzf the picker is a numbered list to toggle'

  # --setup again starts from the saved picks.
  TEST_ENV=(FZF_TEST_OLD=1)
  output="$(in_terminal '' '' -- --setup --yes)"
  [[ $(grep -v '^#' "$CONFIG") == 'env    host     env        FOO_SETUP' ]] || fail "the picks changed: $(cat "$CONFIG")"
  TEST_ENV=()
  pass '--setup starts from the saved picks'

  # [s] at the plan prompt opens the picker on the current picks; the plan is shown again.
  rm -f -- "$STATE/plan"
  printf 'image go toolchain -\ncache go cache modules\ncache go cache build\n' >"$CONFIG"
  TEST_ENV=(FZF_TEST_PICK='build cache')
  output="$(in_terminal s '' y -- shell -c true)"
  [[ $(grep -v '^#' "$CONFIG") == 'cache  go       cache      build' ]] || fail "[s] did not change the picks: $(cat "$CONFIG")"
  [[ $output == *'pick what this project'* ]] || fail "[s] did not open the picker: $output"
  grep -q '^toolchain	' "$STATE/plan" && fail 'the plan still has the unpicked toolchain'
  rm -f -- "$TEST_DIR/bin/fzf"
  TEST_ENV=()
  pass '[s] at the plan prompt changes the picks and shows the plan again'
fi
rm -rf -- "$STATE" "$TEST_HOME/project/go.mod"
