# go-yolo: project images plan

Status: 2026-11-09. Part 1 (detection-based project images with Go and Java) is implemented on
`feature/project-images`. Part 2 (this plan's next phases) reworks it: **you pick** what goes into
the container, and go-yolo **installs** it from its source instead of copying host files.

## 1. Goal

The container should mirror the host's development environment for the current project, so that
**a build that worked in the container gives the same result when re-run on the host**, and a
build that fails on the host fails the same way in the container.

Part 1 got there by detecting what a project needs (marker files, cgo `pkg-config` lines,
`go.work`, which JDKs Gradle or Maven could pick) and copying the host's toolchains. That works,
but the detection is the most complex and least predictable part, copied host files can't be
checked for integrity, and the read-only seeds of the host's caches let one project's agent read
every other project's dependencies. Part 2 keeps the rest (the plan, confirmation, project
images, `--parity`, `--prune`) and changes three things:

1. **Selection instead of detection.** A setup picker lists what the host has; you pick what the
   container gets and how (in the image, mounted, cached). The choice is saved and never
   re-detected.
2. **Install instead of copy.** Picked items are installed in the image from their source (a
   vendor download with its checksum, the ecosystem's own manager, apt) at the host's versions;
   copying host files is the fallback for items nothing knows how to install.
3. **Caches in Docker volumes, nothing shared.** Each project's caches live in its own Docker
   volumes, mounted at the host's cache paths. The host's caches are no longer seeds: a project's
   first build downloads its dependencies.

## 2. Decisions

| # | Decision |
|---|----------|
| D1 | **Reproducible on the host** is the guiding rule. When in doubt, do what the host would do. |
| D2 | **Versions come from the host**, read from the host's own tools on every run (`go env`, the JDK's `release` file, `rustup`, `sdkmanager --list_installed`, ...). The config says *what*, never *which version*, so a host upgrade carries over by itself. |
| D3 | ~~Toolchains are copied into a per-project image.~~ Superseded by D18. |
| D4 | ~~Truly identical beats small: every JDK the build could pick, the whole Android SDK, ...~~ Superseded by D17: identical *as configured*; the picker shows everything the host has, and `--parity` points out what the container lacks. |
| D5 | **Same paths as on the host** for everything: toolchains, config files, caches. Symlink chains the host uses (e.g. SDKMAN `current`) are recreated. |
| D6 | **Same ownership as on the host.** Root-owned on the host means root-owned in the image; user-owned (`~/go/bin`, `~/.rustup`, `~/Android/Sdk`) means installed as the user, so `go install`, `npm i -g` and the like work as on the host. Such writes live only as long as the container. |
| D7 | **Per-project caches in Docker volumes**, one per cache (`go-yolo-<project>-<pathhash>-<cache>`, labelled with the project path and the cache), mounted at the host's cache paths (`~/go/pkg/mod`, `~/.gradle/caches`, ...). **Nothing is shared with the host's caches**, not even read-only: a seed would let one project's agent read every other project's dependencies, private modules included. The first build of a project downloads what it needs (lockfiles keep the result identical); more disk and a slower first build are accepted. A new volume is root-owned, so the entrypoint hands it to the user before dropping privileges. *(Part 1 had `.go-yolo/cache/` plus read-only seeds and from-host copies; superseded.)* |
| D8 | **`.go-yolo/` is hidden from the container** (covered by an empty, read-only tmpfs) and **ignores itself in git** (`.go-yolo/.gitignore` containing `*`). |
| D9 | **Must run from the git repository root.** Anywhere else is an error. |
| D10 | **Confirm before building.** The plan (what is installed, how, what is set and mounted) is shown and confirmed before anything is built. D20 limits *when* it asks. |
| D11 | **No user-wide defaults** for now. Per-project settings only, in `.go-yolo/config`. |
| D12 | **Bash stays**, split into small modules. KISS and readability come first; some performance can be traded for it. A Go rewrite may come later (see 4.7). |
| D13 | **Color output** on terminals; **fzf** is an optional helper, never required. |
| D14 | Order: **rework (part 2) → Go and Java on the new model → Android → Arduino**. **Rust and Node are TBD**: neither is installed on the host, so they wait for a real setup to test against. |
| D15 | **The image never downgrades a package.** If the host is behind the archive, the image gets the archive's newer version and the plan shows a ⚠; you decide whether to go on (or upgrade the host). |
| D16 | **Only packages you pick.** Never "all of the host's `*-dev` packages" (that pulled in X11, OpenGL and LLVM headers and hit downgrades). The picker lists the host's installed packages; a catalog may suggest a few. |
| D17 | **You pick, go-yolo suggests once.** A setup picker lists what the host has, grouped, each with a default mode. On the first setup a few items are pre-selected from simple hints (a `go.mod` → the Go items); after that the saved selection is the only source of truth, and nothing is re-detected. `--setup` opens the picker again with the current selection. |
| D18 | **Install from the source; copy is the fallback.** Each picked item is installed in the image the way a catalog recipe says: a vendor download checked against the vendor's checksum, the ecosystem's manager at the host's versions (`go install path@version`, `rustup`, `sdkmanager`, `arduino-cli`, `npm i -g`), or apt. An item no recipe knows is copied from the host, and the picker says so. |
| D19 | **Building the image may use the network** (downloads for D18). Running the container stays under `--net`. |
| D20 | **Ask only when exposure changes.** A full confirmation is needed when the selection changes, or when something new is exposed to the container (a mount, an env variable, a secret-looking file, a device). Version changes of picked items and `parity` drift are shown in one banner line and rebuilt without asking. |
| D21 | **Devices** (Arduino uploads, adb over USB): TBD. If they come, then opt-in per project with a ⚠ (the agent could flash a board). |
| D22 | **AI-proposed recipes: later, optional** (see 3.11). The AI only proposes; go-yolo verifies the result against the host before offering it, and saves accepted recipes. |

## 3. Design

### 3.1 Flow of one run

```
parse args → host → project → [setup picker] → resolve plan → confirm (D20) → images → run
                               first run or        catalogs:      only when        base +
                               --setup             versions,      exposure         project
                                                   recipes        changes
```

`go-yolo.sh` only loads the modules and calls these steps in order.

### 3.2 Code layout

```
go-yolo.sh            entry point: load lib/ and catalogs/, call the steps
lib/
  ui.sh               colors, die/warn/note, prompts, fzf helpers with plain fallbacks
  args.sh             option parsing
  aliases.sh          --install-aliases & co.
  host.sh             distro, user
  project.sh          git-root check, .go-yolo/
  mounts.sh           add_mount, path validation, system directory list
  agent.sh            agent profile and its config mounts
  config.sh           .go-yolo/config: the selection
  setup.sh            the setup picker
  plan.sh             the plan model: items, sorting, hash, reading/writing
  kinds.sh            the item kinds, declared in one table (3.5)
  apt.sh              apt versions and owners
  confirm.sh          showing, diffing and confirming the plan
  image.sh            base image, project Dockerfile, builds
  run.sh              docker run command, tmux decision, banner
  prune.sh            --prune
  parity.sh           --parity
catalogs/
  host.sh  go.sh  java.sh  android.sh  arduino.sh   (rust.sh, node.sh: TBD)
  README.md           the catalog contract (3.3) and a template
agents/*.conf         unchanged
```

Catalogs (and agents) are discovered from their directories: adding one means adding a file, not
editing `go-yolo.sh`. Conventions stay as in part 1: small functions with a one-line comment,
plain `if`/`for` over clever one-liners (a comment with an example where `awk`/`sed` is
unavoidable), few documented globals, shellcheck-clean, no escape codes or fzf checks outside
`lib/ui.sh`.

### 3.3 Catalogs

A catalog (`catalogs/<name>.sh`, formerly a "pack") knows one ecosystem. Every ecosystem follows
the same two-level pattern: a **runtime or manager**, plus **items that manager installed**, which
the host's manager can list. A catalog implements five functions, prefixed with its name:

| function | job | example (Go) |
|----------|-----|--------------|
| `<name>_discover` | list what the host has: the picker's candidates, each with a group, an id, a description, a size, a default mode, and whether a hint pre-selects it | GOROOT, each tool in GOBIN, the module and build caches, the GOENV file, Go env variables |
| `<name>_resolve ID` | for a picked item, read its version and facts from the host now (D2) | `go env GOVERSION`; `go version -m ~/go/bin/gopls` → `golang.org/x/tools/gopls v0.21.0` |
| `<name>_recipe ID` | how to install it in the image (D18) | the go.dev tarball + SHA-256; `go install golang.org/x/tools/gopls@v0.21.0` |
| `<name>_glue ID` | runtime wiring for picked caches and settings | `GOMODCACHE` and `GOCACHE` pointing at their volumes' paths |
| `<name>_probe` | `--parity` probes, run on both sides | `go version`, `go env`, the tools |

How the ecosystems fit:

| catalog | runtime / manager: recipe | items: host inventory → recipe |
|---------|---------------------------|--------------------------------|
| host | apt | `dpkg-query` → `apt-get install name=version`; CAs, locales, time zone, proxies |
| go | go.dev tarball + SHA-256 | `go version -m GOBIN/*` → `go install path@version` (a `(devel)` build is copied) |
| java | apt, or Adoptium (Temurin) + checksum | each JDK's `release` file (vendor, version) → apt / Adoptium / copy; Maven and Gradle distributions from their release URLs + checksums |
| android | cmdline-tools zip + checksum | `sdkmanager --list_installed` → `sdkmanager "platforms;android-35" "build-tools;35.0.0" …`; licences from the host |
| arduino | arduino-cli release + checksums | `arduino-cli core list`/`lib list --format json` → `core install arduino:avr@1.8.6`, `lib install X@ver`; `arduino-cli.yaml` (board manager URLs) |
| rust (TBD) | rustup-init + checksum | `rustup toolchain list`, `component`/`target list --installed`, `cargo install --list` → `rustup toolchain install X -c … -t …`, `cargo install --locked name@version` |
| node (TBD) | nodejs.org tarball + signed SHASUMS (as the base image already does for the agents) | `npm ls -g --json`, corepack → `npm i -g name@version`, `corepack prepare` |

Most ecosystem knowledge sits in two small places, the inventory command and the install command.
The tricky shared parts (apt, ownership, symlink chains, secrets, checksums, downloads) live once
in `lib/`.

### 3.4 `.go-yolo/config`: the selection

One picked item per line, written by the picker and editable by hand (parsed, never `source`d):

```
# mode   catalog  kind       id                        options
image    go       toolchain
image    go       tool       gopls
cache    go       modules
cache    go       build
mount    go       goenv
env      go       GOPRIVATE
image    java     jdk        /usr/lib/jvm/java-21-openjdk-amd64
image    java     jdk        /home/me/.gradle/jdks/eclipse_adoptium-25-amd64-linux.2
cache    gradle   caches
cache    gradle   wrapper
mount    gradle   properties
image    android  sdk        platforms;android-35
image    arduino  core       arduino:avr
image    host     package    protobuf-compiler
image    host     tool       kotlin                    copy
env      host     GITHUB_TOKEN
```

- Modes: `image` (installed in the image), `mount` (read-only at the same path), `cache`
  (the project's Docker volume, at the host's path), `env`. `device` if D21 happens.
- The config holds **what**, the plan holds **which version and how**.
- Options override a recipe choice (`copy` forces a copy).
- The container can't see this file, and a repo can't ship it (3.6): a trusted source of settings.

### 3.5 The plan

The plan is the resolved selection: one line per item with its version, recipe and notes, as in
part 1, with two changes:

- **Kinds are declared in one table** (`lib/kinds.sh`): for each kind its sort rank, whether it
  goes into the image, how it is shown, and which function emits its Dockerfile lines or
  `docker run` arguments. Adding a kind means one row, not edits in five places.
- **Behaviour and notes are kept apart.** A flag table says which flags change what go-yolo does
  (`on-path`, `derived`, `user`) and which only explain (`host-older=…`, `secret`,
  `outside-repo`); code asks for a behaviour flag through one helper, display shows only notes.

The image tag still includes a hash of the build-time lines, so a version change rebuilds. The
confirmed plan stays in `.go-yolo/plan`.

### 3.6 `.go-yolo/` directory

`config`, `plan` and `build/` (generated Dockerfile and staged files); the caches moved to Docker
volumes (D7), so `.go-yolo/` stays small and holds no read-only module files. It must be a plain
directory owned by the user with nothing tracked by git; the container sees an empty read-only
tmpfs. (The `.dockerignore` warning goes away with the caches.)

### 3.7 Images

```
go-yolo-base:<distro>-<codename>-<hash>     shared: OS, agents, entrypoint
        ▲ FROM
go-yolo:<project>-<pathhash>-<planhash>     per project: the plan's install steps
```

- The base still matches the host distro and codename: apt versions must be the host's, and
  copied binaries (the fallback) need the host's glibc.
- **Install steps run as the owner the host has (D6):** root-owned items as root, user-owned ones
  (`~/.rustup`, `~/Android/Sdk`, `~/.arduino15`, GOBIN) after `USER <uid>:<gid>` with `HOME` set,
  so paths and ownership match.
- Downloads are checked against the vendor's own checksum (or signature), fetched from the vendor,
  never typed into a recipe by hand where the vendor publishes one.
- Copies (the fallback) use BuildKit named contexts with host ownership, as in part 1.
- Steps are ordered by size and stability, so projects with the same big toolchain share layers.
- The base image is built without asking (it is the same for every project and holds nothing
  from the host), so a first run asks only once.

### 3.8 Setup and confirmation

**The setup picker** (first run, or `--setup`) shows the candidates from every catalog, grouped,
with the recipe each would use:

```
go-yolo: what should this project's container get?   (TAB: pick · Enter: done)

  go
  > [x] toolchain go1.27.0        /opt/go/1.27.0            install: go.dev tarball (sha256)
    [x] tool gopls v0.21.0        ~/go/bin/gopls            install: go install …@v0.21.0
    [ ] tool my-tool (devel)      ~/go/bin/my-tool          copy: built locally
    [x] cache modules             ~/go/pkg/mod              project volume (starts empty)
  java
    [ ] jdk 21.0.12 (apt)         /usr/lib/jvm/java-21-…    install: apt
    [ ] jdk 25.0.3 (Temurin)      ~/.gradle/jdks/…          install: Adoptium (sha256)
    [ ] jdk 27                    ~/.jdks/openjdk-27        copy: unknown vendor
  host
    [ ] apt packages …            (type to search installed and archive packages)
```

A preview pane shows each item's path, size, recipe and what its mode means. Without fzf, a
numbered list. Pre-selection (D17) uses only simple, one-off hints: marker files at the repo root
(`go.mod`, `build.gradle*`, `pom.xml`, `local.properties`, `*.ino`). The result is written to
`.go-yolo/config`.

**Confirmation** (D20): after setup, the plan is confirmed once. Later runs ask again only when the
selection changes or something new is exposed; version bumps and parity drift go into one banner
line (`go 1.27.0 → 1.27.1 · 2 parity notes · rebuilt`). The plan is shown as a **summary by
default** (`go 1.27 · gopls · 2 caches · 1 ⚠`) with `--plan` for every line. A ⚠ item can be
excluded right from the prompt. `--yes` and the refusal without a terminal stay as in part 1.

### 3.9 Cross-cutting rules

1. **Ask the host's own tools** for versions and facts (D2), resolving shims through their manager
   (jEnv, Volta, asdf, mise, rustup), never by `readlink` on the shim.
2. **Recreate symlink chains** the host uses (SDKMAN `current`, `default-java` via its package).
3. **apt items are installed with apt** at the host's version when the distro archive has it (this
   release, `-updates`, `-security`); a host behind the archive gets the archive's version and a ⚠
   (D15); third-party or backports-only versions are left out with a ⚠.
4. **CA certificates and locales** of the host go into the image; time zone, proxies and the umask
   are passed, as in part 1.
5. **Env variables** are picked like everything else. Secret-looking names (`*TOKEN*`, `*SECRET*`,
   `*PASSWORD*`, `*KEY*`, `*CREDENTIAL*`, `*AUTH*`, URLs with a password) are never suggested and
   their values are never shown or stored, only a hash. Passed by name with `docker run -e NAME`.
6. **Mounted files that look like they hold credentials** get a ⚠ (D20: picking one asks).
7. **Settings in parent directories** (`go.work`, `.cargo/config.toml`) are offered in the
   picker when the host has them, with a ⚠ for paths outside the repository.

### 3.10 UI

As in part 1: colors on terminals (`NO_COLOR`, `--color`), every colored marker also as text,
fzf through `lib/ui.sh` helpers with plain fallbacks. New uses: the setup picker, the plan's
exclude-from-prompt, the agent picker (`go-yolo.sh` without an agent).

### 3.11 Later: AI-proposed recipes (D22)

For an item no catalog recipe knows (shown as "copy"), the picker can offer `[a] ask AI`:

1. go-yolo collects facts about the item: its path, `release` file, `--version` output, file
   hashes.
2. It asks an available agent (e.g. `claude -p`, with the user's login) for a recipe **in the
   recipe format**: one of the known methods (apt `name=version`, a vendor download with its
   checksum URL, a manager command). Never free-form shell: recipes run as root in the build.
3. go-yolo validates it: the download host must be the vendor's, the checksum is fetched from the
   vendor, never taken from the AI.
4. It test-builds the recipe and **compares the result with the host's artifact** (a binary's hash,
   the `release` file, `--version`). Only a match is offered, marked "proposed by AI, verified".
5. An accepted recipe is saved in `.go-yolo/config`, so the AI is asked once per item.

The host's artifact is the answer key, which turns "trust the AI" into "check the AI". Without a
login, offline, or on a mismatch, the item stays a copy. The same verify-against-the-host step
also helps when writing new catalogs.

## 4. Phases

Part 2's phases each leave go-yolo working. Each updates the README and the tests.

### 4.1 Done in part 1

- **Step 1**: the launcher split into `lib/` modules; colors.
- **Phase 0**: `.go-yolo/`, the git-root rule, the plan with diff and confirmation, the base and
  project images, packages (never downgrading), CAs, time zone, proxies, locales, umask,
  base-vs-host `parity` warnings, `--prune`, `--parity`.
- **Go**: `packs/go.sh`. GOROOT and GOBIN copied, module and build caches project-local with the
  module seed as the first `GOPROXY` entry (the seed goes in phase A), cgo `pkg-config` packages,
  `go.work`. Checked: `--parity` all 48 probes matching, `go run` with `--net none`, the host's
  `~/go` untouched.
- **Java**: `packs/java.sh`. Every JDK Gradle or Maven could pick (apt or copied), Maven and
  Gradle settings, project caches with read-only seeds (`maven.repo.local.tail`,
  `GRADLE_RO_DEP_CACHE`) and wrapper caches starting as copies (both go in phase A); `extra tool`
  replacing `GOYOLO_TOOLS`.
  Checked on a Gradle project with a JDK 25 toolchain, offline after one online run.

### 4.2 Phase A: restructure (no behaviour change) — done

From the part-1 review; makes part 2 easier to build and to read.

- Split `lib/plan.sh` (655 lines) into `plan.sh`, `kinds.sh`, `apt.sh`, `items.sh`, `confirm.sh`;
  declare the kinds and flags in tables; behaviour flags only through `has_flag`; `plan_lines`
  instead of most repeated parsing loops. The Dockerfile sections and the `docker run` arguments
  stay explicit functions in `image.sh` and `run.sh` (more readable than a dispatch table). —
  done; dry-run plans and commands byte-identical.
- Rename `packs/` to `catalogs/`, discover catalogs and agents from their directories, write
  `catalogs/README.md` (the contract and a template); `tests/lint.sh` checks the catalogs on
  their own. — done
- **Caches in Docker volumes (D7)** — done (checked on the Go and Gradle scratch projects: first
  run downloads into the volumes, the second works with `--net none`, the host's caches stay
  untouched), the one behaviour change of this phase: the `cache` kind
  becomes a named volume at the host's path (labels `go-yolo.project`, `go-yolo.cache`); the
  entrypoint chowns a new, root-owned volume before the privilege drop; the `seed` kind,
  `from-host`, the `GOPROXY`/`GRADLE_RO_DEP_CACHE`/`maven.repo.local.tail` wiring and the
  `.dockerignore` warning are removed; `--prune` lists and removes the volumes (with their size,
  and "project is gone" like images). Existing `.go-yolo/cache/` directories are left alone, with a
  one-time note that they can be deleted.
- Split `tests/run.sh` (700 lines) per module; document the test hooks (`GOYOLO_OS_RELEASE`,
  `GOYOLO_CA_DIR`, `GOYOLO_LOCALES_SUPPORTED`, `GOYOLO_JVM_DIR`) in `tests/README.md`. — done:
  `tests/lib.sh` plus ten `tests/test-*.sh`, each from fresh fixtures.

Done when: all tests pass (with the cache tests rewritten for volumes) and the plans of the test
fixtures are identical apart from the cache and seed items; a Go and a Gradle project build with
their caches in volumes, a second run reuses them, and nothing on the host is read or written.

### 4.3 Phase B: selection (D17, D20)

- `lib/config.sh`: the selection format (3.4), replacing `extra`/`exclude`. A part-1 config is
  converted once (each `extra` becomes a picked item, each `exclude` an unpicked one).
- `lib/setup.sh`: the picker (3.8) with fzf and a numbered-list fallback; `--setup`.
- Catalogs gain `<name>_discover`; resolution runs only for picked items. The part-1 detection
  (marker-based resolution, cgo scanning, `go.work` parsing, the Gradle-vs-Maven JDK scoping)
  becomes discovery plus one-off hints, or goes away.
- Quieter confirmation (D20): ask only on selection or exposure changes; summary by default,
  `--plan` for details; exclude a ⚠ item from the prompt; the base image built without asking.
  — done except the exclude-from-prompt (B3): an item counts as new exposure if it wasn't in the
  confirmed plan or was left out there (the base image and parity notes never count); anything
  else is taken with one note line.

Done when: a new Go project and a new Gradle project are set up through the picker (with and
without fzf), the result matches part 1's for the same picks, and a host upgrade of a picked item
rebuilds without a prompt.

### 4.4 Phase C: install recipes for Go and Java (D18, D19)

- `lib/`: the recipe format, checked downloads (the vendor's checksum or signature), install steps
  as root or as the user (3.7), copy as the labelled fallback.
- Go: the go.dev tarball (SHA-256 from go.dev); tools via `go install path@version` from
  `go version -m`; `(devel)` builds copied.
- Java: apt JDKs as today; Temurin JDKs (vendor from the `release` file) from the Adoptium API with
  its checksum; Maven and Gradle distributions from their release URLs with checksums; other JDKs
  copied.
- `--parity` and the plan verify an installed item against the host (e.g. the hash of `bin/go`,
  the JDK's `release` file).

Done when: the part-1 Go and Java checks pass with installed (not copied) toolchains, and the
plan shows which items are copies and why.

### 4.5 Phase D: Android

- Discover: the SDK (`ANDROID_HOME`, `ANDROID_SDK_ROOT`, `sdk.dir` in `local.properties`),
  `sdkmanager --list_installed`, `~/.android/debug.keystore`.
- Recipe: cmdline-tools from dl.google.com with its checksum, then `sdkmanager` with the picked
  components at the host's versions, as the user, at the host's SDK path; licences from the host.
- Mount `~/.android/debug.keystore` read-only (otherwise debug APKs are signed with a different
  key and won't install over host builds); release keystores and `keystore.properties` are
  secrets, never suggested.
- Env: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `ANDROID_NDK_HOME`. Domains: `dl.google.com`,
  `maven.google.com`.
- Devices (adb over USB, the emulator): D21, TBD.

Done when: `./gradlew assembleDebug test` behaves the same on host and container, and the debug
APK built in the container installs over one built on the host.

### 4.6 Phase E: Arduino

- Discover: `arduino-cli` and its config (`arduino-cli config dump`: directories, board manager
  URLs), `core list` and `lib list` (JSON).
- Recipe: arduino-cli from its GitHub release with checksums; `core install`/`lib install` at the
  host's versions, as the user, at the host's data directory; `arduino-cli.yaml` mounted read-only.
- Caches: the download staging directory, in a project volume.
- Domains: `downloads.arduino.cc`, the board manager URLs' hosts.
- Uploading to a board: D21, TBD. Compiling (`arduino-cli compile`) works without it.

Done when: `arduino-cli compile` of a sketch gives the same binary on host and container.

### 4.7 Later

- **Rust** and **Node** (TBD, D14): the catalog rows in 3.3 are the design; build them once there
  is a real setup to test against. Node first needs the agents' Node moved to `/opt/go-yolo/node`,
  so a project's Node never collides with it.
- **AI-proposed recipes** (3.11), after phase C (it needs the recipe format and the verification).
- **Go rewrite** of the launcher: the strongest remaining reasons are parsing XML, JSON and
  `.properties` files with `sed` (a commented-out `<localRepository>` is read wrongly) and the
  size of the plan code. Decide after phase B.
- **Devices** (D21).

## 5. Tests

- **Unit tests per module** (no Docker), with stub commands from `tests/fixtures/`.
- **Catalog tests**: a fixture host plus a fixture selection give a plan compared with
  `tests/golden/<case>.plan`; the same for the generated Dockerfile.
- **Picker tests** through `script(1)` and an fzf stub, as for `--prune` today.
- **Container tests** (`tests/docker.sh`): privilege drop, the `.go-yolo` cover, umask, locales,
  firewall, the ownership of a new cache volume; later install steps as the user.
- **Parity tests**: `--parity` on sample projects per catalog.

## 6. Known limitations and open items

- Private Go modules (`GOPRIVATE`) are fetched directly and fail without credentials (there is no
  seed any more; a `~/.netrc` or SSH opt-in would be an exposure change, D20).
- A project's first build downloads all its dependencies, so it needs the network (`--net
  allowlist` must allow the registries; `--net none` only works once the volumes are filled).
- Maven SNAPSHOT dependencies and version ranges can resolve differently, because the container's
  cache state differs from the host's.
- `--net allowlist` / `none` can make downloads fail at run time where they succeed on the host.
- A vendor can withdraw an old version; its recipe then fails and the item falls back to a copy
  (with a ⚠).
- Per-project images and cache volumes use disk; `--prune` lists both, with sizes. Volumes of a
  deleted project stay until `--prune` removes them.
- Writes to user-owned items in the image (`go install`, `npm i -g`) don't outlive the container.
- The project image contains the user's UID/GID, so it isn't shareable between users (it is a
  local image).
- The base image's own packages can differ from the host's (`parity` notes) until the host is
  upgraded or the base rebuilt.
