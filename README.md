# go-yolo

`go-yolo` runs AI coding agents (**Claude Code**, **OpenAI Codex CLI**, **Mistral Vibe**, **opencode**)
inside a Docker container that mirrors your host: your user, your project directory, and a
per-project image with copies of your host's toolchains (Go; Java with Maven and Gradle),
packages, locales and settings. You confirm what goes in before it is built.

By default the agent runs **with its normal permission prompts** (Claude Code starts in auto mode,
where a classifier approves safe actions and prompts for risky ones). With `--yolo` those prompts are
turned off ("YOLO mode"). The container is the safety boundary: inside it the agent can do
anything, but outside it the agent only reaches what the launcher explicitly mounts.

```
./go-yolo.sh [launcher-opts] <agent> [agent args...]

agents:  claude | codex | vibe | opencode | shell
opts:    --net open|allowlist|none   (default: open)
         --rebuild                   force image rebuild
         --yes                       use a new or changed plan without asking (never from env)
         --plan                      show every plan item (default: a summary, warnings in full)
         --setup                     pick what this project's container gets (alone: just that)
         --yolo                      turn off the agent's permission prompts (default: off)
         --no-tmux                   don't run the agent inside tmux (default: tmux on a TTY,
                                     except for non-interactive runs such as claude -p;
                                     prefix c: extra shell)
         --tmux                      always use tmux, even for non-interactive runs
         --mount PATH[:ro|:rw]       also mount PATH at the same path (default: ro; repeatable)
         --color auto|always|never   colored launcher messages (default: auto, honours NO_COLOR)
         --dry-run                   print the docker command and exit
         -h | --help

env:     GOYOLO_MOUNTS="PATH[:ro|:rw] ..."  extra mounts, like --mount (whitespace-separated)
         GOYOLO_EXTRA_DOMAINS="a.example ..."  more domains for --net allowlist
         GOYOLO_QUIET=1                     don't print the mount summary line
         GOYOLO_{CLAUDE,CODEX,OPENCODE,VIBE,UV}_VERSION, GOYOLO_NODE_MAJOR
                                     version pins for the image build (use with --rebuild)

commands (no agent needed):
./go-yolo.sh --prune [--yes]         list go-yolo images, remove stale ones (--yes: without asking)
./go-yolo.sh --parity                run the same probes on the host and in the container and
                                     compare them (exit status 1 if anything differs)
./go-yolo.sh --print-aliases         print alias definitions to stdout
./go-yolo.sh --install-aliases       add the aliases to your shell rc file(s)
./go-yolo.sh --uninstall-aliases     remove them again
```

Everything after `<agent>` is passed to the agent unchanged. `shell` starts `bash -l` in the same
environment, for debugging (`go-yolo.sh shell -c 'go version'` also works).

## Threat model

**What the container protects:**

- The host filesystem outside the mounts (see [What gets mounted](#what-gets-mounted)).
- Host processes. The agent runs as your UID, but in its own PID namespace.
- SSH keys, the SSH agent socket, the Docker socket and cloud credentials. None of them are
  mounted or forwarded.
- Arbitrary network egress, **but only in `--net allowlist` mode, which is not the default.** In the
  default `open` mode the agent can send anything it can read to any host on the internet, and it
  can reach the Docker host, your LAN and, on a cloud VM, the instance metadata service
  (`169.254.169.254`) with its credentials.

Inside the container, no process holds any Linux capability once the agent starts: `CapEff`,
`CapPrm` and `CapBnd` are all zero, `no_new_privs` is set, and there is no `sudo`.
Privileged startup uses only the image's executable paths; host toolchains are added to `PATH`
after privileges are dropped.

**What it does not protect:**

- **Anything in the mounted workdir.** The agent can read, change or delete all of it,
  including `.git` (hooks!). Commit or back up first.
- **The mounted agent config.** For example, an agent could add a hook to `~/.claude/settings.json`,
  an MCP server to `~/.codex/config.toml`, or a plugin to `~/.config/opencode`. That code later runs
  **on the host** when you use the agent outside the container. The agent's credentials in that
  directory are readable too.
- **The project's cache volumes** (Go's module and build cache, Maven's and Gradle's). The agent
  can write them, so one session can affect the next one of the same project, but no other
  project and nothing on the host uses them. Your own `~/go`, `~/.cache/go-build`, `~/.m2` and
  `~/.gradle` caches are never read or written, so an agent can't see other projects'
  dependencies either.
- **Settings files the plan mounts read-only**: `~/.m2/settings.xml` and `gradle.properties`
  often hold repository credentials, which the agent can read (the plan marks such files with
  ⚠). Leave one out in `go-yolo.sh --setup`.
- `~/.gitconfig` and `~/.config/git/{config,ignore,attributes}` are mounted read-only, so the
  agent can read them (they usually hold no secrets; `~/.config/git/credentials` is not mounted).
- Anything you add with `--mount` or `GOYOLO_MOUNTS`. A read-only mount can still be read and,
  in `open` mode, sent anywhere.
- Data sent to allowed domains. In `allowlist` mode, a domain such as `api.github.com`,
  `raw.githubusercontent.com` or `storage.googleapis.com` can still carry data out.
- DNS in `allowlist` mode. Queries to the container's nameservers are allowed, so data can leave
  encoded in DNS lookups (DNS tunnelling). Use `--net none` if that matters.
- Kernel or container-escape vulnerabilities. Docker is not a VM.

## Requirements

- A **Debian, Ubuntu or Kali** host (`ID` in `/etc/os-release`). Derivatives such as Mint or
  Pop!\_OS are not detected on purpose: their codenames are not Docker image tags.
- Docker, and a user that can run `docker` (e.g. in the `docker` group).
- Optional: Go on the host. A project with a `go.mod` gets a copy of its toolchain and tools
  (see [Go](#go)).
- Optional: a JDK, Maven, Gradle on the host. A Maven or Gradle project gets copies of them (see
  [Java](#java)); other host commands can be added in the setup.

The image's base matches the host (`debian:<codename>`, `ubuntu:<codename>` or
`kalilinux/kali-rolling`), so host binaries copied or mounted into it (the Go toolchain,
`~/go/bin/*`, a JDK) find the same glibc. **Kali is a rolling release:** the image's glibc matches the host only while both are up to
date. Run `go-yolo.sh --rebuild shell` after upgrading the host.

## Install

```bash
git clone https://github.com/r4d01/go-yolo.git ~/src/go-yolo
mkdir -p ~/bin
ln -s ~/src/go-yolo/go-yolo.sh ~/bin/go-yolo.sh     # ~/bin must be on PATH
```

Optionally install the aliases, either into your rc files:

```bash
go-yolo.sh --install-aliases       # writes ~/.bashrc (and ~/.zshrc if it exists), with a backup
go-yolo.sh --uninstall-aliases     # removes them again
```

or by evaluating them from your rc file:

```bash
eval "$(~/src/go-yolo/go-yolo.sh --print-aliases)"
```

The aliases use the launcher's absolute path, so they work without `~/bin` on `PATH`:

| alias         | runs                    |
|---------------|-------------------------|
| `gy-claude`   | `go-yolo.sh claude`     |
| `gy-codex`    | `go-yolo.sh codex`      |
| `gy-vibe`     | `go-yolo.sh vibe`       |
| `gy-opencode` | `go-yolo.sh opencode`   |
| `gy-shell`    | `go-yolo.sh shell`      |

No alias turns on YOLO mode. Launcher options go before the agent, so `gy-claude --yolo` would pass
`--yolo` to Claude, not to the launcher. Type `go-yolo.sh --yolo claude` instead.

The first run builds the images (a few minutes). Later runs start immediately.

## Usage

Run it from the **root directory of a git repository**. Anywhere else (a subdirectory, a directory
that isn't a repository, `$HOME`, `/` or any parent of `$HOME`) is refused.

The first run creates `.go-yolo/` in the repository root for go-yolo's per-project state. It
contains a `.gitignore` with `*`, so git ignores it without any change to your own `.gitignore`.
Inside the container `.go-yolo/` is covered by an empty, read-only directory, so the agent can't
see or change it. A `.go-yolo` that is a symlink, isn't owned by you, or has files tracked by git
is refused: a repository must not ship it.

```bash
cd ~/src/myproject

go-yolo.sh claude                          # Claude Code, auto mode
go-yolo.sh claude -p "say hi"              # non-interactive (runs without tmux)
go-yolo.sh --yolo claude                   # no permission prompts
go-yolo.sh --yolo --net allowlist claude   # no prompts, restricted egress

go-yolo.sh codex                           # Codex CLI, approval prompts on
go-yolo.sh --yolo codex exec "run the tests and fix failures"   # without tmux too

go-yolo.sh vibe
go-yolo.sh --yolo vibe

go-yolo.sh opencode
go-yolo.sh --yolo opencode

go-yolo.sh shell                           # bash in the same environment
go-yolo.sh --no-tmux claude                # Claude without tmux
go-yolo.sh --dry-run codex                 # show the docker command
```

Before the agent starts, the launcher prints one line to stderr. It shows the agent, the image,
the network mode, the YOLO state and what is mounted, so you know which side of the boundary
you're on. stdout stays clean for `-p`/`exec` output. Set `GOYOLO_QUIET=1` to turn it off.

Launcher messages are colored when stderr is a terminal: errors red, warnings yellow, and in the
banner `yolo=ON` red, `net=open` yellow. `NO_COLOR` (or `TERM=dumb`) turns colors off;
`--color=always|never` overrides the detection. The agent's own output is never touched.

```
go-yolo: claude in container go-yolo:myproject-d0c6fbb2-a02bf713 · plan a02bf713 (2026-11-09 10:12) · net=open · yolo=off · tmux · rw: ~/src/myproject, ~/.claude, ~/.claude.json, ~/go/pkg/mod, ~/.cache/go-build · ro: ~/.gitconfig
```

Log in inside the container the first time (e.g. `/login` in Claude, `codex login`). The agent's
config directory is mounted from the host, so the login persists and is shared with the agent on
the host. Codex's browser login needs a callback on `localhost:1455`, which doesn't reach the
container, so use `codex login --device-auth` or an API key.

### Setup: what the container gets

The first time you run go-yolo in a project (or with `go-yolo.sh --setup`), a **picker** lists
what your host has, from every catalog, and you pick what this project's container gets:

```
go-yolo: pick what this project's container gets (versions always come from the host):
  host   image  locale en_US.UTF-8 (generated in the image)
  host   env    time zone Europe/Prague
  go     image  Go go1.27.0 (/opt/go/1.27.0)
  go     image  tools in /home/me/go/bin: dlv gopls
  go     cache  module cache (a project volume at /home/me/go/pkg/mod)
  go     cache  build cache (a project volume at /home/me/.cache/go-build)
  java   image  JDK 21.0.12.1, your default java, from apt (/usr/lib/jvm/java-21-openjdk-amd64)
  java   image  JDK 25.0.3 (/home/me/.gradle/jdks/eclipse_adoptium-25-amd64-linux.2)
  java   cache  gradle-caches (a project volume at /home/me/.gradle/caches)
  ...
go-yolo: add more, e.g. 'package protobuf-compiler', 'tool kotlin', 'mount ~/notes', 'env GITHUB_TOKEN' (Enter: done):
```

On a first setup a few items are **pre-selected from simple hints** (a `go.mod` pre-selects the
Go items, a `build.gradle` the JDKs and Gradle's caches); everything else is your choice. With
fzf installed it is an fzf multi-select (TAB picks), otherwise a numbered list to toggle
(`3 5-7`, `a` all, `n` none). Then you can add apt packages, host commands, read-only mounts
and env variables by name. Variables that look like secrets are listed but never pre-selected.

The picks are saved in `.go-yolo/config`, one per line (editing it by hand works too):

```
image  go       toolchain  -
image  go       tools      -
cache  go       cache      modules
image  java     jdk        /usr/lib/jvm/java-21-openjdk-amd64
image  host     package    protobuf-compiler
env    host     env        GITHUB_TOKEN
```

The config says **what**, never which version: versions are read from the host on every run.
After the setup nothing is detected again; a new JDK on the host, say, shows up in the picker
the next time you run `--setup`. A picked item the host no longer has gets a ⚠ in the plan.

Without a terminal, a project without a setup stops with a hint, unless you pass `--yes` (take
the suggested picks); a dry run previews the suggested picks without saving them. An old config
(`extra`/`exclude` lines) is converted on the next setup and kept as `config.old`.

### The plan

Before anything is built, go-yolo works out a **plan**: what goes into the project's image and
what is passed into the container. (The shared base image is built first, without asking: it is
the same for every project and holds nothing from your host.) A new plan is shown as a summary,
one line per group plus every item with a warning in full, and you confirm it:

```
go-yolo: plan for /home/me/src/myapp (new; go-yolo.sh --setup changes the picks):
  host:  base debian-trixie-d33d4892, 1 locale, 4 parity notes, 1 env
  go:    toolchain go1.27.0, tools (2 files), 2 caches, 3 domains, 5 env
  extra: 2 packages
  warnings:
    package   zlib1g-dev=1:1.3.dfsg+really1.3.1-1+deb13u1 [extra]  ⚠ the host has 1:1.3.dfsg+really1.3.1-1+b1, an older version: the image gets the archive's version (apt upgrade the host to match)
    parity    tzdata=2026f-0+deb13u1  ⚠ the base image has this newer version, the host has 2026e-0+deb13u1 (apt upgrade the host to match)
go-yolo: every item: go-yolo.sh --plan (or [p] below)
go-yolo: warning: the plan has warnings (⚠); check them before you go on
go-yolo: use this plan? [y]es [n]o [p]lan [s]etup [e]dit config [d]ockerfile:
```

`p` (or `--plan` on the command line) shows every item; `s` opens the setup picker on the
current picks (to leave out an item with a warning, say) and shows the plan again; `e` opens `.go-yolo/config` in
`$VISUAL`/`$EDITOR` and shows the plan again; `d` shows the generated Dockerfile (also kept in
`.go-yolo/build/Dockerfile`). Enter or `n` stops without building.

Later runs ask again **only when the plan exposes something new**: an item that wasn't in the
confirmed plan, or one that was left out and is now included (a newly set env variable, a new
mount, ...). Anything else, such as a version bump, a new base image, a changed parity note or a
removed item, is taken with one line, and the image is rebuilt if needed:

```
go-yolo: plan updated, nothing new exposed: package zlib1g-dev 1:1.3.dfsg+really1.3.1-1+b1 → 1:1.3.dfsg+really1.3.1-1+deb13u1
```

Without a terminal, a plan that needs asking is never used: go-yolo exits with an error unless you
pass `--yes`. A dry run shows the plan and goes on without saving it.

The host items:

| item | what | how |
|------|------|-----|
| `base` | the shared base image (OS, agents, entrypoint): always | `FROM go-yolo-base:<distro>-<codename>-<hash>` |
| `parity` | base image packages whose version differs from the host's: always, a warning only | the base installs the archive's current versions; `apt upgrade` the host, or `--rebuild` the base, to match |
| `cert` | the host's extra CA certificates (`/usr/local/share/ca-certificates`) | copied to the same path, `update-ca-certificates` |
| `locale` | the locales of `LANG`, `LC_ALL` and `LC_*` (C and POSIX are built in), plus the `locales` package | `localedef` in the image, as `locale-gen` would; a locale the host doesn't support is left out with a warning |
| `env` | `TZ` (the host's time zone), proxy variables (`HTTP_PROXY`, `https_proxy`, `NO_PROXY`, ...), variables added by name | passed with `docker run -e`, never baked into the image |
| `package` | apt packages added by name | `apt-get install name=version` |

The base image's own packages (git, gcc, libc6, ...) come from the archive when the base is
built, so they can differ from the host's: each difference is a `parity` warning. The base
image is built before the plan is resolved, so the comparison is in the first plan already. The
base image's package list is cached in `~/.cache/go-yolo/`.

Packages get the **host's version**, so the container matches the host. The image never
downgrades a package: if the host is behind the archive, the image gets the archive's newer
version and the plan warns (`apt upgrade` the host to match). A package that isn't installed on
the host gets a warning too, since a build that needs it works in the container but not on the
host. Packages whose host version isn't in the distro archive (third-party repositories,
backports) can't be installed and are left out, with a warning.

Variables that look like secrets (`*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*KEY*`, `*CREDENTIAL*`,
`*AUTH*`, or a URL with a password) are only passed when you pick them. Their values are never
shown or stored, only a hash, so a change is still noticed.

The confirmed plan is stored in `.go-yolo/plan`. The project image's tag
(`go-yolo:<project>-<path hash>-<plan hash>`) includes a hash of the plan's build-time items, so
a change to them builds a new image; a change to `env` items only needs your confirmation.

### Go

The setup offers the host's Go, as the host's `go env` reports it (read with
`GOTOOLCHAIN=local`, so reading it never downloads a toolchain); a `go.mod` or `go.work`
pre-selects it:

| item | what | how |
|------|------|-----|
| `toolchain` | `GOROOT` | copied into the image at the same path (its apt packages if it comes from apt) |
| `tools` | `GOBIN`, or the first GOPATH entry's `bin/` | copied at the same path, owned by you: `go install` works in the container, but its results don't outlive it |
| `cache` | `GOMODCACHE`, `GOCACHE` | the project's Docker volumes `go-mod` and `go-build`, at the host's paths; they start empty and persist between runs |
| `mount` | the `GOENV` file (`go env -w` settings); a `go.work` outside the repository and the modules it uses outside it | read-only at the same path, with a warning for the outside ones |
| `package` | the libraries of `#cgo pkg-config: NAME` lines (the package owning `NAME.pc` on the host), and pkg-config | apt, at the host's versions |
| `env` | `GOPATH`, `GOBIN`, `GOMODCACHE`, `GOCACHE`, `GOENV`; Go variables set in your environment (`GOFLAGS`, `GOPRIVATE`, `CGO_ENABLED`, `CC`, ...) | `docker run -e` |
| `domain` | the `GOPROXY` and `GOSUMDB` hosts | allowed with `--net allowlist` |

The toolchain and tools are first on `PATH`. Your `~/go`, `~/go/bin` and `~/.cache/go-build`
are never mounted, so nothing the agent does there reaches the host. The first build of a
project downloads its modules into the project's volume (so it needs the network); later builds
work with `--net none`. `--parity` compares `go version`, `go env` and the tools.

### Java

The setup offers the host's Java; a `pom.xml`, `mvnw`, `build.gradle(.kts)`,
`settings.gradle(.kts)` or `gradlew` pre-selects the JDKs and the matching caches and settings:

| item | what | how |
|------|------|-----|
| `toolchain` | **each JDK on the host**: `/usr/lib/jvm/*`, SDKMAN, `~/.jdks` (IntelliJ), mise, asdf, Gradle's provisioned JDKs (`~/.gradle/jdks`), `org.gradle.java.installations.paths`, `toolchains.xml`'s `jdkHome`s | apt packages for apt-installed JDKs (and links such as `default-java`), copies at the same path, owned as on the host, for the rest; the default `java` (`$JAVA_HOME`, else the one on `PATH`) first on `PATH` |
| `toolchain` | Maven or Gradle, when they are on `PATH` (pre-selected if the project has no wrapper) | as an added host command |
| `mount` | `~/.m2/settings.xml`, `toolchains.xml`; `GRADLE_USER_HOME`'s `gradle.properties`, `init.gradle(.kts)`, `init.d/` | read-only at the same path |
| `cache` | the Maven local repository (`<localRepository>` or `~/.m2/repository`) and `~/.m2/wrapper`; Gradle's `caches/` and `wrapper/` | the project's Docker volumes, at the host's paths; they start empty, so the first build downloads the wrapper's distribution and the dependencies |
| `env` | `JAVA_HOME`, `JAVA_OPTS`, `JAVA_TOOL_OPTIONS`, ...; for Maven `MAVEN_OPTS`, ...; for Gradle `GRADLE_OPTS`, `GRADLE_USER_HOME`, `ORG_GRADLE_PROJECT_*` (secrets filtered) | `docker run -e` |
| `domain` | Maven Central, the Gradle services, the hosts in `settings.xml` and the wrappers' download URLs | allowed with `--net allowlist` |

An apt JDK that is behind the archive gets the archive's newer version (never a downgrade) and a
⚠ in the plan, so `apt upgrade` the host to match. `--parity` compares `java -version`, the JVM's
main system properties (`java.home`, encodings, user language and country), `javac`, the JDKs
found in the usual places, and `mvn -v`/`gradle --version` when they are on `PATH`.

### Checking parity

`go-yolo.sh --parity` (from the project root, like a normal run) runs the same probes on the
host and in the project's container and shows each result:

```
go-yolo: the same probes on the host and in the container (go-yolo:myapp-d0c6fbb2-a02bf713):
  ✓ user                         me (1000:1000)
  ✓ directory                    /home/me/src/myapp
  ✗ umask                        host: 0002
                                 container: 0022
  ✓ glibc                        glibc 2.41
  ✓ time zone                    Europe/Prague (CET+0100)
  ✓ tool git                     git version 2.47.3
  ✓ env TZ                       Europe/Prague
go-yolo: warning: 1 of 7 probes differ
```

The probes cover the user, home, working directory, umask, architecture, glibc, locale, time
zone, the base tools (gcc, make, git, python3), and every env variable, package and CA
certificate in the plan (secret values only as a hash). The exit status is 1 if anything
differs. Each catalog can add probes (`<catalog>_probe` in `catalogs/<catalog>.sh`); both sides run the same
code, copied into the container.

### tmux

By default the agent runs in the first window of a tmux session inside the container.
Non-interactive runs are the exception: `claude -p`, `codex exec`, `opencode run`, `vibe -p`,
`shell -c`, other output-only subcommands (`AGENT_BATCH_ARGS` and `AGENT_BATCH_COMMANDS` in
`agents/<agent>.conf`) and `--help`/`--version` run directly, because their output would vanish
with the tmux window. `--tmux` forces tmux anyway. Press
`prefix c` to open a bash window next to it, e.g. to run tests or watch logs while the agent works.
Every window runs as the same unprivileged user, behind the same firewall. Use this rather than
`docker exec`: an exec'd process skips the entrypoint's privilege drop, and in allowlist mode it
would still hold `NET_ADMIN`, so it could remove the firewall.

- The prefix is `C-b`. If you start go-yolo from inside a host tmux, it is `C-a`, so `C-b` still
  reaches the outer tmux.
- The status bar shows `go-yolo | <agent> | net=… | yolo=…`. It turns red in YOLO mode. The
  terminal title is set to `go-yolo: <window>`.
- Detaching (`prefix d`) is disabled, because the tmux client is the container's main process.
  The container stops when the last window closes.
- The mouse is on, so the wheel scrolls back through agent output. Hold Shift to select text
  natively. Copying from tmux uses OSC 52 to reach the host clipboard.
- The config is `tmux/tmux.conf`. Your own `~/.tmux.conf` is not read.
- tmux needs a terminal. Without one (stdin or stdout not a TTY) the agent runs directly, without
  tmux. With tmux the launcher always exits with status 0, so pass `--no-tmux` when the exit
  status of an interactive-looking run matters.
- Options that need a newer tmux than the image has (e.g. `allow-passthrough` on Ubuntu 22.04's
  tmux 3.2a) are skipped silently.
- `--no-tmux` turns tmux off.

### What gets mounted

Each path is mounted at the **same absolute path**, and only if it exists:

| host path                                    | mode       | when                                                |
|----------------------------------------------|------------|-----------------------------------------------------|
| `$PWD`                                       | read-write | always                                              |
| `$PWD/.go-yolo`                              | hidden     | always (an empty read-only tmpfs covers it)         |
| `~/.gitconfig`                               | read-only  | if it exists                                        |
| `~/.config/git/config`, `ignore`, `attributes` | read-only | each file, if it exists                            |
| the plan's `mount` and `cache` items | read-only; caches are the project's Docker volumes | see [The plan](#the-plan), [Go](#go) and [Java](#java) |
| the selected agent's config (table below)    | read-write | that agent only, never another agent's config      |
| each `--mount` / `GOYOLO_MOUNTS` path        | read-only, or `:rw` | when given (see below)                     |

A missing agent config directory is created on the host (mode 700) so a login persists. A missing
`.json` config file (e.g. `~/.claude.json`) is created containing `{}` (mode 600), for the same
reason. Other missing config files are skipped.

Every mount is checked, including automatic toolchains, caches, agent config and the workdir.
System roots (`/`, `/usr`, `/etc`, ...), `$HOME` and its parents are refused, including symlink
aliases. `/run`, `/dev`, `/proc`, `/sys` and their descendants are also refused. Unsafe cache
settings such as `GOMODCACHE=$HOME`, `GOROOT=/usr` or `GRADLE_USER_HOME=$HOME` stop the launcher
with an error.
Mounts must also avoid `/opt/go-yolo`, system executable and library directories, and `/etc`
configuration paths used during privileged startup.

### Extra mounts

Mount more host paths with `--mount PATH[:ro|:rw]` (repeatable) or `GOYOLO_MOUNTS` (whitespace-separated,
same syntax). Mounts are **read-only unless you add `:rw`**:

```bash
go-yolo.sh --mount ~/src/shared-lib --mount ~/datasets:rw claude
GOYOLO_MOUNTS="$HOME/src/shared-lib $HOME/notes:rw" go-yolo.sh claude
```

Relative paths are resolved against the current directory. A path that doesn't exist is an error.
A symlink is mounted at its own path, with the directory it resolves to as the source.
The mount safety checks above also apply here. Explicit mounts are added before the automatic
ones, so the first mode given for a path wins. `GOYOLO_MOUNTS` can't hold paths with spaces; use
`--mount` for those.

Your UID, GID, username, `$HOME` path and umask are the same as on the host, so files the agent
creates belong to you and get the same permissions. `LANG`, `LANGUAGE`, `LC_ALL` and `LC_*` are
passed too; their locales are generated in the project image (see [The plan](#the-plan)). If one
is missing anyway (a locale you didn't pick), `LANG` falls back to `C.UTF-8` and an `LC_*` variable
is dropped.

### Other host commands

A host command added in the setup (`tool NAME`) brings that command: its apt packages if apt installed
it, otherwise its install directory (the `<dir>` of the `<dir>/bin/NAME` it resolves to, keeping
an SDKMAN-style `current` link), copied into the image and put first on `PATH`. A command that is a
plain file in a shared `bin/` (`~/bin/foo`) can't be copied on its own and is flagged in the plan.
`GOYOLO_TOOLS` is gone; go-yolo warns if it is still set.

## YOLO mode

YOLO mode is **opt-in on every run**: only `--yolo` on the command line turns it on. It is never read
from the environment or a config file, and no alias adds it. When it is on, the launcher prints a
warning, and with `--net open` the warning also says that network access is unrestricted.

| agent    | normal run                                                     | `--yolo` adds                                           | config mounts                                      |
|----------|----------------------------------------------------------------|---------------------------------------------------------|----------------------------------------------------|
| claude   | `claude --permission-mode auto`                                | `--permission-mode bypassPermissions`                   | `~/.claude`, `~/.claude.json`                      |
| codex    | `codex --sandbox danger-full-access` (approval prompts stay on) | `--dangerously-bypass-approvals-and-sandbox`           | `~/.codex`                                         |
| vibe     | `vibe`                                                         | `--auto-approve`                                        | `~/.vibe`                                          |
| opencode | `opencode` with your own config                                | env `OPENCODE_CONFIG_CONTENT={"permission":"allow"}`    | `~/.config/opencode`, `~/.local/share/opencode`    |

Codex's own Linux sandbox (Landlock/seccomp/bubblewrap) does not work inside an unprivileged Docker
container, so it is always turned off. Without `--yolo`, Codex still asks before running commands.
opencode's YOLO setting is passed as inline config, which opencode merges on top of your global and
project config. Your mounted config is never modified.

## Network modes

| mode        | effect                                                                                          |
|-------------|-------------------------------------------------------------------------------------------------|
| `open`      | default. Normal Docker networking, no extra capabilities.                                       |
| `allowlist` | egress only to allowed domains. The container gets `NET_ADMIN`/`NET_RAW`, the entrypoint sets up iptables/ipset, then drops all capabilities before the agent starts. If firewall setup fails, the container exits. It never falls back to open networking. |
| `none`      | `--network none`: no network at all (the agent can't reach its API either).                      |

In `allowlist` mode, the allowed IPv4 destinations are:

- every domain in `firewall/allowlist.txt` (GitHub, Go proxy, Maven Central, Gradle, npm, PyPI),
- the selected agent's `AGENT_DOMAINS` from `agents/<agent>.conf` (for `shell`: every agent's domains),
- `GOYOLO_EXTRA_DOMAINS`,
- GitHub's `web`, `api` and `git` IP ranges from `https://api.github.com/meta`,
- DNS (port 53) to the nameservers in the container's `/etc/resolv.conf`.

All IPv6 traffic is dropped. Other connections are rejected right away, so tools fail fast. On
startup the firewall checks that `https://api.github.com` works and that `example.com` (or
`example.net`/`example.org`, at an address outside the allowlist) is blocked.

### Adding a domain

For one run:

```bash
GOYOLO_EXTRA_DOMAINS="api.groq.com openrouter.ai" go-yolo.sh --net allowlist opencode
```

Permanently: add it to `AGENT_DOMAINS` in `agents/<agent>.conf`, or for every agent to
`firewall/allowlist.txt`. Editing either file changes the image hash, so the next run rebuilds the image.

## Adding a new agent

1. Create `agents/<name>.conf`:

   ```bash
   AGENT_BIN="mytool"
   AGENT_ARGS=()                     # always passed
   AGENT_YOLO_ARGS=(--yes-to-all)    # only with --yolo
   AGENT_ENV=()                      # KEY=VALUE, always set
   AGENT_YOLO_ENV=()                 # KEY=VALUE, only with --yolo
   AGENT_MOUNTS=("$HOME/.mytool")    # mounted read-write at the same path
   AGENT_BATCH_ARGS=(--print)        # non-interactive flags (anywhere): run without tmux
   AGENT_BATCH_COMMANDS=(run)        # non-interactive subcommands (first arg): run without tmux
   AGENT_DOMAINS=(api.mytool.dev)    # allowed in --net allowlist mode
   ```

   Put every setting that turns off prompts in `AGENT_YOLO_ARGS`/`AGENT_YOLO_ENV`, never in
   `AGENT_ARGS`/`AGENT_ENV`. A missing `AGENT_MOUNTS` entry ending in `.json` is created
   containing `{}`. Another missing entry whose name (ignoring a leading dot) contains a dot, such
   as `.mytool.toml`, is treated as a file and skipped. Anything else is treated as a directory and
   created on the host.
2. Add a system-wide install line to the `Dockerfile` (`npm install -g …`, `uv tool install …`, or
   a binary in `/usr/local/bin`). Never install into a home directory.
   That's all: go-yolo finds the agents in `agents/*.conf` (and catalogs in `catalogs/*.sh`, see
   `catalogs/README.md`).

## Updating agents

The agents' auto-updaters are turned off. To update everything:

```bash
go-yolo.sh --rebuild shell
```

`--rebuild` pulls the current base image and disables Docker's build cache, so package and agent
installation steps run again even when the base image has not changed. Ordinary builds keep using
the cache. To pin versions, set any of `GOYOLO_CLAUDE_VERSION`,
`GOYOLO_CODEX_VERSION`, `GOYOLO_OPENCODE_VERSION`, `GOYOLO_VIBE_VERSION`, `GOYOLO_UV_VERSION` or
`GOYOLO_NODE_MAJOR` (default 24) for the rebuild, e.g.
`GOYOLO_CLAUDE_VERSION=2.1.296 go-yolo.sh --rebuild claude`.

Node.js comes from nodejs.org. Its `SHASUMS256.txt` is checked against the Node.js release keys
fetched from `github.com/nodejs/release-keys`, so a build needs both hosts reachable.

The base image is tagged `go-yolo-base:<distro>-<codename>-<hash>` (plus
`go-yolo-base:<distro>-<codename>`). The hash covers the `Dockerfile`, `entrypoint.sh`, `scripts/`,
`agents/`, `firewall/` and `tmux/`, so editing any of them triggers a rebuild. A new base changes
every project's plan, so each project shows the change and rebuilds its image on its next run.
`--rebuild` rebuilds both images without the build cache. Old images are not deleted
automatically, and neither are the projects' cache volumes; `go-yolo.sh --prune` lists both:

```
go-yolo: images and cache volumes (✓ in use, ✗ stale):
  ✓ image  go-yolo-base:debian-trixie                     2.4GB  2 hours ago        points to the newest base image
  ✓ image  go-yolo-base:debian-trixie-5a5324ec            2.4GB  2 hours ago        the base image of this go-yolo version
  ✗ image  go-yolo-base:debian-trixie-3c23a8bf            2.3GB  3 days ago         an older base image
  ✓ image  go-yolo:myapp-d0c6fbb2-a02bf713                2.4GB  2 hours ago        /home/me/src/myapp
  ✗ image  go-yolo:myapp-d0c6fbb2-77e1c2a9                2.4GB  3 days ago         an older plan of /home/me/src/myapp
  ✗ image  go-yolo:oldapp-1b2c3d4e-5f6a7b8c               2.4GB  2 weeks ago        project is gone: /home/me/src/oldapp
  ✓ volume go-yolo-myapp-d0c6fbb2-go-mod           50.3MB  2026-11-09         go-mod cache of /home/me/src/myapp
  ✗ volume go-yolo-oldapp-1b2c3d4e-go-mod           120MB  2026-10-20         project is gone: /home/me/src/oldapp
go-yolo: remove the 4 ✗ ones? [y]es [n]o [p]ick:
```

An image is current if it is the base image of this go-yolo version, or a project's image for
its confirmed plan; a cache volume is current if its project's confirmed plan still has that
cache. `p` lets you pick what to remove (with fzf if it is installed, otherwise one
y/n question per image), current images included. Without a terminal `--prune` only lists;
`--prune --yes` removes the stale images without asking. Images a running container uses can't be
removed; `--prune` says so and goes on. Cached package lists of removed base images are deleted
too.

## Code layout

`go-yolo.sh` only lists the steps of a run; each step lives in a small module under `lib/`:

| file                | what it does                                                       |
|---------------------|--------------------------------------------------------------------|
| `lib/ui.sh`         | colors, `die`/`warn`/`note`                                        |
| `lib/args.sh`       | command-line options and usage                                     |
| `lib/aliases.sh`    | `--print-aliases`, `--install-aliases`, `--uninstall-aliases`      |
| `lib/host.sh`       | host distro, release and user                                      |
| `lib/image.sh`      | image name, content hash and build                                 |
| `lib/mounts.sh`     | mount safety checks; workdir, extra and git config mounts          |
| `lib/project.sh`    | git repository root check, the `.go-yolo/` state directory         |
| `lib/config.sh`     | `.go-yolo/config`: the picks                                       |
| `lib/setup.sh`      | the setup picker: candidates, suggestions, saving the picks        |
| `lib/kinds.sh`      | the plan's item kinds and flags, each declared once                |
| `lib/plan.sh`       | the plan model: adding, finding, sorting, hashing, saving items    |
| `lib/apt.sh`        | apt versions and owners; apt package items                         |
| `lib/items.sh`      | the other helpers catalogs use to add items                        |
| `lib/confirm.sh`    | showing, diffing and confirming the plan                           |
| `lib/agent.sh`      | the agent profile and its config mounts                            |
| `lib/run.sh`        | network mode, tmux decision, the `docker run` command, the banner  |
| `lib/prune.sh`      | `--prune`: image status, removal                                   |
| `lib/parity.sh`     | `--parity`: runs the catalogs' probes on both sides and compares them |
| `catalogs/host.sh`  | plan items every project gets (base, CAs, time zone, proxies, extras) |
| `catalogs/go.sh`    | the Go catalog                                                     |
| `catalogs/java.sh`  | the Java catalog (JDKs, Maven, Gradle)                             |
| `catalogs/README.md`| the catalog contract and a template for a new one                  |

Everything inside the container (`entrypoint.sh`, `scripts/`, `agents/`, `firewall/`, `tmux/`)
is part of the image. `docs/PLAN.md` describes where this is heading.

## Checks

Run launcher regressions without Docker or host toolchains:

```bash
bash tests/run.sh
bash tests/lint.sh        # shellcheck over the launcher, entrypoint, catalogs
```

It uses stub commands from `tests/fixtures/` and never changes your real config;
`bash tests/run.sh go java` runs only those test files. `tests/README.md` explains the layout,
the helpers, the stubs and the launcher's test hooks.
The tmux selection checks need `script(1)` (util-linux) and are skipped without it.

After building an image, check privilege dropping, executable shadows and the allowlist firewall:

```bash
bash tests/docker.sh go-yolo-base:debian-trixie    # use your image's distro/codename tag
```

The container checks use temporary fixtures, require working allowlist networking, and report a
skip when Docker is unavailable.

## Known limitations

- **Allowlist IPs are resolved once at startup.** CDN-backed hosts can change IPs during a long
  session, and connections to the new IPs are then rejected. Restart the container if that happens.
  Hosts that share IPs with an allowed host (e.g. behind the same CDN) are reachable too.
- Allowlist mode is IPv4 only. All IPv6 is blocked.
- The Kali image matches the host's glibc only while both are up to date (rebuild after upgrading).
- Only the host's primary GID is mapped. Supplementary groups are not.
- Running as root on the host (UID 0) is refused.
- Only the GOPATH's first entry's `bin/` is copied when GOPATH is a list (as `go install` uses it).
- Private modules (`GOPRIVATE`, `GONOPROXY`) are fetched directly, as on the host, but the
  container has no SSH keys or `~/.netrc`, so that fails.
- A project's first build downloads all its dependencies into its cache volumes, so it needs the
  network (`--net allowlist` allows the usual registries).
- OAuth logins that redirect to `localhost` on the host don't reach the container. Use a device
  code flow or an API key where the agent offers one.
- The agent's config directory is shared with the host install of the same agent (by design: one
  login). Different agent versions inside and outside the container may disagree on its format.
- The launcher uses the image's `tini` as PID 1, started *after* the privilege drop, instead of
  `docker run --init`. Docker's init would stay root with the container's capabilities
  (including `NET_ADMIN` in allowlist mode).
