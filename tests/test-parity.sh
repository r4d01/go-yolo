#!/usr/bin/env bash
# --parity.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

rm -rf -- "$STATE"
mkdir -p "$STATE"
printf 'extra env API_TOKEN\n' >"$STATE/config"
TEST_ENV=(DOCKER_TEST_RUN_SCRIPT=1 API_TOKEN=s3cr3t-value)
output="$(launch --yes --parity 2>&1)" || fail "--parity found differences where there are none: $output"
for probe in user home directory umask architecture glibc 'time zone' 'tool git' \
  "cert $TEST_DIR/ca/corp/root.crt"; do
  [[ $output == *"✓ $probe "* ]] || fail "--parity lacks a matching '$probe' probe: $output"
done
[[ $output == *'✓ env API_TOKEN'*'sha256:'* && $output != *s3cr3t* ]] || fail "--parity shows a secret: $output"
[[ $output == *'all '*' probes match'* ]] || fail "--parity did not sum up: $output"

TEST_ENV+=(DOCKER_TEST_PARITY_SED='s/^umask\t.*/umask\t0077/')
if output="$(launch --yes --parity 2>&1)"; then fail '--parity exited 0 despite a difference'; fi
[[ $output == *'✗ umask'*'host: '*'container: 0077'* && $output == *'1 of '*' probes differ'* ]] \
  || fail "--parity did not show the difference: $output"
[[ $(launch_in "$TEST_HOME/project" --parity claude) == *"don't name an agent"* ]] || fail '--parity accepted an agent'
rm -rf -- "$STATE"
TEST_ENV=()
pass '--parity runs the same probes on both sides, shows differences and exits 1 for them'
