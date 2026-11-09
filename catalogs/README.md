# Catalogs

A catalog knows one ecosystem: what the host has of it, and which plan items mirror that in
the project's container. `go-yolo.sh` loads every `catalogs/<name>.sh` (the `host` catalog first,
then the rest by name), so adding a catalog means adding a file. Picked items are **installed
from their source** where the catalog knows a recipe (a vendor download, `go install`), checked
against the host's files; copying the host's files is the fallback (`docs/PLAN.md`, 3.3 and 3.12).

## The contract

A catalog defines functions prefixed with its name:

| function | job | required |
|----------|-----|----------|
| `<name>_discover` | list what the host has, for the setup picker: one candidate per line, `mode<TAB>kind<TAB>id<TAB>hint<TAB>name<TAB>description` (see below) | yes, unless the catalog only adds fixed items |
| `<name>_resolve` | add plan items for what the setup picked: check with `picked <name> KIND ID` (or `picked_ids <name> KIND`, `catalog_picked <name>`; `picked_mode` says `image` or `copy`), ask the host's tools, and use the helpers below | yes |
| `<name>_detect` | a **hint** only: true if the project looks like it uses the ecosystem (files in the project root, the current directory); `_discover` uses it to pre-select candidates on a first setup | no |
| `<name>_setup MODE` | after the picker: complete or ask about the picks in `CONFIG_ITEMS` (e.g. pin a needed package, ask for a licence); `MODE` is `ask` in a terminal, otherwise it must not accept anything | no |
| `<name>_probe` | `--parity` probe: print `name<TAB>value` lines (`kind name` for plan items: those flagged `not-on-host` show as container-only) | no |

A candidate line:

| field | meaning |
|-------|---------|
| `mode` | `image`, `mount`, `cache` or `env`: what the item becomes (a user can change `image` to `copy` by hand) |
| `kind`, `id` | what `picked <name> KIND ID` asks for; `id` is `-` when there is only one |
| `hint` | `1` to pre-select it on a first setup (from `_detect`); never `1` for a secret-looking variable |
| `name` | the path or name it stands for (an old `exclude` line is matched against it) |
| `description` | what the picker shows; for an image item end it with how it gets there (`· install: go.dev release (sha256)`, `· copy: built from local sources`) |

Rules:

- **Offer what the host has; plan only what is picked.** Nothing a catalog finds goes into the
  plan unless it is picked; the hints only pre-select.
- **Ask the host's tools**, never guess: `go env`, the JDK's `release` file, `dpkg -S`. Read
  versions on every run; don't store them.
- **Offer what the host doesn't have too** (D23), when the catalog can: never pre-selected
  (hint `0`), its version pinned in the id (`build-tools;36.0.0@36.0.0`), the `not-on-host` flag
  in the plan, the description starting with `○`.
- **A picked item the host no longer has** gets a `gone` item (`plan_add KIND GROUP skip NAME - gone`).
- **Install, don't copy, where you can** (`plan_download`, `plan_build`), with the vendor's own
  checksum URL (never a checksum typed into the catalog) and a few host files to check the result
  against. Honour the `copy` mode. A copy says why with a reason flag (`no-recipe`,
  `copy-picked`, `local-build`, ...; declared in `lib/kinds.sh`).
- **Only through the helpers.** They apply the mount and copy safety checks, and skip items the
  plan already has.
- **A probe runs on both sides.** It is copied into the container as text (`declare -f`) with the
  plan (`declare -p PLAN`), so it may only use `PLAN` and commands both sides have: none of
  go-yolo's functions or globals. It runs for the host catalog and catalogs with picks.
- Keep them short: the tricky shared parts (apt, ownership, symlink chains, secrets) live in `lib/`.

## Helpers

| helper | adds |
|--------|------|
| `plan_packages GROUP NAME...` (`lib/apt.sh`) | apt packages, at the host's version where the image can get it, never downgrading |
| `plan_download KIND GROUP DIR VERSION FLAGS URL ALGORITHM CHECKSUM_URL FILE...` (`lib/recipes.sh`) | a vendor archive installed at the host's directory `DIR`, as its owner: checked against the vendor's checksum (`sha256`/`sha512` at `CHECKSUM_URL`) and `FILE...` against the host's (`FLAGS`: `-` or `on-path`) |
| `plan_build KIND GROUP FILE VALUE COMMAND` (`lib/recipes.sh`) | a host file built in the image's build stage by shell `COMMAND` (run as you, writing `"$OUT/<name>"`), checked against the host's |
| `plan_copy KIND GROUP DIR VALUE FLAGS` | the fallback: a host directory copied into the image at the same path, with the host's ownership (`KIND`: `toolchain`, `tools`; `FLAGS`: the copy's reason, plus `on-path` to put `DIR/bin` on `PATH`) |
| `plan_copy_file KIND GROUP FILE REASON` (`lib/recipes.sh`) | the fallback for one file (a tool) |
| `plan_tool GROUP NAME [MODE [RECIPE]]` | a host command: its apt packages, or its install directory: installed by function `RECIPE DIR` if it knows it, else copied |
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
# The Foo catalog: the host's Foo, as the host has it.
#
#   toolchain  FOO_HOME: Foo's release installed at the same path (or copied, with the copy mode)
#   cache      ~/.cache/foo, in the project's volume foo
#   env        the Foo variables set on the host

foo_detect() { [[ -f foo.toml ]]; }

foo_discover() {
  local hint=0 home
  home="$(foo env FOO_HOME 2>/dev/null)" || return 0   # no Foo on this host: nothing to offer
  if foo_detect; then hint=1; fi
  printf 'image\ttoolchain\t-\t%s\t%s\tFoo %s (%s) · install: dl.foo.example (sha256)\n' "$hint" "$home" "$(foo --version)" "$home"
  printf 'cache\tcache\tfoo\t%s\t%s\tFoo cache (a project volume at %s)\n' "$hint" "$HOME_DIR/.cache/foo" "$HOME_DIR/.cache/foo"
  if [[ -n ${FOO_FLAGS:-} ]]; then printf 'env\tenv\tFOO_FLAGS\t%s\tFOO_FLAGS\tFOO_FLAGS=%s\n' "$hint" "$FOO_FLAGS"; fi
}

foo_resolve() {
  local home name version url
  catalog_picked foo || return 0
  if ! home="$(foo env FOO_HOME 2>/dev/null)"; then
    plan_add toolchain foo skip foo - gone
    return 0
  fi
  if picked foo toolchain -; then
    version="$(foo --version)"
    url="https://dl.foo.example/foo-$version-linux-amd64.tar.gz"
    if [[ $(picked_mode foo toolchain -) == copy ]]; then
      plan_copy toolchain foo "$home" "$version" on-path,copy-picked
    else
      # the vendor's archive, its published SHA-256, and the host files to check it against
      plan_download toolchain foo "$home" "$version" on-path "$url" sha256 "$url.sha256" bin/foo
    fi
    plan_domain foo registry.foo.example
  fi
  if picked foo cache foo; then plan_cache foo "$HOME_DIR/.cache/foo" foo; fi
  while IFS= read -r name; do plan_env foo "$name"; done < <(picked_ids foo env)
}

# --parity probe: runs on the host and in the container (no go-yolo functions here).
foo_probe() {
  printf 'foo version\t%s\n' "$(foo --version 2>&1 || printf '(missing)')"
}
```

Then add tests (fixtures in `tests/`, see `tests/test-go.sh` and `tests/test-setup.sh`), the README
section, and `tests/lint.sh` checks it.
