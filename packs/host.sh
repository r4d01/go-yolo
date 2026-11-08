# shellcheck shell=bash
# The host pack: what every project gets, whatever its languages.
#
#   base      the shared go-yolo base image (OS, agents, entrypoint)
#   parity    base image packages whose version differs from the host's, as warnings: the
#             base image installs the archive's current versions, and it never downgrades
#   packages  the `extra package` items from .go-yolo/config, at the host's versions
#             (language packs add the packages a project's native code needs)
#   certs     extra CA certificates trusted by the host (/usr/local/share/ca-certificates)
#   env       the host's time zone and proxy settings; plus `extra env` items

host_detect() { return 0; }

host_resolve() {
  local cert name
  plan_add base host image "$BASE_TAG"
  plan_base_parity

  # shellcheck disable=SC2046 # one word per package name
  plan_packages extra $(config_extras package)

  while IFS= read -r -d '' cert; do
    plan_cert "$cert"
  done < <(find "${GOYOLO_CA_DIR:-/usr/local/share/ca-certificates}" -name '*.crt' -type f -print0 2>/dev/null | sort -z)

  if name="$(host_timezone)"; then plan_env host TZ "$name"; fi
  for name in HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY \
              http_proxy https_proxy ftp_proxy all_proxy no_proxy; do
    plan_env host "$name"
  done
  while IFS= read -r name; do
    plan_env extra "$name"
  done < <(config_extras env)
}

# Warn about base image packages whose version differs from the host's. Until the base image
# exists there is nothing to compare; go-yolo resolves the plan again once it is built.
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
