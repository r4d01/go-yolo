#!/usr/bin/env bash
# install-archive.sh URL ALGORITHM CHECKSUM_URL DEST HASH [--empty LIST] -- FILE...
#
# Used by the project images (see lib/recipes.sh): download a vendor's archive (.tar.gz, .tar.xz
# or .zip), check it against the checksum the vendor publishes at CHECKSUM_URL (ALGORITHM sha256
# or sha512; the file's first word), unpack it into DEST without its single top directory, make
# the paths in file LIST (one per line, relative to DEST) empty files as the host has them (e.g.
# Gradle's provisioned.ok markers, and the license links its unpacking turns into empty files),
# and check FILE... against the host's copies (HASH, see verify.sh).
#
# It runs as the owner the host has for DEST: as root, or as you (the Dockerfile's USER).
set -euo pipefail

die() { printf 'go-yolo: %s\n' "$*" >&2; exit 1; }

(($# >= 6)) || die "usage: install-archive.sh URL ALGORITHM CHECKSUM_URL DEST HASH [--empty LIST] -- FILE..."
url=$1 algorithm=$2 sums_url=$3 dest=$4 hash=$5
shift 5
empty_list=""
if [[ $1 == --empty ]]; then empty_list=$2; shift 2; fi
[[ ${1:-} == -- ]] || die "install-archive.sh: expected -- before the files to check"
shift
case $algorithm in sha256|sha512) ;; *) die "install-archive.sh: unknown algorithm $algorithm" ;; esac

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/archive" "$url" || die "can't download $url"
expected="$(curl -fsSL --retry 3 "$sums_url" | awk 'NR == 1 { print $1 }')" || die "can't download $sums_url"
[[ $expected =~ ^[0-9a-f]{64}([0-9a-f]{64})?$ ]] || die "no $algorithm checksum in $sums_url"
printf '%s  %s\n' "$expected" "$tmp/archive" | "${algorithm}sum" --check --quiet - >&2 \
  || die "$url doesn't match the $algorithm checksum in $sums_url"

mkdir -p -- "$dest"
if [[ $(head -c 2 -- "$tmp/archive") == PK ]]; then
  mkdir -- "$tmp/unzipped"
  unzip -q -- "$tmp/archive" -d "$tmp/unzipped"
  shopt -s dotglob nullglob
  tops=("$tmp/unzipped"/*)
  if ((${#tops[@]} != 1)) || [[ ! -d ${tops[0]} ]]; then die "$url: expected one top directory in the zip"; fi
  cp -a -- "${tops[0]}/." "$dest/"
else
  tar -xf "$tmp/archive" -C "$dest" --strip-components=1 --no-same-owner
fi
if [[ -n $empty_list ]]; then
  while IFS= read -r name; do
    [[ -n $name && $name != /* && $name != *..* ]] || die "$empty_list: bad path '$name'"
    mkdir -p -- "$(dirname -- "$dest/$name")"
    rm -f -- "$dest/$name"
    : >"$dest/$name"
  done <"$empty_list"
fi

/opt/go-yolo/scripts/verify.sh "$dest" "$hash" "$@"
