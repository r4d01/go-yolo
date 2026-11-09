#!/usr/bin/env bash
# Launcher regressions: no Docker daemon, Go installation, or host config changes needed.
#
#   bash tests/run.sh             run every tests/test-*.sh
#   bash tests/run.sh go java     run only tests/test-go.sh and tests/test-java.sh
#
# Each test file starts from fresh fixtures (tests/lib.sh); see tests/README.md.
set -uo pipefail
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

files=()
if (($#)); then
  for name in "$@"; do files+=("$TESTS_DIR/test-$name.sh"); done
else
  files=("$TESTS_DIR"/test-*.sh)
fi

output="$(mktemp)"
trap 'rm -f -- "$output"' EXIT
passed=0
failed=()
for file in "${files[@]}"; do
  name="$(basename -- "$file" .sh)"
  name=${name#test-}
  if [[ ! -f $file ]]; then
    printf 'FAIL: no such test file: %s\n' "$file"
    failed+=("$name")
    continue
  fi
  printf '# %s\n' "$name"
  # A test file prints "ok - ..." per group and stops at its first failure.
  bash "$file" >"$output" 2>&1
  status=$?
  cat -- "$output"
  passed=$((passed + $(grep -c '^ok - ' "$output")))
  if ((status != 0)); then failed+=("$name"); fi
done

if ((${#failed[@]})); then
  printf 'Passed %d launcher regression groups; FAILED in: %s\n' "$passed" "${failed[*]}"
  exit 1
fi
printf 'Passed %d launcher regression groups.\n' "$passed"
