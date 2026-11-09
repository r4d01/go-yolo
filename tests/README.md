# Tests

```bash
bash tests/run.sh               # every launcher test file (no Docker daemon or toolchains needed)
bash tests/run.sh go java       # only tests/test-go.sh and tests/test-java.sh
bash tests/lint.sh              # shellcheck over the launcher, entrypoint, scripts and catalogs
bash tests/docker.sh IMAGE      # container checks against a built base image
```

## Layout

| file | what |
|------|------|
| `lib.sh` | shared setup, sourced first by every test file: a fresh temp directory with a fixture home and git project, the stub commands, and the helpers |
| `test-mounts.sh` | mount safety, extra mounts, git and agent config mounts |
| `test-terminal.sh` | tmux selection, colors |
| `test-project.sh` | the git repository root, `.go-yolo/` |
| `test-plan.sh` | the plan: packages, certificates, env, diff, confirmation, the base comparison, the prompt |
| `test-locales.sh` | locales and the umask |
| `test-go.sh`, `test-java.sh` | the Go and Java catalogs (and `extra tool`) |
| `test-prune.sh`, `test-parity.sh` | `--prune`, `--parity` |
| `test-images.sh` | image builds: `--rebuild`, the build cache, reuse |
| `docker.sh` | real containers: privilege drop, executable shadows, firewall, umask, locales, cache volume ownership |
| `fixtures/` | stub commands and their data |

A test file prints `ok - <what>` per group and stops at its first failure. Each starts from scratch,
so files don't depend on each other; within a file the groups run in order.

## Helpers (`lib.sh`)

| helper | does |
|--------|------|
| `launch ARGS...` | run `go-yolo.sh` in the fixture project with a clean environment (`env -i`) pointing at the stubs; `TEST_ENV=(VAR=value ...)` adds variables, `LAUNCH_DIR` another directory |
| `launch_in DIR ARGS...` | like `launch` from `DIR`, printing only stderr and never failing |
| `dry_run ARGS...` | `launch --dry-run`, the docker command split into `ARGS` |
| `has_arg VALUE`, `assert_mount SOURCE TARGET rw\|ro` | check `ARGS` |
| `reject ARGS...` | expect go-yolo to refuse (`refusing to ...`) |
| `expect_plan TEXT` | expect `plan_text` (captured from a dry run's stderr) to contain `TEXT` |
| `removed_items` | the images and volumes the docker stub was asked to remove |
| `fail MESSAGE`, `pass MESSAGE` | end a group |

## Stub commands (`fixtures/`)

| stub | stands in for | driven by |
|------|---------------|-----------|
| `docker` | the Docker CLI: logs every call to `DOCKER_TEST_LOG` | `DOCKER_TEST_IMAGE_STATUS` (`0` every image exists, `1` none does, `built-on-build` only the built ones), `DOCKER_TEST_IMAGE_ID`, `DOCKER_TEST_IMAGES` and `DOCKER_TEST_VOLUMES` (`--prune`'s lists), `DPKG_BASE_FIXTURE` (the base image's packages), `DOCKER_TEST_RUN_SCRIPT=1` and `DOCKER_TEST_PARITY_SED` (`--parity`'s container side runs locally) |
| `go` | `go env NAME...` (from the environment), `go version`, `go work edit -json` | `GOVERSION`, `GO_TEST_WORK_JSON` |
| `apt-cache` | `apt-cache policy` | `APT_POLICY_FIXTURE` |
| `dpkg-query` | the host's installed packages | `DPKG_HOST_FIXTURE` |
| `dpkg` | `dpkg -S` (anything else goes to the real dpkg) | `DPKG_S_FIXTURE` |
| `pkg-config` | `pkg-config --variable pc_path pkg-config` | `PC_PATH_FIXTURE` |
| `fzf` | picks the lines containing `FZF_TEST_PICK` | `FZF_TEST_PICK` |
| `probe`, `shadow` | used by `docker.sh` inside a container | |

## Test hooks in the launcher

go-yolo reads a few host locations that a test must replace. These variables do that; they are
for tests only, not documented for users:

| variable | replaces |
|----------|----------|
| `GOYOLO_OS_RELEASE` | `/etc/os-release` |
| `GOYOLO_CA_DIR` | `/usr/local/share/ca-certificates` |
| `GOYOLO_LOCALES_SUPPORTED` | `/usr/share/i18n/SUPPORTED` |
| `GOYOLO_JVM_DIR` | `/usr/lib/jvm` |
