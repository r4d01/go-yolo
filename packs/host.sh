# shellcheck shell=bash
# The host pack: what every project gets, whatever its languages.
#
#   base      the shared go-yolo base image (OS, agents, entrypoint)
#   packages  the `extra package` items from .go-yolo/config, at the host's versions
#             (language packs add the packages a project's native code needs)
#   certs     extra CA certificates trusted by the host (/usr/local/share/ca-certificates)
#   env       the host's time zone and proxy settings; plus `extra env` items

host_detect() { return 0; }

host_resolve() {
  local cert name
  plan_add base host image "$BASE_TAG"

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
