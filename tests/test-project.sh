#!/usr/bin/env bash
# The git repository root and .go-yolo/.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

mkdir -p "$TEST_DIR/not-a-repo"
[[ $(launch_in "$TEST_DIR/not-a-repo" --dry-run shell) == *'not inside a git repository'* ]] \
  || fail 'ran outside a git repository'
[[ $(launch_in "$TEST_HOME/project/nested" --dry-run shell) == *"run go-yolo from the repository's root directory: cd $TEST_HOME/project"* ]] \
  || fail 'ran from a repository subdirectory'
pass 'go-yolo runs only from a git repository root'

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

mkdir -p "$STATE/cache/go-mod"
[[ $(launch_in "$TEST_HOME/project" --yes shell) == *'cache is no longer used (caches are Docker volumes now)'* ]] \
  || fail 'no note about the old .go-yolo/cache/'
[[ $(launch_in "$TEST_HOME/project" --yes shell) != *'no longer used'* ]] || fail 'the old-cache note was repeated'
rm -rf -- "$STATE/cache" "$STATE/noted-old-cache"
pass 'an old .go-yolo/cache/ gets a one-time note that caches are Docker volumes now'
