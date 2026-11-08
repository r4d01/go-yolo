#!/usr/bin/env bash
# Run against an already-built image: bash tests/docker.sh go-yolo:<distro>-<codename>
set -euo pipefail
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  printf 'SKIP: Docker is unavailable; container privilege and firewall checks were not run.\n'
  exit 0
fi
[[ $# == 1 ]] || { printf 'Usage: bash tests/docker.sh IMAGE\n' >&2; exit 2; }
docker image inspect "$1" >/dev/null
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d /tmp/go-yolo-docker.XXXXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/"{go/bin,tools/bin,toolchain/bin}
chmod 755 "$TEST_DIR"
for name in id locale infocmp mktemp tic rm iptables ipset curl dig jq ip python3 setpriv tini; do
  cp "$REPO_DIR/tests/fixtures/shadow" "$TEST_DIR/go/bin/$name"
done
cp "$REPO_DIR/tests/fixtures/probe" "$TEST_DIR/tools/bin/goyolo-probe"
cp "$REPO_DIR/tests/fixtures/probe" "$TEST_DIR/tools/bin/vibe"
chmod +x "$TEST_DIR/go/bin/"* "$TEST_DIR/tools/bin/"*
TEST_UID="$(id -u)"
TEST_GID="$(id -g)"
if ((TEST_UID == 0)); then TEST_UID=1000; fi
if ((TEST_GID == 0)); then TEST_GID=1000; fi

for scenario in none:vibe none:shell allowlist:shell; do
  net=${scenario%:*}
  agent=${scenario#*:}
  args=(--network none)
  if [[ $net == allowlist ]]; then args=(--cap-add=NET_ADMIN --cap-add=NET_RAW); fi
  cmd=()
  if [[ $agent == shell ]]; then cmd=(-c 'exec goyolo-probe'); fi
  docker run --rm --security-opt no-new-privileges "${args[@]}" \
    --mount "type=bind,source=$TEST_DIR,target=/home/goyolo-test" \
    -e GOYOLO_UID="$TEST_UID" -e GOYOLO_GID="$TEST_GID" \
    -e GOYOLO_USER=goyolotest -e GOYOLO_HOME=/home/goyolo-test \
    -e GOYOLO_AGENT="$agent" -e GOYOLO_NET="$net" -e GOYOLO_TMUX=0 \
    -e GOYOLO_UMASK=0007 -e LANG=C.UTF-8 -e LC_TIME=xx_XX.UTF-8 \
    -e GOYOLO_TOOL_PATH=/home/goyolo-test/tools/bin:/home/goyolo-test/toolchain/bin:/home/goyolo-test/go/bin \
    -e PATH=/home/goyolo-test/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$1" "${cmd[@]}"
  [[ ! -e $TEST_DIR/root-shadow ]] || { printf 'FAIL: executable shadow ran as root\n' >&2; exit 1; }
done
