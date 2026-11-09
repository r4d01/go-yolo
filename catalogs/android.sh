# shellcheck shell=bash
# The Android catalog: an Android SDK at the host's SDK path, the host's or one the host doesn't
# have (D23), and the debug keystore.
#
#   component  SDK packages (platforms;android-36, build-tools;36.0.0, platform-tools,
#              cmdline-tools;latest): with an SDK on the host its packages at the host's
#              revisions; without one, packages from Google's repository manifest at the revision
#              picked in the setup, pinned in the id ("build-tools;36.0.0@36.0.0", ⚠ not on the
#              host). Installed in the image's build stage by scripts/android-sdk.sh: cmdline-tools
#              from the manifest (SHA-1), then its Android CLI; every revision checked
#   license    an Android licence you accepted in the setup (shown in full); with a host SDK, the
#              licences the host accepted (its SDK/licenses files)
#   mount      ~/.android/debug.keystore (read-only): debug APKs are signed as on the host
# With components come ANDROID_HOME and ANDROID_SDK_ROOT, and dl.google.com and maven.google.com
# for --net allowlist.
#
# The SDK path: sdk.dir in the project's local.properties, else ANDROID_HOME, ANDROID_SDK_ROOT,
# else ~/Android/Sdk. Release keystores and keystore.properties are secrets: never offered.

ANDROID_REPOSITORY=https://dl.google.com/android/repository/repository2-3.xml

# A hint for the setup picker: an Android Gradle project.
android_detect() {
  [[ -f local.properties ]] && grep -q '^sdk\.dir' local.properties && return 0
  grep -qs 'com\.android\.' build.gradle build.gradle.kts app/build.gradle app/build.gradle.kts
}

# The SDK path, as Gradle would find it (see above).
android_sdk_dir() {
  local dir
  dir="$(sed -n 's/^sdk\.dir *= *//p' local.properties 2>/dev/null | head -n 1)"
  dir=${dir//\\:/:}
  dir=${dir:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME_DIR/Android/Sdk}}}
  printf '%s' "${dir%/}"
}

# android_host_packages SDK — the packages installed in host SDK SDK, one "path<TAB>revision" per
# line, from their package.xml files (<localPackage path="platforms;android-36"> ... <revision>
# <major>2</major></revision>).
android_host_packages() {
  local files=()
  mapfile -t files < <(find "$1" -maxdepth 4 -name package.xml 2>/dev/null)
  ((${#files[@]})) || return 0
  python3 -I - "${files[@]}" <<'PY'
import sys, xml.etree.ElementTree as ET
for name in sys.argv[1:]:
    try:
        package = ET.parse(name).getroot().find('localPackage')
    except ET.ParseError:
        continue
    if package is None:
        continue
    revision = package.find('revision')
    parts = [revision.find(tag) for tag in ('major', 'minor', 'micro')]
    print(package.get('path') + '\t' + '.'.join(p.text for p in parts if p is not None))
PY
}

# android_manifest — print the path of Google's repository manifest, downloaded at most once a
# day (into ~/.cache/go-yolo); fail if there is none (offline on a first setup).
android_manifest() {
  local file
  if [[ -n ${GOYOLO_ANDROID_MANIFEST:-} ]]; then printf '%s' "$GOYOLO_ANDROID_MANIFEST"; return 0; fi
  file="${XDG_CACHE_HOME:-$HOME_DIR/.cache}/go-yolo/android-repository2-3.xml"
  if [[ ! -s $file || -n $(find "$file" -mmin +1440 2>/dev/null) ]]; then
    mkdir -p -- "${file%/*}"
    if curl -fsSL --max-time 30 -o "$file.tmp" "$ANDROID_REPOSITORY" 2>/dev/null; then
      mv -- "$file.tmp" "$file"
    else
      rm -f -- "$file.tmp"
    fi
  fi
  [[ -s $file ]] && printf '%s' "$file"
}

# android_manifest_packages — the manifest's stable packages with a Linux archive, one
# "path<TAB>revision<TAB>licence" per line, newest first within each kind.
android_manifest_packages() {
  local manifest
  manifest="$(android_manifest)" || return 1
  python3 -I - "$manifest" <<'PY'
import sys, xml.etree.ElementTree as ET
rows = []
for package in ET.parse(sys.argv[1]).getroot().iter('remotePackage'):
    if package.find('channelRef').get('ref') != 'channel-0':
        continue
    hosts = [a.find('host-os') for a in package.iter('archive')]
    if not any(h is None or h.text == 'linux' for h in hosts):
        continue
    revision = package.find('revision')
    parts = [revision.find(tag) for tag in ('major', 'minor', 'micro')]
    numbers = [int(p.text) for p in parts if p is not None]
    rows.append((package.get('path'), '.'.join(map(str, numbers)), package.find('uses-license').get('ref')))
for path, revision, licence in rows:
    print(f'{path}\t{revision}\t{licence}')
PY
}

# android_licence_text ID — the text of licence ID, from the manifest.
android_licence_text() {
  local manifest
  manifest="$(android_manifest)" || return 1
  python3 -I - "$manifest" "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
for licence in ET.parse(sys.argv[1]).getroot().iter('license'):
    if licence.get('id') == sys.argv[2]:
        print(licence.text.strip())
PY
}

# android_offered — the manifest packages the picker offers without a host SDK: cmdline-tools,
# platform-tools, and the newest stable platforms and build-tools (three each), plus the
# platform of the project's compileSdk. One "path<TAB>revision<TAB>licence" per line.
android_offered() {
  local compile path revision licence platforms=0 build_tools=0
  compile="$(android_compile_sdk)" || compile=""
  while IFS=$'\t' read -r path revision licence; do
    case $path in
      'cmdline-tools;latest'|platform-tools) ;;
      platforms\;android-[0-9]*)
        [[ $path =~ ^platforms\;android-[0-9]+(\.[0-9]+)?$ ]] || continue
        if [[ $path != "platforms;android-$compile" ]]; then
          ((platforms++ < 3)) || continue
        fi
        ;;
      build-tools\;[0-9]*)
        [[ $path =~ ^build-tools\;[0-9.]+$ ]] || continue
        ((build_tools++ < 3)) || continue
        ;;
      *) continue ;;
    esac
    printf '%s\t%s\t%s\n' "$path" "$revision" "$licence"
  done < <(android_manifest_packages | sort -t $'\t' -k1,1 -V -r)
}

# The project's compileSdk (compileSdk = 36, compileSdk 36, compileSdkVersion 36); fails if none.
android_compile_sdk() {
  local file value
  for file in app/build.gradle.kts app/build.gradle build.gradle.kts build.gradle; do
    [[ -f $file ]] || continue
    value="$(sed -n -E 's/^ *compileSdk(Version)? *=? *([0-9]+).*/\2/p' "$file" | head -n 1)"
    if [[ -n $value ]]; then printf '%s' "$value"; return 0; fi
  done
  return 1
}

# Candidates for the setup picker (see lib/setup.sh): "mode kind id hint name description".
android_discover() {
  local hint=0 sdk path revision licence compile note file
  command -v python3 >/dev/null 2>&1 || return 0   # the package lists are XML
  if android_detect; then hint=1; fi
  sdk="$(android_sdk_dir)"
  if [[ -n $(android_host_packages "$sdk") ]]; then
    while IFS=$'\t' read -r path revision; do
      printf 'image\tcomponent\t%s\t%s\t%s\t%s %s (on the host, %s) · install: Android CLI at the host'"'"'s revision\n' \
        "$path" "$hint" "$sdk/${path//;//}" "$path" "$revision" "$sdk"
    done < <(android_host_packages "$sdk" | LC_ALL=C sort)
  elif android_detect || catalog_picked android; then
    # Without an SDK on the host: offer the manifest's (never pre-selected, D23).
    compile="$(android_compile_sdk)" || compile=""
    while IFS=$'\t' read -r path revision licence; do
      note=""
      if [[ $path == "platforms;android-$compile" ]]; then note=", suggested: the project's compileSdk"; fi
      if [[ $path == 'cmdline-tools;latest' ]]; then note=", needed with any other package"; fi
      printf 'image\tcomponent\t%s@%s\t0\t%s\t○ %s %s (not on the host%s; licence %s) · install: Android CLI at %s\n' \
        "$path" "$revision" "$sdk/${path//;//}" "$path" "$revision" "$note" "$licence" "$sdk"
    done < <(android_offered)
    while IFS= read -r licence; do
      printf 'image\tlicense\t%s\t1\t%s\tlicence %s (accepted in the setup)\n' "$licence" "$licence" "$licence"
    done < <(picked_ids android license)
  fi
  file="$HOME_DIR/.android/debug.keystore"
  if [[ -f $file ]]; then
    printf 'mount\tmount\tdebug-keystore\t%s\t%s\tdebug keystore %s (read-only: debug APKs signed as on the host)\n' "$hint" "$file" "$file"
  fi
}

# After the picker (see lib/setup.sh): with packages the host doesn't have, pin cmdline-tools too,
# and ask for each licence they need that isn't accepted yet: shown in full, accepted only with a
# yes. MODE "ask" in a terminal; otherwise nothing is accepted (the plan warns).
android_setup() {
  local mode=$1 id path revision licence answer
  local -A needed=() offered=()
  mapfile -t ids < <(picked_ids android component | grep '@' || true)
  ((${#ids[@]})) || return 0
  while IFS=$'\t' read -r path revision licence; do offered[$path]="$revision"$'\t'"$licence"; done < <(android_manifest_packages)
  if ! printf '%s\n' "${ids[@]}" | grep -q '^cmdline-tools;latest@' && [[ -n ${offered['cmdline-tools;latest']:-} ]]; then
    id="cmdline-tools;latest@${offered['cmdline-tools;latest']%%$'\t'*}"
    CONFIG_ITEMS+=("image"$'\t'"android"$'\t'"component"$'\t'"$id")
    ids+=("$id")
    note "the Android SDK needs cmdline-tools: picked $id too"
  fi
  for id in "${ids[@]}"; do
    licence=${offered[${id%@*}]#*$'\t'}
    if [[ -n ${offered[${id%@*}]:-} ]] && ! picked android license "$licence"; then needed[$licence]=1; fi
  done
  for licence in "${!needed[@]}"; do
    if [[ $mode != ask ]]; then
      warn "the Android licence $licence isn't accepted: go-yolo.sh --setup shows it and asks"
      continue
    fi
    printf '\n%s\n\n' "$(android_licence_text "$licence")" >&2
    read -r -p "go-yolo: the Android packages you picked need the licence $licence above. Accept it? [y/N]: " answer
    if [[ $answer == y || $answer == yes ]]; then
      CONFIG_ITEMS+=("image"$'\t'"android"$'\t'"license"$'\t'"$licence")
    else
      warn "licence $licence not accepted: the Android packages that need it won't be installed"
    fi
  done
}

android_resolve() {
  local sdk id path revision licence host=0 items=() licences=() flags
  local -A host_revision=() licence_of=()
  catalog_picked android || return 0
  sdk="$(android_sdk_dir)"
  while IFS=$'\t' read -r path revision; do host_revision[$path]=$revision; host=1; done < <(android_host_packages "$sdk")
  # The cached manifest (if any) says which licence each package needs; no network here.
  if [[ -n ${GOYOLO_ANDROID_MANIFEST:-} || -s ${XDG_CACHE_HOME:-$HOME_DIR/.cache}/go-yolo/android-repository2-3.xml ]]; then
    while IFS=$'\t' read -r path revision licence; do licence_of[$path]=$licence; done < <(android_manifest_packages)
  fi
  if ((host)); then
    while IFS= read -r licence; do licences+=("$licence"); done < <(find "$sdk/licenses" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
  else
    while IFS= read -r licence; do licences+=("$licence"); done < <(picked_ids android license)
  fi

  while IFS= read -r id; do
    path=${id%@*}
    flags=-
    if [[ $id == *@* ]]; then
      revision=${id##*@}
      if ((host)); then
        plan_add component android skip "$path" "$revision" not-with-host-sdk
        continue
      fi
      flags=not-on-host
    elif [[ -n ${host_revision[$path]:-} ]]; then
      revision=${host_revision[$path]}
    else
      plan_add component android skip "$path" - gone
      continue
    fi
    licence=${licence_of[$path]:-}
    if [[ -n $licence && " ${licences[*]} " != *" $licence "* ]]; then
      plan_add component android skip "$path" "$revision" "licence-missing=$licence"
      continue
    fi
    plan_add component android install "$path" "$revision" "$flags"
    items+=("$path@$revision")
  done < <(picked_ids android component)

  if ((${#items[@]})); then
    flags=-
    if ((!host)); then flags=not-on-host; fi
    plan_build_dir toolchain android "$sdk" "Android SDK, ${#items[@]} packages" "$flags" \
      "/opt/go-yolo/scripts/android-sdk.sh $(shell_words "$sdk" "$(IFS=,; printf '%s' "${licences[*]:-none}")") -- $(shell_words "${items[@]}")"
    for licence in "${licences[@]}"; do plan_add license android accepted "$licence"; done
    plan_env android ANDROID_HOME "$sdk"
    plan_env android ANDROID_SDK_ROOT "$sdk"
    plan_domain android dl.google.com
    plan_domain android maven.google.com
  fi
  if picked android mount debug-keystore; then
    if [[ -f $HOME_DIR/.android/debug.keystore ]]; then
      plan_mount android "$HOME_DIR/.android/debug.keystore"
    else
      plan_add mount android skip debug-keystore - gone
    fi
  fi
}

# --parity probe (see lib/parity.sh): the revision of each planned SDK package.
android_probe() {
  local line kind group method name value flags sdk="" revision
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name value flags <<<"$line"
    if [[ $group == android && $kind == toolchain ]]; then sdk=$name; fi
  done
  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name value flags <<<"$line"
    [[ $kind == component && $method != skip ]] || continue
    # <revision><major>36</major><minor>0</minor><micro>0</micro></revision> → 36.0.0
    revision="$(tr -d '\n ' <"$sdk/${name//;//}/package.xml" 2>/dev/null \
      | sed -n 's:.*<localPackage[^>]*>.*<revision>\(.*\)</revision>.*:\1:p' \
      | sed -e 's:</[a-z]*>::g' -e 's:<major>::; s:<minor>:.:; s:<micro>:.:; s:<preview>.*::')"
    printf 'component %s\t%s\n' "$name" "${revision:-(missing)}"
  done
}
