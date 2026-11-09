# shellcheck shell=bash
# Install recipes (D18): an item is installed in the image from its source, at the host's path
# and with the host's owner, instead of being copied from the host.
#
#   download  a vendor's archive, checked against the checksum the vendor publishes (fetched from
#             the vendor while the image builds), unpacked at the host's path
#             (scripts/install-archive.sh)
#   build     a file built in a separate build stage of the image (e.g. `go install
#             path@version`), with the host's paths so the result can be byte-identical; only
#             the file is copied into the image, not what the build downloaded
#
# Either way the result is checked against the host's: the hash of a few of the host's files (a
# toolchain's bin/go and VERSION, a JDK's release and bin/java, a tool's binary) is part of the
# item's value ("go1.27.0, 1db869c560a19357"), and the build fails if the installed files
# differ (scripts/verify.sh). A host change of those files changes the value, so it rebuilds.
# A copy (plan_copy) is the fallback for items no recipe knows; its note says why.
#
# Sets: RECIPES  "kind<TAB>name" -> what the Dockerfile (lib/image.sh) needs:
#                  download: url<TAB>algorithm<TAB>checksum url<TAB>file...
#                  build:    a shell command for the build stage, writing the file to "$OUT"

declare -A RECIPES=()

# verify_hash DIR FILE... — the hash scripts/verify.sh checks: the first 16 hex digits of the
# SHA-256 of `sha256sum FILE...` run in DIR.
verify_hash() {
  (cd -- "$1" && sha256sum -- "${@:2}") | sha256sum | cut -c1-16
}

# install_target KIND GROUP DIR — set TARGET to the real path of host directory DIR, where an
# item is installed or copied in the image, after the safety checks; fail if the plan already
# has it. A symlinked DIR gets a link item, so the path the host uses works too. (Not in $(...):
# the link item and a refusal must reach this shell.)
TARGET=""
install_target() {
  local kind=$1 group=$2 dir=$3
  TARGET="$(realpath -- "$dir")"
  if is_system_dir "$TARGET"; then
    die "refusing to put $dir into the image: it is a system directory, your home directory or one of its parents"
  fi
  if is_under "$PROJECT_DIR" "$TARGET"; then
    die "refusing to put $dir into the image: it contains the project"
  fi
  if plan_has "$kind" "$TARGET"; then return 1; fi
  if [[ $TARGET != "$(realpath -ms -- "$dir")" ]]; then plan_add link "$group" link "$dir" "$TARGET"; fi
}

# owner_flags PATH [FLAGS] — FLAGS with user-owned first if you own PATH on the host.
owner_flags() {
  local flags=${2:--}
  if [[ $(stat -c %u -- "$1") == "$HOST_UID" ]]; then
    if [[ $flags == - ]]; then flags=user-owned; else flags="user-owned,$flags"; fi
  fi
  printf '%s' "$flags"
}

# plan_download KIND GROUP DIR VERSION FLAGS URL ALGORITHM CHECKSUM_URL FILE... — install the
# vendor's archive at URL as host directory DIR. ALGORITHM (sha256, sha512) and CHECKSUM_URL are
# the vendor's checksum of the archive; FILE... (relative to DIR) are checked against the host's.
# FLAGS: "-", or e.g. on-path.
plan_download() {
  local kind=$1 group=$2 dir=$3 version=$4 flags=$5 url=$6 algorithm=$7 sums=$8 real host
  shift 8
  install_target "$kind" "$group" "$dir" || return 0
  real=$TARGET
  host=${url#*://}
  flags="$(owner_flags "$real" "$(add_flag "$flags" "download=${host%%/*}")")"
  plan_add "$kind" "$group" download "$real" "$version, $(verify_hash "$real" "$@")" "$flags"
  RECIPES[$kind$'\t'$real]="$url"$'\t'"$algorithm"$'\t'"$sums"$'\t'"$*"
}

# plan_build KIND GROUP FILE VALUE COMMAND — build host file FILE in the image's build stage with
# COMMAND (a shell command run as you, with your HOME, that writes the file as "$OUT/<its name>"),
# then check it against the host's. VALUE says what is built (e.g. path@version).
plan_build() {
  local kind=$1 group=$2 file=$3 value=$4 command=$5
  if plan_has "$kind" "$file"; then return 0; fi
  plan_add "$kind" "$group" build "$file" "$value, $(verify_hash "${file%/*}" "${file##*/}")" "$(owner_flags "$file" built)"
  RECIPES[$kind$'\t'$file]=$command
}

# plan_copy_file KIND GROUP FILE REASON — copy one host file (e.g. a tool no recipe can build) into
# the image at the same path, owned as on the host; REASON is the flag saying why.
plan_copy_file() {
  local kind=$1 group=$2 file=$3 reason=$4
  if plan_has "$kind" "$file"; then return 0; fi
  plan_add "$kind" "$group" copy "$file" "$(sha256sum <"$file" | cut -c1-16)" "$(owner_flags "$file" "$reason")"
}

# shell_words WORD... — the words for a shell command line, each quoted only if it needs to be
# (printf %q quotes a "," too, which makes URLs and lists hard to read).
shell_words() {
  local word out=()
  for word in "$@"; do
    if [[ -n $word && $word != *[^A-Za-z0-9_=/.:,@%+-]* ]]; then out+=("$word"); else out+=("$(printf '%q' "$word")"); fi
  done
  printf '%s' "${out[*]}"
}

# recipe KIND NAME — print the recipe recorded for that plan item.
recipe() { printf '%s' "${RECIPES[$1$'\t'$2]-}"; }
