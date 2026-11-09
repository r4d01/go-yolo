#!/usr/bin/env bash
# android-sdk.sh SDK LICENCES -- PACKAGE@REVISION...
#
# Used by the project images (see catalogs/android.sh): install an Android SDK at SDK in the
# image's build stage (run as you), with each PACKAGE (e.g. "platforms;android-36") at REVISION.
#
#   1. Every package's licence (from Google's repository manifest) must be one you accepted:
#      LICENCES is a comma-separated list of licence ids (accepted in go-yolo.sh --setup), or a
#      directory, the host's SDK/licenses (as the host accepted them). The Android CLI accepts
#      licences without asking, so this check comes first.
#   2. cmdline-tools from the manifest (dl.google.com), checked against its SHA-1, unpacked at
#      SDK/cmdline-tools/latest; its Android CLI (`android sdk install`, with its own Java)
#      installs the packages at their revisions.
#   3. Each package's installed revision must be REVISION: Google only serves the revisions its
#      manifest lists, and the CLI skips one it can't get. If the build fails here, run
#      go-yolo.sh --setup to take the current revision.
set -euo pipefail

die() { printf 'go-yolo: %s\n' "$*" >&2; exit 1; }

if (($# < 4)) || [[ $3 != -- ]]; then die "usage: android-sdk.sh SDK LICENCES -- PACKAGE@REVISION..."; fi
sdk=$1 licences=$2
shift 3
repository=https://dl.google.com/android/repository

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/repository.xml" "$repository/repository2-3.xml" || die "can't download the Android repository manifest"

# manifest PATH — print "licence url sha1" of PATH's current Linux (or any-OS) archive.
manifest() {
  python3 -I - "$tmp/repository.xml" "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for package in root.iter('remotePackage'):
    if package.get('path') != sys.argv[2] or package.find('channelRef').get('ref') != 'channel-0':
        continue
    for archive in package.iter('archive'):
        host = archive.find('host-os')
        if host is None or host.text == 'linux':
            complete = archive.find('complete')
            print(package.find('uses-license').get('ref'), complete.find('url').text,
                  complete.find('checksum').text)
            sys.exit(0)
sys.exit(1)
PY
}

# installed_revision PATH — the revision of installed package PATH ("36.0.0", "2", "23.0"), from
# its package.xml (<revision><major>36</major><minor>0</minor><micro>0</micro></revision>).
installed_revision() {
  python3 -I - "$sdk/${1//;//}/package.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    revision = ET.parse(sys.argv[1]).getroot().find('localPackage/revision')
except (OSError, ET.ParseError):
    sys.exit(1)
parts = [revision.find(tag) for tag in ('major', 'minor', 'micro')]
print('.'.join(part.text for part in parts if part is not None))
PY
}

# 1. The licences.
if [[ -d $licences ]]; then
  accepted="$(find "$licences" -maxdepth 1 -type f -printf '%f,')"
else
  accepted="$licences,"
fi
packages=()
for item in "$@"; do
  read -r licence _ < <(manifest "${item%@*}") || die "${item%@*} isn't in the Android repository manifest (any more)"
  [[ ,$accepted == *",$licence,"* ]] || die "${item%@*} needs the licence $licence, which wasn't accepted (go-yolo.sh --setup)"
  if [[ ${item%@*} != 'cmdline-tools;latest' ]]; then packages+=("$item"); fi
done

# 2. cmdline-tools, then the packages.
read -r _ url sha1 < <(manifest 'cmdline-tools;latest') || die "no cmdline-tools in the Android repository manifest"
curl -fsSL --retry 3 -o "$tmp/cmdline-tools.zip" "$repository/$url" || die "can't download $repository/$url"
printf '%s  %s\n' "$sha1" "$tmp/cmdline-tools.zip" | sha1sum --check --quiet - >&2 || die "$url doesn't match the manifest's SHA-1"
mkdir -p -- "$sdk/cmdline-tools"
unzip -q -- "$tmp/cmdline-tools.zip" -d "$tmp/unzipped"
rm -rf -- "$sdk/cmdline-tools/latest"
mv -- "$tmp/unzipped/cmdline-tools" "$sdk/cmdline-tools/latest"
if ((${#packages[@]})); then
  "$sdk/cmdline-tools/latest/bin/android" --no-metrics --sdk="$sdk" sdk install "${packages[@]}" </dev/null >&2 \
    || die "the Android CLI couldn't install ${packages[*]}"
fi
# The licence files the host has, or only those accepted in the setup.
if [[ -d $licences ]]; then
  rm -rf -- "$sdk/licenses"
  cp -r -- "$licences" "$sdk/licenses"
else
  for file in "$sdk"/licenses/*; do
    [[ -e $file && ,$accepted != *",${file##*/},"* ]] || continue
    rm -f -- "$file"
  done
fi

# 3. The revisions, as pinned. cmdline-tools isn't installed by the CLI: its revision is the
# manifest's, as unpacked (its source.properties: Pkg.Revision=23.0).
for item in "$@"; do
  if [[ ${item%@*} == 'cmdline-tools;latest' ]]; then
    revision="$(sed -n 's/^Pkg\.Revision=//p' "$sdk/cmdline-tools/latest/source.properties")"
  else
    revision="$(installed_revision "${item%@*}")" || die "${item%@*} wasn't installed"
  fi
  [[ $revision == "${item##*@}" ]] \
    || die "${item%@*}: Google now serves revision $revision, the setup pinned ${item##*@} (go-yolo.sh --setup takes the new one)"
done
