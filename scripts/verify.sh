#!/usr/bin/env bash
# verify.sh DIR HASH FILE...
#
# Used by the project images (see lib/recipes.sh): check that FILE... (paths relative to DIR) are
# the host's. HASH is the first 16 hex digits of the SHA-256 of `sha256sum FILE...` run in DIR,
# which go-yolo computed the same way from the host's files.
set -euo pipefail

(($# >= 3)) || { printf 'usage: verify.sh DIR HASH FILE...\n' >&2; exit 1; }
dir=$1 hash=$2
shift 2
cd -- "$dir"
actual="$(sha256sum -- "$@" | sha256sum | cut -c1-16)"
if [[ $actual != "$hash" ]]; then
  printf "go-yolo: %s isn't the host's: the hash of these files is %s, the host's is %s:\n" "$dir" "$actual" "$hash" >&2
  sha256sum -- "$@" | sed 's/^/    /' >&2
  printf 'go-yolo: to copy it from the host instead, change its mode to "copy" in .go-yolo/config\n' >&2
  exit 1
fi
