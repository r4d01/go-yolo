#!/usr/bin/env bash
# Locales and the umask.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# en_US.utf8 is spelled differently from the supported list's en_US.UTF-8; sr_RS@latin has a
# modifier; xx_XX.UTF-8 isn't supported; cs_CZ.UTF-8 is excluded in the config.
rm -rf -- "$STATE"
mkdir -p "$STATE"
printf 'exclude locale cs_CZ.UTF-8\n' >"$STATE/config"
TEST_ENV=(LANG=en_US.utf8 LC_TIME=sr_RS@latin LC_PAPER=xx_XX.UTF-8 LC_MONETARY=cs_CZ.UTF-8 LC_NUMERIC=C)
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan 'package   locales=2.41-12'
expect_plan 'locale    en_US.utf8'
expect_plan 'locale    sr_RS@latin'
expect_plan "locale    xx_XX.UTF-8  ⚠ not generated: not in the host's list of supported locales"
[[ $plan_text != *cs_CZ* ]] || fail 'an unpicked locale is in the plan'
[[ $plan_text != *'locale    C'* ]] || fail 'the built-in C locale was planned'
dry_run shell
for expected in "GOYOLO_UMASK=$(umask)" LANG LC_TIME LC_PAPER; do
  printf '%s\n' "${ARGS[@]}" | grep -qxF -- "$expected" || fail "the docker command lacks $expected"
done
TEST_IMAGE_STATUS=1 launch --yes shell 2>/dev/null
dockerfile="$(cat "$STATE/build/Dockerfile")"
[[ $dockerfile == *'localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.utf8'* ]] \
  || fail "Dockerfile does not generate en_US.utf8: $dockerfile"
[[ $dockerfile == *'localedef -i sr_RS@latin -c -f UTF-8 -A /usr/share/locale/locale.alias sr_RS@latin'* ]] \
  || fail 'Dockerfile does not generate sr_RS@latin'
[[ $dockerfile != *xx_XX* && $dockerfile != *cs_CZ* ]] || fail 'Dockerfile generates a left-out locale'

rm -rf -- "$STATE"
TEST_ENV=()
pass "the host's locales are generated in the image; umask and locale variables are passed"
