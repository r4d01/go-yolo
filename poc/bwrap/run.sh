#!/usr/bin/env bash
# run.sh [--net allowlist|open|none] [PROJECT] [-- COMMAND...]
#
# Proof of concept: run tmux (or COMMAND) in a bubblewrap sandbox.
#   - the system (/usr, /etc, /opt, ...) read-only, as on the host: host toolchains just work
#   - $HOME is an empty tmpfs: ~/.ssh, ~/.aws, other projects don't exist
#   - PROJECT (default: the current directory) read-write, at its own path
#   - own PID, IPC, UTS and network namespaces; a clean environment (no tokens, no SSH agent)
#   - network: the sandbox has no network of its own; its only way out is proxy/ on the host,
#     reached through a unix socket, and configured in proxy.yaml (read again when you save it).
#     It adds the AI providers' keys, so they never enter the sandbox, and never connects to your
#     LAN beyond the config's lan list. "allowlist" (the default) allows only the config's allow
#     list, "open" every public host; "none": no proxy at all.
set -euo pipefail

die() { printf 'run.sh: %s\n' "$*" >&2; exit 1; }
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

net=allowlist
if [[ ${1:-} == --net ]]; then net=${2:-}; shift 2 || die "--net needs a value"; fi
case $net in allowlist|open|none) ;; *) die "--net must be allowlist, open or none" ;; esac
project="$PWD"
if [[ ${1:-} != -- && -n ${1:-} ]]; then project=$1; shift; fi
project="$(realpath -- "$project")"
case $project in /|/usr|/usr/*|/etc|/etc/*|"$HOME") die "refusing to mount $project read-write" ;; esac
command=(tmux -L bwrap-poc new-session -s poc)
if [[ ${1:-} == -- ]]; then shift; command=("$@"); fi

args=(--unshare-all --die-with-parent --hostname bwrap-poc)

# The system, read-only. /bin, /lib, ... are links into /usr on most distros.
for d in /usr /etc /opt; do
  if [[ -d $d ]]; then args+=(--ro-bind "$d" "$d"); fi
done
for d in /bin /sbin /lib /lib32 /lib64 /libx32; do
  if [[ -L $d ]]; then args+=(--symlink "$(readlink -- "$d")" "$d")
  elif [[ -d $d ]]; then args+=(--ro-bind "$d" "$d"); fi
done

# Fresh /proc, /dev (with its own ptys), /tmp, /run and an empty $HOME.
args+=(--proc /proc --dev /dev --tmpfs /tmp --tmpfs /run --tmpfs "$HOME")

# The project, read-write.
args+=(--bind "$project" "$project" --chdir "$project")

# A clean environment.
args+=(--clearenv --setenv HOME "$HOME" --setenv USER "$USER" --setenv LOGNAME "$USER"
  --setenv SHELL /bin/bash --setenv PATH /usr/local/bin:/usr/bin:/bin
  --setenv TERM "${TERM:-xterm-256color}" --setenv LANG "${LANG:-C.UTF-8}")

# The network: always through the proxy (the sandbox's own network namespace has only loopback),
# unless "none".
if [[ $net != none ]]; then
  command -v socat >/dev/null || die "the proxy needs socat"
  proxy="$dir/proxy/proxy" config="$dir/proxy.yaml"
  if [[ ! -x $proxy || $dir/proxy/main.go -nt $proxy || $dir/proxy/go.mod -nt $proxy ]]; then
    (cd -- "$dir/proxy" && go build -o proxy .) || die "can't build proxy/ (needs go)"
  fi
  proxy_args=(-config "$config")
  if [[ $net == open ]]; then proxy_args+=(-open); fi
  runtime="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/bwrap-poc.XXXXXX")"
  "$proxy" "${proxy_args[@]}" -listen "unix:$runtime/proxy.sock" 2>>"$dir/proxy.log" &
  proxy_pid=$!
  trap 'kill "$proxy_pid" 2>/dev/null; rm -rf -- "$runtime"' EXIT
  for _ in {1..50}; do [[ -S $runtime/proxy.sock ]] && break; sleep 0.1; done
  [[ -S $runtime/proxy.sock ]] || die "the proxy didn't start (see $dir/proxy.log)"
  printf 'run.sh: network %s, through the proxy (log: %s)\n' "$net" "$dir/proxy.log" >&2
  # Inside, socat turns the socket back into localhost:3128 for the proxy settings.
  url=http://127.0.0.1:3128
  args+=(--ro-bind "$runtime/proxy.sock" /run/proxy.sock
    --setenv HTTP_PROXY "$url" --setenv HTTPS_PROXY "$url" --setenv http_proxy "$url"
    --setenv https_proxy "$url" --setenv NO_PROXY "localhost,127.0.0.1" --setenv no_proxy "localhost,127.0.0.1"
    --setenv JAVA_TOOL_OPTIONS "-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=3128 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=3128")
  # The AI providers' gateway: dummy keys, and base URLs pointing at the proxy, which adds the
  # real keys (the sandbox's environment is cleared, so the real ones never get in).
  gateway_env="$("$proxy" -config "$config" -print-env "$url")" || die "can't read $config"
  while IFS= read -r line; do
    if [[ -n $line ]]; then args+=(--setenv "${line%%=*}" "${line#*=}"); fi
  done <<<"$gateway_env"
  command=(bash -c 'socat TCP-LISTEN:3128,bind=127.0.0.1,fork,reuseaddr UNIX-CONNECT:/run/proxy.sock & exec "$@"' bash "${command[@]}")
fi

bwrap "${args[@]}" -- "${command[@]}"
