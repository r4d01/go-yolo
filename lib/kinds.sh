# shellcheck shell=bash
# The plan's item kinds and flags, each declared once.
#
# Sets: KIND_RANK   kind -> sort rank (the order the plan is shown and the image built in)
#       KIND_IMAGE  kind -> 1 if its items go into the image (their lines are hashed into the tag)
#       KIND_LABEL  kind -> how an item is shown: {name} and {value} are replaced
#       FLAG_TYPE   flag -> behaviour (code acts on it; see has_flag) | note | warning
#       FLAG_TEXT   flag -> its note: %s is the item's name, %v the flag's value (host-older=%v),
#                   %d the host distro

declare -A KIND_RANK=() KIND_IMAGE=() KIND_LABEL=() FLAG_TYPE=() FLAG_TEXT=()

# kind       rank  image  shown as
while read -r kind rank image label; do
  [[ -n $kind && $kind != '#'* ]] || continue
  KIND_RANK[$kind]=$rank KIND_IMAGE[$kind]=$image KIND_LABEL[$kind]=$label
done <<'EOF'
base         10    1      {name}
toolchain    11    1      {name} ({value})
tools        12    1      {name} ({value})
tool         12    1      {name} ({value})
link         13    1      {name} → {value}
package      14    1      {name}={value}
parity       15    0      {name}={value}
cert         16    1      {name}
locale       17    1      {name}
mount        20    0      {name} (read-only)
cache        21    0      {name} (project volume {value})
domain       23    0      {name}
env          29    0      {name}={value}
EOF

# flag                 type       note
while read -r flag type text; do
  [[ -n $flag && $flag != '#'* ]] || continue
  FLAG_TYPE[$flag]=$type FLAG_TEXT[$flag]=$text
done <<'EOF'
on-path                behaviour  first on PATH
derived                behaviour  set by go-yolo
user-owned             behaviour  owned by you, as on the host
download               note       installed from %v, checked against its checksum and the host's files
built                  note       built in the image, checked against the host's file
copy-picked            note       copied from the host, as .go-yolo/config asks
no-recipe              note       copied from the host: no recipe knows how to install it
local-build            note       copied from the host: built from local sources
custom-build           note       copied from the host: built with settings go install can't repeat
other-go               note       copied from the host: built with %v, not with the host's Go
private-module         note       copied from the host: a private module (GOPRIVATE), which the build can't fetch
no-go                  note       copied from the host: building it needs the Go toolchain, which isn't picked
renamed                note       copied from the host: renamed after it was installed
not-go-binary          note       copied from the host: not a Go binary
hidden                 note       value not shown
empty                  note       empty value
not-set                warning    picked, but not set on the host: not passed
gone                   warning    picked, but the host doesn't have it (any more): go-yolo.sh --setup
host-behind            warning    the base image has this newer version, the host has %v (apt upgrade the host to match)
host-ahead             warning    the base image has this older version, the host has %v (go-yolo.sh --rebuild updates the base image)
host-older             warning    the host has %v, an older version: the image gets the archive's version (apt upgrade the host to match)
not-on-host            warning    not installed on the host: a build that needs it works here but fails on the host
not-in-archive         warning    not installed: the host's version isn't in the %d archive (third-party repository, or apt upgrade the host)
not-found              warning    no such apt package
may-hold-secrets       warning    may hold credentials: the agent can read it
not-on-path            warning    not on the host's PATH: neither side has it
not-in-bin-dir         warning    not copied: it isn't installed as <dir>/bin/<name>
outside-repo           warning    outside the repository: read-only in the container
no-locales-package     warning    not generated: the locales package isn't in the plan
unsupported-locale     warning    not generated: not in the host's list of supported locales
EOF
unset kind rank image label flag type text

# kind_rank KIND — its sort rank (unknown kinds last).
kind_rank() { printf '%s' "${KIND_RANK[$1]:-99}"; }

# kind_text KIND NAME VALUE — the item as shown in the plan. A missing ("-") or hidden
# ("sha256:...") value leaves out "={value}", so a secret's hash is never shown.
kind_text() {
  local label=${KIND_LABEL[$1]:-'{name}'} name=$2 value=$3
  if [[ $label == *'={value}' && ( $value == - || $value == sha256:* ) ]]; then label=${label%'={value}'}; fi
  label=${label//'{name}'/$name}
  printf '%s' "${label//'{value}'/$value}"
}

# flag_note FLAG NAME — explain one flag in words; warnings start with "⚠".
flag_note() {
  local flag=${1%%=*} value="" text
  if [[ $1 == *=* ]]; then value=${1#*=}; fi
  text=${FLAG_TEXT[$flag]:-$1}
  text=${text//%s/$2}
  text=${text//%v/$value}
  text=${text//%d/$HOST_ID}
  if [[ ${FLAG_TYPE[$flag]:-} == warning ]]; then text="⚠ $text"; fi
  printf '%s' "$text"
}

# has_flag FLAGS FLAG — true if the comma-separated FLAGS include behaviour flag FLAG. Notes
# and warnings only explain; code never acts on them (asking for one is a bug).
has_flag() {
  [[ ${FLAG_TYPE[$2]:-} == behaviour ]] || die "internal error: '$2' is not a behaviour flag"
  [[ ,$1, == *,"$2",* ]]
}

# add_flag FLAGS FLAG — FLAGS with FLAG added ("-" means none).
add_flag() {
  if [[ $1 == - || -z $1 ]]; then printf '%s' "$2"; else printf '%s,%s' "$1" "$2"; fi
}
