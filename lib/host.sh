# shellcheck shell=bash
# Host detection: distro, release and user.
#
# Sets: HOST_ID HOST_CODENAME BASE_IMAGE   distro, codename and the matching base image
#       HOST_UID HOST_GID HOST_USER        the user the agent runs as in the container
#       HOME_DIR HOME_REAL                 $HOME without a trailing slash, and its real path

SUPPORTED_DISTROS="debian, ubuntu, kali"

# os_release_get KEY FILE — print KEY's value from an os-release file, without quotes.
os_release_get() {
  local line value
  line="$(grep -E "^$1=" "$2" | tail -n 1 || true)"
  value=${line#*=}
  value=${value#[\"\']}
  value=${value%[\"\']}
  printf '%s' "$value"
}

detect_host() {
  local os_release=${GOYOLO_OS_RELEASE:-/etc/os-release}
  [[ -r $os_release ]] || die "cannot read $os_release; supported host distros: $SUPPORTED_DISTROS"
  HOST_ID="$(os_release_get ID "$os_release")"
  HOST_CODENAME="$(os_release_get VERSION_CODENAME "$os_release")"

  case $HOST_ID in
    debian|ubuntu|kali) ;;
    *) die "unsupported host distro '${HOST_ID:-unknown}' (from $os_release); supported: $SUPPORTED_DISTROS" ;;
  esac
  [[ $HOST_CODENAME =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
    || die "VERSION_CODENAME missing or invalid in $os_release; supported host distros: $SUPPORTED_DISTROS"

  # Same distro and release as the host, so host binaries find the same glibc.
  case $HOST_ID in
    debian) BASE_IMAGE="debian:$HOST_CODENAME" ;;
    ubuntu) BASE_IMAGE="ubuntu:$HOST_CODENAME" ;;
    kali) BASE_IMAGE="kalilinux/kali-rolling" ;;
  esac

  HOST_UID="$(id -u)"
  HOST_GID="$(id -g)"
  HOST_USER="$(id -un)"
  [[ $HOME == /* ]] || die "\$HOME must be an absolute path"
  HOME_DIR=${HOME%/}
  HOME_REAL="$(readlink -f "$HOME_DIR" || printf '%s' "$HOME_DIR")"
}
