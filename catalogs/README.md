# Catalogs

A catalog knows one ecosystem: what the host has of it, and which plan items mirror that in
the project's container. `go-yolo.sh` loads every `catalogs/<name>.sh` (the `host` catalog first,
then the rest by name), so adding a catalog means adding a file. `docs/PLAN.md` (3.3) describes
where catalogs are heading: from detecting what a project needs to offering what the host has in
a setup picker, and from copying host files to installing them from their source.

## The contract (today)

A catalog defines functions prefixed with its name:

| function | job | required |
|----------|-----|----------|
| `<name>_detect` | true if this project uses the ecosystem (look at files in the project root, the current directory) | yes |
| `<name>_resolve` | ask the host's own tools and add plan items with the helpers below | yes |
| `<name>_probe` | `--parity` probe: print `name<TAB>value` lines | no |

Rules:

- **Ask the host's tools**, never guess: `go env`, the JDK's `release` file, `dpkg -S`. Read
  versions on every run; don't store them.
- **Only through the helpers.** They apply `.go-yolo/config`'s `exclude` lines, the mount and
  copy safety checks, and skip items the plan already has.
- **A probe runs on both sides.** It is copied into the container as text (`declare -f`) with the
  plan (`declare -p PLAN`), so it may only use `PLAN` and commands both sides have: none of
  go-yolo's functions or globals.
- Keep them short: the tricky shared parts (apt, ownership, symlink chains, secrets) live in `lib/`.

## Helpers

| helper | adds |
|--------|------|
| `plan_packages GROUP NAME...` (`lib/apt.sh`) | apt packages, at the host's version where the image can get it, never downgrading |
| `plan_copy KIND GROUP DIR VALUE [FLAG]` | a host directory copied into the image at the same path, with the host's ownership (`KIND`: `toolchain`, `tools`; `FLAG` `on-path` puts `DIR/bin` on `PATH`) |
| `plan_tool GROUP NAME` | a host command: its apt packages, or its install directory |
| `plan_mount GROUP PATH [FLAGS]` | a host file or directory, read-only at the same path (files that look like they hold credentials get a ⚠) |
| `plan_cache GROUP PATH NAME` | the project's cache volume `NAME` at the host's cache path `PATH` |
| `plan_env GROUP NAME [VALUE]` | a host environment variable (secret-looking ones only when `.go-yolo/config` asks for them); with `VALUE`, a value go-yolo sets itself |
| `plan_domain GROUP HOST` | a host allowed with `--net allowlist` |
| `plan_cert PATH`, `plan_locale NAME` | a CA certificate, a locale |
| `plan_add KIND GROUP METHOD NAME [VALUE] [FLAGS]` (`lib/plan.sh`) | any item, when nothing above fits |

`plan_has KIND NAME`, `plan_items KIND [METHOD]`, `plan_value KIND NAME` and `plan_lines` read
the plan. Item kinds and flags are declared in `lib/kinds.sh`; a new flag needs a row there.

Globals a catalog can use: `HOME_DIR`, `PROJECT_DIR` (the current directory),
`HOST_ID`/`HOST_CODENAME`, `HOST_UID`/`HOST_GID`.

## Template

```bash
# shellcheck shell=bash
# The Foo catalog, for projects with a foo.toml: the host's Foo, as the host has it.
#
#   toolchain  FOO_HOME, copied into the image at the same path (or its apt packages)
#   cache      ~/.cache/foo, in the project's volume foo
#   env        the Foo variables set on the host
#   domain     the Foo registry

foo_detect() { [[ -f foo.toml ]]; }

foo_resolve() {
  local home
  if ! home="$(foo env FOO_HOME 2>/dev/null)"; then
    warn "this project uses Foo, but foo isn't on PATH: the container gets no Foo either"
    return 0
  fi
  plan_copy toolchain foo "$home" "$(foo --version)" on-path
  plan_cache foo "$HOME_DIR/.cache/foo" foo
  plan_env foo FOO_FLAGS
  plan_domain foo registry.foo.example
}

# --parity probe: runs on the host and in the container (no go-yolo functions here).
foo_probe() {
  printf 'foo version\t%s\n' "$(foo --version 2>&1 || printf '(missing)')"
}
```

Then add tests (fixtures in `tests/`, see `tests/run.sh`'s Go and Java sections), the README
section, and `tests/lint.sh` checks it.
