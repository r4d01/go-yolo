# go-yolo: project images plan

Status: draft, 2026-11-08. Nothing here is implemented yet.

## 1. Goal

The container should mirror the host's development environment for the current project, so that
**a build that worked in the container gives the same result when re-run on the host**, and a
build that fails on the host fails the same way in the container.

Today the launcher bind-mounts host toolchains (GOROOT, JDK, Maven, Gradle) and shares host caches
read-write. That does not scale to more languages, breaks on tools that need to write (rustup,
Android SDK, corepack), and lets the agent poison host caches (`~/.m2`, `~/go/bin`, Gradle init
scripts). This plan replaces it with a **per-project image** that contains copies of exactly the
host toolchains the project needs, plus **project-local caches** that persist between runs.

## 2. Decisions

| # | Decision |
|---|----------|
| D1 | **Reproducible on the host** is the guiding rule. When in doubt, do what the host would do. |
| D2 | **Versions come from the host, never from the project.** The project only decides *which* toolchains are needed (`go.mod` → Go). Which Go, JDK, Rust or Node is used is what the host resolves in the project directory, in the user's shell (SDKMAN, nvm, mise, direnv activations included). |
| D3 | **Toolchains are copied into a per-project image**, not mounted. Bigger images are acceptable. |
| D4 | **Truly identical** beats small: all JDKs that the host's Gradle/Maven could pick as toolchains, the whole Android SDK, all installed Rust toolchains. |
| D5 | **Same paths as on the host** for everything: toolchains, config files, caches. Symlink chains the host uses (e.g. SDKMAN `current`) are recreated. |
| D6 | **Same ownership as on the host.** A copied directory owned by root on the host is root-owned in the image; one owned by the user (`~/go/bin`, an nvm Node) is owned by the user, so `go install` / `npm i -g` work as on the host. Such writes live only as long as the container. |
| D7 | **Project-local, persistent caches** in `<repo>/.go-yolo/cache/`, mounted read-write at the host's cache paths. **Host caches are mounted read-only as seeds** where the tool supports it. Nothing is ever written to the host's own caches. |
| D8 | **`.go-yolo/` is hidden from the container** (covered by an empty, read-only tmpfs) and **ignores itself in git** (`.go-yolo/.gitignore` containing `*`). |
| D9 | **Must run from the git repository root.** Anywhere else is an error. |
| D10 | **Confirm before building.** The launcher resolves a plan (what will be installed, how, what will be set and mounted), shows it, and builds only a confirmed plan. Changes are shown as a diff. |
| D11 | **No user-wide defaults** for now. Per-project settings only, in `.go-yolo/config`. |
| D12 | **Bash stays**, split into small modules. KISS and readability come first; some performance can be traded for it. A Go rewrite may come later. |
| D13 | **Color output** on terminals; **fzf** is an optional helper, never required. |
| D14 | Language order: **Go → Rust → Node → Java (Maven, Gradle) → Android**. |
| D15 | **The image never downgrades a package.** If the host is behind the archive, the image gets the archive's newer version, and the plan shows a ⚠; you decide whether to go on (or `apt upgrade` the host). |
| D16 | **Only packages a project needs**, never "all of the host's `*-dev` packages". Language packs propose the packages they find a reason for (e.g. a cgo `pkg-config` name → the host package owning that `.pc` file); everything else is an `extra package`. |

## 3. Design

### 3.1 Flow of one run

```
parse args → detect host → check project → resolve plan → confirm plan → ensure images → run
                                           (lang packs)    (diff, ask)     (base + project)
```

`go-yolo.sh` itself only loads the modules and calls these steps in order.

### 3.2 Code layout

```
go-yolo.sh            entry point: load lib/, call the steps (~50 lines)
lib/
  ui.sh               colors, die/warn/note, prompts, fzf helpers with plain fallbacks
  args.sh             option parsing; the globals it sets are listed at the top
  aliases.sh          --install-aliases & co.
  host.sh             distro, user, base image name
  project.sh          git-root check, .go-yolo/ checks and setup, cache dirs
  mounts.sh           add_mount, path validation, system directory list
  agent.sh            agent profile and its config mounts
  toolchains.sh       today's host toolchain mounts (shrinks in phase 1, gone after phase 4)
  plan.sh             plan helpers (plan_toolchain, plan_env, ...), render, diff, confirm
  image.sh            base image build, project Dockerfile generation, project image build
  run.sh              docker run command, tmux decision, banner
packs/
  go.sh  rust.sh  node.sh  java.sh  android.sh
agents/*.conf         unchanged
```

Conventions:

- Small functions with one job and a one-line comment saying what they are for.
- Plain `if`/`for` over clever one-liners. Unavoidable `awk`/`sed` gets a comment with an example
  of input and output.
- Few globals, set in `args.sh` and `host.sh`, listed at the top of each file.
- shellcheck-clean. Every module has its own tests.
- No raw escape codes outside `lib/ui.sh`. No fzf checks outside `lib/ui.sh`.

### 3.3 Language packs

Each `packs/<name>.sh` defines two functions, prefixed with the pack name. `packs/host.sh` (base
image, CAs, time zone, proxies, extras) is the pack every project gets:

```bash
go_detect()  { [[ -f go.mod ]]; }     # does the project need this language?
go_resolve() { ...; }                 # ask the host, emit plan lines via plan_* helpers
```

Packs stay short: the tricky parts (apt vs copy, symlink chains, ownership, shims, secret
detection) live once in `lib/plan.sh` as helpers such as `plan_toolchain`, `plan_env_candidates`,
`plan_file`, `plan_seed`, `plan_cache`, `plan_domain`.

### 3.4 The plan is plain text

Every step either writes plan lines or reads them. A plan is a sorted, tab-separated text file,
one item per line:

```
kind       lang    method  path / name                                 value / flags
toolchain  go      copy    /usr/local/go                               1.25.3
toolchain  java    apt     openjdk-21-jdk-headless                     21.0.5+11-1~deb13u1
link       java    link    ~/.sdkman/candidates/java/current           21.0.5-tem
package    host    apt     libsqlite3-dev                              3.46.1-2
package    extra   apt     protobuf-compiler                           3.21.12-11 warn:not-on-host
cert       host    copy    /usr/local/share/ca-certificates/corp.crt
tool       go      copy    ~/go/bin/golangci-lint                      user-owned
env        go      env     GOPRIVATE                                   github.com/r4d01/*
file       gradle  ro      ~/.gradle/gradle.properties                 warn:secret
seed       go      ro      ~/go/pkg/mod/cache/download
cache      go      rw      ~/go/pkg/mod                                .go-yolo/cache/go-mod
domain     rust    allow   index.crates.io
```

(`~` is shown for readability; the file stores absolute paths.)

- **Build-time kinds** (`toolchain`, `link`, `package`, `cert`, `tool`) define the project image.
- **Runtime kinds** (`env`, `file`, `seed`, `cache`, `domain`) become `docker run` arguments.
- **Confirming** compares the new plan with `.go-yolo/plan` (the last confirmed one) using `diff`.
- **The image tag** includes the `sha256sum` of the build-time lines plus the base image hash.
- **The Dockerfile** is generated line by line, one small function per method.
- **Tests** run a language pack against a fixture host and compare its output with an expected
  plan file.

### 3.5 `.go-yolo/` directory

```
<repo>/.go-yolo/
  .gitignore     "*"
  config         user choices (extra / exclude)
  plan           last confirmed plan
  build/         generated Dockerfile and small staged files (certs, apt sources)
  cache/         persistent caches: go-mod, go-build, cargo-registry, npm, gradle, m2, ...
```

Checks on every run. Any failure is an error with an explanation:

- `.go-yolo` is a real directory (not a symlink), owned by the user, inside the repo.
- Nothing under `.go-yolo/` is tracked by git (`git ls-files .go-yolo` is empty). A repo that
  ships its own `.go-yolo` is refused.
- Every cache subdirectory passes the normal mount checks.
- If the repo has a `Dockerfile` and its `.dockerignore` doesn't exclude `.go-yolo/`, print a
  one-time warning (the caches would end up in that project's Docker build context).

In the container, `<repo>/.go-yolo` is covered by `--mount type=tmpfs,destination=<repo>/.go-yolo,tmpfs-mode=0555`
(root-owned, so the agent can't write to it). The caches are reachable only through their own
mounts at the host's cache paths.

### 3.6 `.go-yolo/config`

A simple line format, parsed (never `source`d):

```
# one item per line: extra|exclude <kind> <name>
extra    tool     sbt
extra    package  protobuf-compiler
extra    env      GITHUB_TOKEN
exclude  toolchain /usr/lib/jvm/java-17-openjdk-amd64
exclude  package  libpq-dev
```

The container can't see this file, and a repo can't ship it (see 3.5), so it is a trusted
source of settings.

### 3.7 Images

```
go-yolo-base:<distro>-<codename>-<hash>     shared: OS, agents, entrypoint (today's image)
        ▲ FROM
go-yolo:<project>-<pathhash>-<planhash>     per project: generated from the plan
```

- The base image still matches the host distro and codename, because copied binaries need the
  host's glibc and apt packages must have the host's versions.
- Large directories are passed as BuildKit named contexts (`--build-context tcN=<dir>`, then
  `COPY --from=tcN`), so nothing big gets staged. Small files are staged in `.go-yolo/build/`,
  which is the main build context. **Requires BuildKit** (default since Docker 23).
- `COPY --chown=<uid>:<gid>` for user-owned sources (D6). Missing parent directories under
  `$HOME` are created with the user's ownership.
- COPY steps are ordered by size (largest and most stable first, e.g. the Android SDK), so that
  projects with the same big toolchain share build cache, and layers where possible.
- Images carry labels: project path, plan hash, confirmation date. `--prune` uses them.
- `--rebuild` rebuilds the base (pull, no cache) and then the project image.

### 3.8 Plan confirmation

```
go-yolo: image plan for ~/src/myapp (new)

base       debian:trixie + agents (go-yolo-base:debian-trixie-3f2a91c0)
toolchains
  go        1.25.3   copy   /usr/local/go                              (≈ 250 MB)
  java      21.0.5   apt    openjdk-21-jdk-headless=21.0.5+11-1~deb13u1
  ...
runtime (not baked into the image)
  env       GOPRIVATE=github.com/r4d01/*
  ro files  ~/.gradle/gradle.properties   ⚠ contains "password"
  ...
  not passed  GITHUB_TOKEN (looks secret; add it with `extra env`)

[y] build  [n] abort  [e] edit  [d] show Dockerfile  [?] help
```

- On later runs only the diff is shown (`+` added, `-` removed, `~` changed), with the reason when
  known ("host upgraded", "no longer on host").
- If only runtime lines changed, there is no rebuild, but the change is still confirmed.
- `[e]` with fzf: a multi-select to exclude items (with a preview pane: value, source, size,
  warnings, why it was detected), then a multi-select to add extras (host tools not in the plan,
  host env vars not proposed, apt packages from `apt-cache pkgnames` with `apt-cache show` as
  the preview). Without fzf: open `.go-yolo/config` in `$EDITOR`. Then resolve and show again.
- `[d]` shows the generated Dockerfile; it is also kept in `.go-yolo/build/Dockerfile`.
- Size estimates (`du`) per copied item and a total.
- **No terminal → never build an unconfirmed plan**: exit with an error that lists the changes and
  says to run interactively.
- `--yes` skips the prompt. It is never read from the environment and no alias adds it (same
  model as `--yolo`).
- The banner shows `plan <hash> confirmed <date>`.

### 3.9 Cross-cutting rules (apply to every language)

1. **Ask the host's own tools**, in the project directory: `go env`, `rustup which rustc`,
   `volta which node`, `jenv javahome`, `mise where <tool>`, `$JAVA_HOME`, `command -v`.
   Shim-based managers (jEnv, Volta, asdf, mise, rustup) are resolved through the manager,
   never by `readlink` on the shim.
2. **Recreate the symlink chain** from the path the host uses to the real directory.
3. **Apt-installed toolchains are installed with apt** at the host's exact version
   (`dpkg -S <path>` → package, `dpkg-query` → version), so their library dependencies come
   along. Extra host apt sources (`/etc/apt/sources.list.d/*`) and their keyrings are mirrored. If
   the exact version is no longer available, fall back to copying the directory and installing
   the packages it depends on.
4. **Packages** (D16): the packs propose what a project needs; `extra package <name>` adds more.
   Each gets the **host's version** when it is in the distro archive (this release, its
   `-updates` and `-security` suites; checked with `apt-cache policy`). Otherwise:
   - host behind the archive → the archive's newer version, `⚠` (D15: never a downgrade);
   - not installed on the host → the archive's version, `⚠ not installed on the host`;
   - the host's version only comes from a third-party repository or backports → left out, `⚠`;
   - unknown to apt → left out, `⚠`.
   The version is recorded in the plan, so a change shows up in the diff. Only apt for now; a
   free-form Dockerfile snippet can come later if there's a real need. (An earlier idea, all of
   the host's `*-dev` packages, pulled in X11, OpenGL and LLVM headers no build needed, and
   hit downgrades on an out-of-date host.)
5. **CA certificates**: host extra CAs (`/usr/local/share/ca-certificates/*`) are copied and
   `update-ca-certificates` is run.
6. **Config in parent directories** (`go.work`, `.cargo/config.toml`, `rust-toolchain.toml`) is
   found and mounted read-only at its host path.
7. **Absolute paths inside config files** (Maven `localRepository`, Gradle
   `org.gradle.java.installations.paths`, Cargo `target-dir`, npm `prefix`, `go.work` `use`) are
   reported in the plan with a warning when they point outside what the plan covers.
8. **Env vars**: each pack lists candidate names. Candidates set on the host are proposed with
   their values. Names matching `*TOKEN*|*SECRET*|*PASSWORD*|*KEY*|*CREDENTIAL*|*AUTH*`, and
   URLs with a password, are never proposed; they can only be added with `extra env NAME`, and
   their values are never shown or stored (only a hash). Variables are passed by name with
   `docker run -e NAME`, never baked into the image and never on the command line. `TZ` is
   always proposed (`tzdata` is in the base image); `LANG` is passed as before.
9. **Config files** are mounted read-only at their host path. Files that look like they hold
   credentials get a `⚠` in the plan. Known secret files are never proposed (see each language).

### 3.10 UI

- `lib/ui.sh` has `die`/`warn`/`note` and `ui_paint red|yellow|green|dim TEXT`; nothing else
  uses escape codes.
- Color only when stderr is a terminal and `TERM` isn't `dumb`. `NO_COLOR` turns it off;
  `--color=auto|always|never` overrides. All launcher output goes to stderr, so agent output is
  never colored by go-yolo.
- Colored meaning: plan diff (`+` green, `-` red, `~` yellow), warnings yellow, errors red,
  banner `yolo=ON` red, `net=open` yellow, `net=allowlist|none` green.
- Every colored marker also has a text form, so nothing is lost without color.
- fzf is used only when installed and stdin/stderr are terminals, through helpers like
  `ui_pick_many <prompt> <preview-cmd>` whose fallback lives in the same function. Uses: plan
  editing (3.8), agent picker (`go-yolo.sh` without an agent), `--prune`.

## 4. Phases

Each phase is shippable on its own: behaviour that a phase hasn't replaced yet keeps working the
old way. Each phase updates the README and the tests.

### Step 1 — Split the launcher (no behaviour change) — done

- Move `go-yolo.sh` into `lib/` modules as in 3.2; `go-yolo.sh` becomes the step list.
- Add `lib/ui.sh` with colors, `NO_COLOR` and `--color`.
- Tests stay in `tests/run.sh` for now; they get split per module once phase 0 adds modules
  with logic of their own.

Done when: `tests/run.sh` and `tests/docker.sh` pass unchanged (apart from color-aware output
checks), and `--dry-run` output is identical to before for the test fixtures.

### Phase 0 — Project images, plan and confirmation — in progress

Done so far: `.go-yolo/` and the project checks; the plan with diff, confirmation (prompt,
`--yes`, refusal without a terminal) and `$EDITOR` editing; `.go-yolo/config`; base image
`go-yolo-base:…` and the generated project image; packages (rule 4), CAs, time zone, proxies,
extra env; `parity` warnings for base image packages whose version differs from the host's
(the base is built after the first confirmation, then the plan is resolved and confirmed again
before the project image). `--prune` (with the first fzf helper, `ui_pick_many`). Still to do: fzf editing, `--parity`, the
agent picker. Named contexts and
ownership (`--chown`) come with the first pack that copies a toolchain (phase 1).

- `lib/project.sh`: git-root check (D9), `.go-yolo/` creation and checks (3.5), tmpfs cover,
  `.dockerignore` warning.
- `lib/plan.sh`: plan format, helpers, render, diff, confirm, `--yes`, non-TTY refusal,
  `.go-yolo/config` parsing, fzf editing with `$EDITOR` fallback.
- `lib/image.sh`: base image as `go-yolo-base:…`, generated project Dockerfile, named
  contexts, ownership, labels.
- Cross-cutting rules 4, 5 and 8 (packages, CAs, env vars). Rules 3 (apt-installed toolchains,
  third-party sources) and 9 (config files) come with the first pack that needs them.
- `--parity`: run the same probes on the host and in the container and show the differences
  (env vars, plus whatever each language pack adds).
- `--prune`: list go-yolo images with project, plan date, size and whether the project still
  exists; delete the selected ones.
- Agent picker when no agent is given.

Done when: a project without any language markers gets a confirmed plan, a project image
(base + CAs + extra packages + env), the hidden `.go-yolo/`, and `--parity` shows no unexpected
differences. Changing a host package version shows a diff and rebuilds after confirmation.

### Phase 1 — Go

- Detect: `go.mod`, `go.work`.
- Resolve: `go env GOROOT GOVERSION GOTOOLCHAIN GOENV GOWORK GOMODCACHE GOCACHE GOPATH`.
- Toolchain: GOROOT (apt `golang-*` or copy). Tools from `$GOPATH/bin` (or `GOBIN`), user-owned.
- Files: `GOENV` file; `go.work` if outside the repo (and a warning for its `use` paths).
- Env candidates: `GOFLAGS GOPRIVATE GONOPROXY GONOSUMDB GOPROXY GOSUMDB GOTOOLCHAIN GOEXPERIMENT
  CGO_ENABLED CC CXX CGO_CFLAGS CGO_LDFLAGS`.
- Seed: `GOMODCACHE/cache/download` as `GOPROXY=file://…,<host GOPROXY>` (prepended to the
  host's own GOPROXY value, so the fallback is unchanged).
- Caches: `GOMODCACHE` and `GOCACHE` at their host paths, backed by `.go-yolo/cache/go-mod` and
  `go-build`. Toolchains downloaded via `GOTOOLCHAIN` land in the module cache.
- Secrets never proposed: `~/.netrc` (opt-in with `extra file`).
- Domains: `proxy.golang.org`, `sum.golang.org`, `storage.googleapis.com`; plus the host's
  GOPROXY hosts.
- Removes: the GOROOT/GOPATH/GOCACHE host mounts and `GOYOLO_GOPATH_MODE` (warn if still set).

Done when: for this repo and a cgo project (e.g. sqlite), `go build ./...`, `go test ./...` and
`go generate ./...` behave the same on host and in container; `--parity` shows identical `go env`
(apart from documented GOPROXY seeding); the host's `~/go` is never written.

### Phase 2 — Rust

- Detect: `Cargo.toml`.
- Resolve: `rustup which rustc` (in the repo), `rustup toolchain list`, `rustup show`.
- Toolchain: rustup itself plus **all** installed toolchains (D4) and `~/.rustup/settings.toml`
  (default toolchain and directory overrides). Distro `rustc`/`cargo` via apt if that's what the
  host uses.
- Tools: `~/.cargo/bin` minus the rustup proxies, user-owned.
- Files: `~/.cargo/config.toml`, plus `.cargo/config.toml` and `rust-toolchain.toml` from parent
  directories.
- Env candidates: `RUSTFLAGS RUSTDOCFLAGS RUSTC_WRAPPER CARGO_BUILD_TARGET CARGO_TARGET_DIR
  CARGO_INCREMENTAL CARGO_NET_GIT_FETCH_WITH_CLI CARGO_REGISTRIES_*`, `CC`, `CXX`.
- Caches: `~/.cargo/registry`, `~/.cargo/git` (and the sccache dir when `RUSTC_WRAPPER` is
  sccache), backed by `.go-yolo/cache/`. No seed (Cargo has no read-only cache layer;
  `Cargo.lock` and checksums keep the result identical).
- Warn when `CARGO_TARGET_DIR` or `target-dir` points outside the repo.
- Secrets never proposed: `~/.cargo/credentials.toml`.
- Domains: `index.crates.io`, `static.crates.io`, `crates.io`, `static.rust-lang.org`.

Done when: `cargo build`, `cargo test` and `cargo +<other toolchain> build` behave the same on host
and container for a project with a `-sys` crate and one with `rust-toolchain.toml`.

### Phase 3 — Node

- Prerequisite: move the agents' Node to `/opt/go-yolo/node` with wrapper scripts, so the
  project's Node (including one in `/usr/local` from `n` or a tarball) never collides with it.
- Detect: `package.json`.
- Resolve: `volta which node`, `mise where node`, else `command -v node` with fnm/nvm symlinks
  resolved; `npm prefix -g`; `corepack --version`; `command -v pnpm yarn`.
- Toolchain: the Node install dir (apt, NodeSource via apt, or copy), with its global packages and
  corepack shims. A custom global prefix (`~/.npm-global`) and a standalone pnpm are copied too.
- Files: `~/.npmrc` (⚠ when it contains `_authToken`), `~/.yarnrc.yml`, `~/.config/pnpm/rc`.
- Env candidates: `NODE_OPTIONS NODE_ENV NODE_EXTRA_CA_CERTS npm_config_* COREPACK_* PNPM_HOME
  PLAYWRIGHT_BROWSERS_PATH PUPPETEER_* CYPRESS_CACHE_FOLDER`.
- Seeds: `~/.cache/node/corepack`, `~/.cache/node-gyp`, `~/.cache/ms-playwright`,
  `~/.cache/Cypress`, `~/.cache/puppeteer` (read-only; used through env vars or as a copy source,
  to be settled per tool during the phase).
- Caches: `~/.npm`, the pnpm store, the yarn global cache, backed by `.go-yolo/cache/`.
- Domains: `registry.npmjs.org` (already allowed), `repo.yarnpkg.com`, the host's registry from
  `.npmrc`.

Done when: `npm ci && npm test` (and the pnpm/yarn equivalents with `packageManager`) behave the
same on host and container, including a project with a native addon whose `node_modules` built in
the container then works on the host.

### Phase 4 — Java (JDK, Maven, Gradle)

- Detect: `pom.xml`, `mvnw`, `build.gradle(.kts)`, `settings.gradle(.kts)`, `gradlew`.
- Resolve the default JDK: `$JAVA_HOME`, `jenv javahome`, `mise where java`, else `command -v java`
  (Java 8 `jre/` layout handled as today).
- **All toolchain JDKs (D4)**: `/usr/lib/jvm/*`, `~/.sdkman/candidates/java/*`, `~/.jdks/*`,
  `~/.gradle/jdks/*`, `~/.asdf`/mise Java installs, `org.gradle.java.installations.paths`,
  and the JDKs listed in `~/.m2/toolchains.xml`.
- Maven / Gradle installs when the project has no wrapper (`command -v mvn gradle`, SDKMAN
  candidates, apt).
- Files: `~/.m2/settings.xml`, `~/.m2/toolchains.xml`, `GRADLE_USER_HOME/gradle.properties`,
  `GRADLE_USER_HOME/init.gradle(.kts)`, `GRADLE_USER_HOME/init.d/*`.
- Env candidates: `JAVA_HOME JAVA_OPTS JAVA_TOOL_OPTIONS _JAVA_OPTIONS MAVEN_OPTS MAVEN_ARGS
  GRADLE_OPTS GRADLE_USER_HOME` and `ORG_GRADLE_PROJECT_*` (with the secret-name filter).
- Seeds: `~/.m2/repository` via `-Dmaven.repo.local.tail`, passed in `MAVEN_ARGS` (both need
  Maven ≥ 3.9; older Mavens run without the seed), `GRADLE_USER_HOME/caches` via
  `GRADLE_RO_DEP_CACHE`, `~/.m2/wrapper` and `GRADLE_USER_HOME/wrapper/dists`.
- Caches: `~/.m2/repository`, `GRADLE_USER_HOME/caches`, `GRADLE_USER_HOME/wrapper` at their
  host paths, backed by `.go-yolo/cache/m2` and `gradle`.
- The JDK `cacerts` comes with the JDK copy or package (and rule 5).
- Secrets never proposed: `~/.m2/settings-security.xml`.
- Domains: `repo.maven.apache.org`, `repo1.maven.org`, `services.gradle.org`,
  `downloads.gradle.org`, `plugins.gradle.org` (most are already allowed), plus repositories
  from `settings.xml`.
- Removes: `GOYOLO_TOOLS` and the tool host mounts (warn if still set; `extra tool` replaces it).

Done when: a Maven project, a Gradle project with `gradlew`, and a Gradle project using
`java { toolchain { … } }` behave the same on host and container; `--parity` shows identical
`java -XshowSettings:properties -version`, `mvn -v` and `gradle -v`.

### Phase 5 — Android

- Detect: `com.android.*` plugins in Gradle files, `local.properties` with `sdk.dir`,
  `AndroidManifest.xml`.
- Resolve: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `sdk.dir` from `local.properties`.
- Toolchain: **the whole SDK** at its host path (D4), copied first among the project layers so
  Android projects share it. Includes accepted licenses (`licenses/`).
- Files: `~/.android/debug.keystore` (read-only; otherwise debug APKs built in the container are
  signed with a different key and can't be installed over host builds).
- Env candidates: `ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK_HOME`.
- Secrets never proposed: release keystores, `keystore.properties`.
- Domains: `dl.google.com`, `maven.google.com`.
- Out of scope: adb to devices, the emulator.

Done when: `./gradlew assembleDebug test` behaves the same on host and container, and the debug
APK built in the container installs over one built on the host.

## 5. Tests

- **Unit tests per module** (no Docker): stub commands from `tests/fixtures/`, as today.
- **Golden plans per language**: a fixture host (stubbed `go`, `rustup`, `dpkg-query`, …) plus a
  fixture project produce a plan that is compared with `tests/golden/<case>.plan`.
- **Dockerfile generation** compared with golden files.
- **Container tests** (`tests/docker.sh`): privilege drop, tmpfs cover of `.go-yolo`, cache
  persistence across two runs, ownership of copied directories, firewall.
- **Parity tests**: `--parity` on sample projects per language.

## 6. Known limitations and open items

- `go.work` that `use`s modules outside the repo: those modules must be mounted. Read-only by
  default? Settle in phase 1.
- Maven SNAPSHOT dependencies and version ranges can resolve differently, because the container's
  cache state differs from the host's.
- `--net allowlist` / `none` can make downloads fail where they succeed on the host. That is
  expected, and documented.
- pnpm can't hardlink across mounts and falls back to copying (same result, slower).
- The Gradle read-only cache must not change while in use; a host Gradle build running at the
  same time could in theory disturb it.
- Exact apt versions disappear from the archive when the host lags behind; the copy fallback
  covers this, but its dependency list is approximate.
- Which host packages count as "build packages" (rule 4) may need tuning after real use.
- Per-project images use more disk. `--prune` and layer ordering mitigate it.
- Writes to user-owned copied directories (`go install`, `npm i -g`) don't persist after the
  container exits.
- The per-project image contains the user's UID/GID (for `--chown`), so it is not shareable
  between users. That is acceptable: it is a local image.
