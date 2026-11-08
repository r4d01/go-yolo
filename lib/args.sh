# shellcheck shell=bash
# Command-line options.
#
# Sets: NET REBUILD YOLO USE_TMUX TMUX_FORCED DRY_RUN COLOR YES USER_MOUNTS
#       AGENT            the selected agent (one of AGENTS)
#       PASSTHROUGH_ARGS everything after the agent, passed to it unchanged

usage() {
  cat <<EOF
Usage: go-yolo.sh [launcher-opts] <agent> [agent args...]

agents:  ${AGENTS[*]}
opts:    --net open|allowlist|none   (default: open)
         --rebuild                   force image rebuild
         --yes                       use a new or changed plan without asking (never from env)
         --yolo                      turn off the agent's permission prompts (default: off)
         --no-tmux                   don't run the agent inside tmux (default: tmux on a TTY,
                                     except for non-interactive runs such as claude -p;
                                     prefix c: extra shell)
         --tmux                      always use tmux, even for non-interactive runs
         --mount PATH[:ro|:rw]       also mount PATH at the same path (default: ro; repeatable)
         --color auto|always|never   colored launcher messages (default: auto, honours NO_COLOR)
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
  go-yolo.sh --print-aliases         print alias definitions to stdout
  go-yolo.sh --install-aliases       add the aliases to your shell rc file(s)
  go-yolo.sh --uninstall-aliases     remove them again

Everything after <agent> is passed to the agent unchanged.
EOF
}

NET=open
REBUILD=0
YOLO=0
USE_TMUX=1
TMUX_FORCED=0
DRY_RUN=0
COLOR=auto
YES=0
USER_MOUNTS=()
AGENT=""
PASSTHROUGH_ARGS=()

# parse_args "$@" — set the globals above. Alias commands and --help run here and exit.
parse_args() {
  while (($#)); do
    case $1 in
      --net)
        (($# >= 2)) || die "--net needs a value (open|allowlist|none)"
        NET=$2; shift 2 ;;
      --net=*) NET=${1#*=}; shift ;;
      --rebuild) REBUILD=1; shift ;;
      --yes) YES=1; shift ;;
      --yolo) YOLO=1; shift ;;
      --tmux) USE_TMUX=1; TMUX_FORCED=1; shift ;;
      --no-tmux) USE_TMUX=0; TMUX_FORCED=0; shift ;;
      --mount)
        (($# >= 2)) || die "--mount needs a value (PATH[:ro|:rw])"
        USER_MOUNTS+=("$2"); shift 2 ;;
      --mount=*) USER_MOUNTS+=("${1#*=}"); shift ;;
      --color)
        (($# >= 2)) || die "--color needs a value (auto|always|never)"
        COLOR=$2; shift 2 ;;
      --color=*) COLOR=${1#*=}; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --print-aliases) alias_lines; exit 0 ;;
      --install-aliases) install_aliases; exit 0 ;;
      --uninstall-aliases) uninstall_aliases; exit 0 ;;
      --) shift; break ;;
      -*) usage >&2; die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  ui_set_color "$COLOR"

  case $NET in
    open|allowlist|none) ;;
    *) die "invalid --net value '$NET' (use open, allowlist or none)" ;;
  esac

  if (($# == 0)); then
    usage >&2
    exit 2
  fi
  AGENT=$1
  shift
  if [[ " ${AGENTS[*]} " != *" $AGENT "* ]]; then
    die "unknown agent '$AGENT'; valid agents: ${AGENTS[*]}"
  fi
  PASSTHROUGH_ARGS=("$@")
}
