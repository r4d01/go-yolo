# shellcheck shell=bash
# The host catalog: what every project can get, whatever its languages.
#
#   base      the shared go-yolo base image (OS, agents, entrypoint): always
#   parity    base image packages whose version differs from the host's, as warnings: always
#   cert      extra CA certificates trusted by the host (/usr/local/share/ca-certificates)
#   locale    the locales of LANG, LC_ALL and LC_* (with the locales package to generate them)
#   tz        the host's time zone (TZ)
#   env       the host's proxy settings; any host variable added by name
#   package   apt packages added by name, at the host's versions
#   tool      host commands added by name (their install directory, or their apt packages)
#   mount     host paths added by name, read-only

HOST_PROXY_VARS=(HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY
                 http_proxy https_proxy ftp_proxy all_proxy no_proxy)

host_detect() { return 0; }

# Candidates for the setup picker (see lib/setup.sh): "mode kind id hint name description".
host_discover() {
  local cert name zone
  while IFS= read -r -d '' cert; do
    printf 'image\tcert\t%s\t1\t%s\tCA certificate %s\n' "$cert" "$cert" "${cert##*/}"
  done < <(find "${GOYOLO_CA_DIR:-/usr/local/share/ca-certificates}" -name '*.crt' -type f -print0 2>/dev/null | sort -z)
  while IFS= read -r name; do
    printf 'image\tlocale\t%s\t1\t%s\tlocale %s (generated in the image)\n' "$name" "$name" "$name"
  done < <(host_locales)
  if zone="$(host_timezone)"; then printf 'env\ttz\t-\t1\tTZ\ttime zone %s\n' "$zone"; fi
  for name in "${HOST_PROXY_VARS[@]}"; do
    [[ -n ${!name:-} ]] || continue
    if looks_secret "$name" "${!name}"; then
      printf 'env\tenv\t%s\t0\t%s\t%s (⚠ looks like a secret: its value is never shown)\n' "$name" "$name" "$name"
    else
      printf 'env\tenv\t%s\t1\t%s\t%s=%s\n' "$name" "$name" "$name" "${!name}"
    fi
  done
}

host_resolve() {
  local cert name locales=()
  plan_add base host image "$BASE_TAG"
  plan_base_parity
  if [[ -n ${GOYOLO_TOOLS:-} ]]; then
    warn "GOYOLO_TOOLS is no longer used; add host commands in go-yolo.sh --setup (Java, Maven and Gradle come with the java items)"
  fi

  # shellcheck disable=SC2046 # one word per package name
  plan_packages extra $(picked_ids host package)
  while IFS= read -r name; do plan_tool extra "$name"; done < <(picked_ids host tool)
  while IFS= read -r name; do
    if [[ -e $name ]]; then plan_mount extra "$name"; else plan_add mount extra skip "$name" - gone; fi
  done < <(picked_ids host mount)

  while IFS= read -r cert; do
    if [[ -f $cert ]]; then plan_cert "$cert"; else plan_add cert host skip "$cert" - gone; fi
  done < <(picked_ids host cert)

  mapfile -t locales < <(picked_ids host locale)
  if ((${#locales[@]})); then
    plan_packages host locales
    for name in "${locales[@]}"; do plan_locale "$name"; done
  fi

  if picked host tz - && name="$(host_timezone)"; then plan_env host TZ "$name"; fi
  while IFS= read -r name; do
    if [[ " ${HOST_PROXY_VARS[*]} " == *" $name "* ]]; then plan_env host "$name"; else plan_env extra "$name"; fi
  done < <(picked_ids host env)
}

# Warn about base image packages whose version differs from the host's (go-yolo builds the base
# image before it resolves the plan, so there is something to compare).
plan_base_parity() {
  local name version host_version
  local -A host=()
  while IFS=$'\t' read -r name version; do
    host[$name]=$version
  done < <(host_packages)

  while IFS=$'\t' read -r name version; do
    host_version=${host[$name]:-}
    if [[ -z $host_version || $host_version == "$version" ]]; then continue; fi
    if dpkg --compare-versions "$host_version" lt "$version"; then
      plan_add parity host check "$name" "$version" "host-behind=$host_version"
    else
      plan_add parity host check "$name" "$version" "host-ahead=$host_version"
    fi
  done < <(base_packages)
}

# The host's installed packages for its own architecture, one "name<TAB>version" per line.
host_packages() {
  local arch
  arch="$(dpkg --print-architecture)"
  # dpkg-query prints e.g. "ii \tzlib1g\tamd64\t1:1.3.dfsg+really1.3.1-1+b1".
  dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Architecture}\t${Version}\n' 2>/dev/null \
    | awk -F'\t' -v arch="$arch" '$1 ~ /^ii/ && ($3 == arch || $3 == "all") { print $2 "\t" $4 }'
}

# The locales the host's LANG, LC_ALL and LC_* use, once each. C and POSIX are built in.
host_locales() {
  local var
  for var in "${LOCALE_VARS[@]}"; do
    case ${!var:-} in
      ''|C|POSIX|C.*) ;;
      *) printf '%s\n' "${!var}" ;;
    esac
  done | sort -u
}

# The host's time zone name (e.g. Europe/Prague): $TZ, /etc/timezone or the /etc/localtime link.
host_timezone() {
  local zone
  if [[ -n ${TZ:-} ]]; then
    zone=$TZ
  elif [[ -s /etc/timezone ]]; then
    zone="$(head -n 1 /etc/timezone)"
  elif zone="$(readlink /etc/localtime)" && [[ $zone == */zoneinfo/* ]]; then
    zone=${zone#*/zoneinfo/}
  else
    return 1
  fi
  [[ -n $zone ]] && printf '%s' "$zone"
}

# --parity probe (see lib/parity.sh). It runs on the host and, as a copy, in the container, so
# it may only use the plan (PLAN) and commands both sides have.
host_probe() {
  local line kind group method name value flags tool version
  printf 'user\t%s (%s:%s)\n' "$(id -un)" "$(id -u)" "$(id -g)"
  printf 'home\t%s\n' "$HOME"
  printf 'directory\t%s\n' "$PWD"
  printf 'umask\t%s\n' "$(umask)"
  printf 'architecture\t%s\n' "$(uname -m)"
  printf 'glibc\t%s\n' "$(getconf GNU_LIBC_VERSION 2>/dev/null)"
  # Each locale category as programs see it (and complaints about missing locales).
  while IFS= read -r line; do
    printf 'locale %s\t%s\n' "${line%%=*}" "${line#*=}"
  done < <(locale 2>&1)
  printf 'time zone\t%s\n' "$(date '+%Z %z')"
  for tool in gcc make git python3; do
    version="(missing)"
    if command -v "$tool" >/dev/null 2>&1; then version="$("$tool" --version 2>&1 | head -n 1)"; fi
    printf 'tool %s\t%s\n' "$tool" "$version"
  done

  for line in "${PLAN[@]}"; do
    IFS=$'\t' read -r kind group method name value flags <<<"$line"
    if [[ $method == skip ]]; then continue; fi
    case $kind in
      env)
        # Values go-yolo sets itself are checked by their effect (time zone, go env, ...). (A probe
        # runs in the container too, without go-yolo's helpers, so no has_flag here.)
        if [[ ,$flags, == *,derived,* ]]; then continue; fi
        if [[ $value == sha256:* ]]; then
          printf 'env %s\tsha256:%s\n' "$name" "$(printf '%s' "${!name-}" | sha256sum | cut -c1-12)"
        else
          printf 'env %s\t%s\n' "$name" "${!name-(unset)}"
        fi
        ;;
      package)
        version="$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null)" || version="(not installed)"
        printf 'package %s\t%s\n' "$name" "${version:-(not installed)}"
        ;;
      toolchain|tool)
        # Installed, built or copied: compare the files, not just the version. A directory by
        # its files' names, sizes and link targets (contents would take too long), a file by
        # its contents. (Apt toolchains are checked as packages.)
        if [[ $method == apt ]]; then continue; fi
        if [[ -d $name ]]; then
          version="$(find "$name" \( -type f -o -type l \) -printf '%P %s %l\n' 2>/dev/null | LC_ALL=C sort | sha256sum | cut -c1-12)"
          printf '%s %s\tfiles: %s\n' "$kind" "$name" "$version"
        elif [[ -f $name ]]; then
          printf '%s %s\tsha256:%s\n' "$kind" "$name" "$(sha256sum <"$name" | cut -c1-12)"
        else
          printf '%s %s\t(missing)\n' "$kind" "$name"
        fi
        ;;
      cert)
        version="(missing)"
        if [[ -r $name ]]; then version="sha256:$(sha256sum <"$name" | cut -c1-12)"; fi
        printf 'cert %s\t%s\n' "$name" "$version"
        ;;
    esac
  done
}
