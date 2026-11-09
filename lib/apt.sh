# shellcheck shell=bash
# apt: which version of a package the image can get, and which packages own a host path.

# apt_versions NAME... — for each apt package print five tab-separated fields:
#   name, installed version, candidate version, installed_ok, candidate_ok
# "(none)" stands for no version; *_ok is 1 if that version is in the distro archive, the
# only place the image can install from (not third-party repositories, not backports).
# Names apt doesn't know are not printed.
apt_versions() {
  # apt-cache policy prints, per package:
  #   libsqlite3-dev:
  #     Installed: 3.46.1-2
  #     Candidate: 3.46.1-3
  #     Version table:
  #        3.46.1-3 500
  #           500 http://deb.debian.org/debian trixie-security/main amd64 Packages
  #    *** 3.46.1-2 500
  #           500 http://deb.debian.org/debian trixie/main amd64 Packages
  #           100 /var/lib/dpkg/status
  # A version is in the distro archive if one of its sources is this release, its -updates
  # or its -security suite, in a distro component (main, contrib, ..., universe).
  apt-cache policy -- "$@" 2>/dev/null | awk -v codename="$HOST_CODENAME" '
    function flush() {
      if (name != "") print name "\t" installed "\t" candidate "\t" (installed in ok) + 0 "\t" (candidate in ok) + 0
      name = ""
      split("", ok)
    }
    /^[^ ].*:$/ { flush(); name = substr($0, 1, length($0) - 1); installed = candidate = "(none)"; next }
    $1 == "Installed:" { installed = $2; next }
    $1 == "Candidate:" { candidate = $2; next }
    /^ \*\*\* / { version = $2; next }
    /^     [^ ]/ { version = $1; next }
    $2 ~ /^[a-z]+:\/\// {
      suite = "^" codename "(-updates|-security)?/(main|contrib|non-free|non-free-firmware|restricted|universe|multiverse)$"
      if ($3 ~ suite) ok[version] = 1
    }
    END { flush() }'
}

# apt_owners PATH — print the apt packages that own PATH on the host, one per line (without a
# ":amd64"-style suffix); fail if none does.
apt_owners() {
  local owners
  owners="$(dpkg -S -- "$1" 2>/dev/null | head -n 1)" || return 1
  [[ -n $owners ]] || return 1
  owners=${owners%%: *}            # "openjdk-21-jre:amd64, openjdk-21-jre-headless:amd64"
  owners=${owners//, /$'\n'}
  sed 's/:[a-z0-9]*$//' <<<"$owners"
}

# plan_packages GROUP NAME... — apt packages, at the host's version where possible.
#
# The image never downgrades a package. So if the host is behind the archive, the image gets
# the archive's newer version, with a warning in the plan: apt upgrade the host to match.
plan_packages() {
  local group=$1 name installed candidate installed_ok candidate_ok
  shift
  local wanted=() resolved=()
  for name in "$@"; do
    if plan_has package "$name"; then continue; fi
    wanted+=("$name")
  done
  ((${#wanted[@]})) || return 0

  while IFS=$'\t' read -r name installed candidate installed_ok candidate_ok; do
    resolved+=("$name")
    if [[ $installed != "(none)" && $installed == "$candidate" ]] && ((installed_ok)); then
      plan_add package "$group" apt "$name" "$installed"
    elif [[ $installed != "(none)" ]] && ((candidate_ok)) \
      && dpkg --compare-versions "$installed" lt "$candidate"; then
      plan_add package "$group" apt "$name" "$candidate" "host-older=$installed"
    elif [[ $installed == "(none)" ]] && ((candidate_ok)); then
      plan_add package "$group" apt "$name" "$candidate" not-on-host
    elif [[ $installed != "(none)" ]]; then
      plan_add package "$group" skip "$name" "$installed" not-in-archive
    else
      plan_add package "$group" skip "$name" "$candidate" not-in-archive
    fi
  done < <(apt_versions "${wanted[@]}")

  for name in "${wanted[@]}"; do
    if [[ " ${resolved[*]} " != *" $name "* ]]; then plan_add package "$group" skip "$name" - not-found; fi
  done
}
