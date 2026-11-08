# go-yolo

`go-yolo` runs AI coding agents (**Claude Code**, **OpenAI Codex CLI**, **Mistral Vibe**, **opencode**)
inside a Docker container that mirrors your host user, your project directory, your Go toolchain
and other host toolchains (Java, Maven, Gradle, ...).

By default the agent runs **with its normal permission prompts** (Claude Code starts in auto mode,
where a classifier approves safe actions and prompts for risky ones). With `--yolo` those prompts are
turned off ("YOLO mode"). The container is the safety boundary: inside it the agent can do
anything, but outside it the agent only reaches what the launcher explicitly mounts.

```
./go-yolo.sh [launcher-opts] <agent> [agent args...]

agents:  claude | codex | vibe | opencode | shell
opts:    --net open|allowlist|none   (default: open)
         --rebuild                   force image rebuild
         --yolo                      turn off the agent's permission prompts (default: off)
         --no-tmux                   don't run the agent inside tmux (default: tmux on a TTY,
                                     except for non-interactive runs such as claude -p;
                                     prefix c: extra shell)
         --tmux                      always use tmux, even for non-interactive runs
         --mount PATH[:ro|:rw]       also mount PATH at the same path (default: ro; repeatable)
         --dry-run                   print the docker command and exit
         -h | --help

env:     GOYOLO_TOOLS="java mvn gradle"  host tools to mount (read-only) and put on PATH
                                     (default shown; add e.g. sbt kotlin ant, or set empty)
         GOYOLO_MOUNTS="PATH[:ro|:rw] ..."  extra mounts, like --mount (whitespace-separated)
         GOYOLO_GOPATH_MODE=rw|ro|modcache  how GOPATH is mounted (default: rw)
         GOYOLO_EXTRA_DOMAINS="a.example ..."  more domains for --net allowlist
         GOYOLO_QUIET=1                     don't print the mount summary line
         GOYOLO_{CLAUDE,CODEX,OPENCODE,VIBE,UV}_VERSION, GOYOLO_NODE_MAJOR
                                     version pins for the image build (use with --rebuild)

alias commands (no agent needed):
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
- **`~/go/bin` when GOPATH is mounted read-write** (the default). The agent can replace binaries
  that you later run on the host. Use `GOYOLO_GOPATH_MODE=modcache` or `ro` to avoid this.
- **`~/.m2` and `~/.gradle`** (mounted read-write when `mvn`/`gradle` are in `GOYOLO_TOOLS`, the
  default). `settings.xml` and `gradle.properties` often hold repository credentials, and the
  agent can add a Gradle init script that later runs on the host. Set `GOYOLO_TOOLS=` to opt out.
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
- Optional: Go on the host. Its toolchain and caches are mounted into the container.
- Optional: a JDK, Maven, Gradle (or other tools, see [Host toolchains](#host-toolchains)) on the
  host. They are mounted into the container too.

The image's base matches the host (`debian:<codename>`, `ubuntu:<codename>` or
`kalilinux/kali-rolling`), so host-mounted binaries (the Go toolchain, `~/go/bin/*`, a JDK) find the same
glibc. **Kali is a rolling release:** the image's glibc matches the host only while both are up to
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

The first run builds the image (a few minutes). Later runs start immediately.

## Usage

Run it from a project directory. Running from `$HOME`, `/` or any parent of `$HOME` is refused.

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

```
go-yolo: claude in container go-yolo:debian-trixie-bddc78a0 · net=open · yolo=off · tmux · rw: ~/src/myproject, ~/go, ~/.cache/go-build, ~/.claude, ~/.claude.json · ro: ~/.gitconfig, /opt/go/1.27.0
```

Log in inside the container the first time (e.g. `/login` in Claude, `codex login`). The agent's
config directory is mounted from the host, so the login persists and is shared with the agent on
the host. Codex's browser login needs a callback on `localhost:1455`, which doesn't reach the
container, so use `codex login --device-auth` or an API key.

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
| `~/.gitconfig`                               | read-only  | if it exists                                        |
| `~/.config/git/config`, `ignore`, `attributes` | read-only | each file, if it exists                            |
| `GOROOT`                                     | read-only  | if `go` is on `PATH`                                |
| `GOPATH`                                     | `GOYOLO_GOPATH_MODE` (`rw` default, `ro`) | if `go` is on `PATH`   |
| `GOMODCACHE` only                            | read-write | `GOYOLO_GOPATH_MODE=modcache`                       |
| `GOCACHE`, `GOENV` file                      | rw / ro    | if they exist                                       |
| each `GOYOLO_TOOLS` tool's install dir       | read-only  | if the tool is on `PATH` (see below)                |
| `~/.m2`, `GRADLE_USER_HOME` or `~/.gradle`, `~/.sbt`, `~/.ivy2`, `~/.cache/coursier` | read-write | if the matching tool is in `GOYOLO_TOOLS` |
| the selected agent's config (table below)    | read-write | that agent only, never another agent's config      |
| each `--mount` / `GOYOLO_MOUNTS` path        | read-only, or `:rw` | when given (see below)                     |

A missing agent config directory is created on the host (mode 700) so a login persists. A missing
`.json` config file (e.g. `~/.claude.json`) is created containing `{}` (mode 600), for the same
reason. Other missing config files are skipped.

Every mount is checked, including automatic toolchains, caches, agent config and the workdir.
System roots (`/`, `/usr`, `/etc`, ...), `$HOME` and its parents are refused, including symlink
aliases. `/run`, `/dev`, `/proc`, `/sys` and their descendants are also refused. Unsafe cache
settings such as `GOPATH=$HOME` or `GRADLE_USER_HOME=$HOME` stop the launcher with an error.
Mounts must also avoid `/opt/go-yolo`, system executable and library directories, and `/etc`
configuration paths used during privileged startup. Debian JDK installations under
`/usr/lib/jvm` and their Java configuration directories remain supported.

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
ones, so `--mount ~/.m2:ro` makes the Maven cache read-only. `GOYOLO_MOUNTS` can't hold paths with spaces; use
`--mount` for those.

Your UID, GID, username and `$HOME` path are the same as on the host, so files the agent creates
belong to you.

### Host toolchains

`GOYOLO_TOOLS` lists host commands to bring into the container (default `java mvn gradle`):

```bash
GOYOLO_TOOLS="java mvn gradle sbt kotlin ant" go-yolo.sh claude
GOYOLO_TOOLS= go-yolo.sh claude                 # no host tools, no Java/Maven/Gradle caches
```

For each tool on `PATH`, the launcher follows its symlinks (`/usr/bin/java → /etc/alternatives →
/usr/lib/jvm/...`, SDKMAN's `current`) to the real executable, which must sit in
`<install dir>/bin`. The install dir is mounted read-only and its `bin` is put first on `PATH`. For
`java`, a host `JAVA_HOME` takes precedence, and `JAVA_HOME` is set in the container. Directories
that the install dir's symlinks point into (Debian's `/etc/java-N-openjdk`, `/etc/ssl/certs/java`,
`/usr/share/java`) are mounted read-only as well. A host `GRADLE_USER_HOME` is passed into the
container when `gradle` is listed.

A tool installed straight into a system or home directory (e.g. `/usr/bin/foo`, `~/bin/foo` as a
plain file) is skipped with a warning: mounting `/usr` or `~` would expose too much. A listed tool
that isn't installed is skipped silently, but its cache directories are still mounted, so
`./mvnw` and `./gradlew` projects reuse them.

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
3. Add the name to `AGENTS` in `go-yolo.sh` and to the agent check in `entrypoint.sh`.

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

Images are tagged `go-yolo:<distro>-<codename>-<hash>` (plus `go-yolo:<distro>-<codename>`). The
hash covers the `Dockerfile`, `entrypoint.sh`, `scripts/`, `agents/`, `firewall/` and `tmux/`, so editing
any of them triggers a rebuild. Old images are not deleted automatically: `docker image ls go-yolo`.

## Checks

Run launcher regressions without Docker or host toolchains:

```bash
bash tests/run.sh
```

It uses stub `go` and `docker` commands from `tests/fixtures/` and never changes your real config.
The tmux selection checks need `script(1)` (util-linux) and are skipped without it.

After building an image, check privilege dropping, executable shadows and the allowlist firewall:

```bash
bash tests/docker.sh go-yolo:debian-trixie    # use your image's distro/codename tag
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
- Only the GOPATH's first entry is mounted when GOPATH is a list.
- OAuth logins that redirect to `localhost` on the host don't reach the container. Use a device
  code flow or an API key where the agent offers one.
- The agent's config directory is shared with the host install of the same agent (by design: one
  login). Different agent versions inside and outside the container may disagree on its format.
- The launcher uses the image's `tini` as PID 1, started *after* the privilege drop, instead of
  `docker run --init`. Docker's init would stay root with the container's capabilities
  (including `NET_ADMIN` in allowlist mode).
