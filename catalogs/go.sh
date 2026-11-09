# shellcheck shell=bash
# The Go catalog, for projects with a go.mod or go.work: the host's Go, as the host has it.
#
#   toolchain  GOROOT, copied into the image at the same path (or its apt packages)
#   tools      GOBIN, or the first GOPATH entry's bin/: your `go install`ed tools, owned by you
#   package    the apt packages behind the project's `#cgo pkg-config:` names, and pkg-config
#   mount      the GOENV file (`go env -w` settings); a go.work outside the repository, and the
#              modules it uses outside the repository (read-only)
#   cache      GOMODCACHE and GOCACHE at the host's paths, in the project's volumes go-mod and
#              go-build (they start empty: the host's own caches are never shared)
#   env        GOPATH, GOBIN, GOMODCACHE, GOCACHE and GOENV as the host has them; the Go
#              variables set in the host's environment
#   domain     the GOPROXY and GOSUMDB hosts, for --net allowlist
#
# The host's own GOPATH, module cache and build cache are never read or written. The host's settings
# are read with GOTOOLCHAIN=local: just reading them must not make the host download a newer
# toolchain that a go.mod asks for.

go_detect() { [[ -f go.mod || -f go.work ]]; }

go_resolve() {
  local values goroot version gopath gobin gomodcache gocache goenv gowork goproxy gosumdb name
  if [[ -n ${GOYOLO_GOPATH_MODE+set} ]]; then
    warn "GOYOLO_GOPATH_MODE is no longer used: GOPATH isn't mounted any more (see the go items in the plan)"
  fi
  if ! command -v go >/dev/null 2>&1; then
    warn "this project uses Go, but go isn't on PATH: the container gets no Go either"
    return 0
  fi

  mapfile -t values < <(GOTOOLCHAIN=local go env GOROOT GOVERSION GOPATH GOBIN GOMODCACHE GOCACHE \
                          GOENV GOWORK GOPROXY GOSUMDB)
  goroot=${values[0]} version=${values[1]} gopath=${values[2]} gobin=${values[3]}
  gomodcache=${values[4]} gocache=${values[5]} goenv=${values[6]} gowork=${values[7]}
  goproxy=${values[8]} gosumdb=${values[9]}

  go_plan_toolchain "$goroot" "$version"
  # Tools: GOBIN, or bin/ of the first GOPATH entry, as `go install` would use.
  if [[ -z $gobin ]]; then gobin="${gopath%%:*}/bin"; fi
  if [[ -d $gobin ]]; then plan_copy tools go "$gobin" "$(dir_fingerprint "$gobin")"; fi
  go_plan_cgo_packages

  if [[ -f $goenv ]]; then plan_mount go "$goenv"; fi
  if [[ -n $gowork && $gowork != off ]]; then go_plan_workspace "$gowork"; fi

  plan_cache go "$gomodcache" go-mod
  if [[ $gocache != off ]]; then plan_cache go "$gocache" go-build; fi

  plan_env go GOPATH "$gopath"
  if [[ -n ${values[3]} ]]; then plan_env go GOBIN "$gobin"; fi
  plan_env go GOMODCACHE "$gomodcache"
  plan_env go GOCACHE "$gocache"
  plan_env go GOENV "$goenv"
  for name in GOPROXY GOFLAGS GOPRIVATE GONOPROXY GONOSUMDB GOSUMDB GOINSECURE GOTOOLCHAIN GOEXPERIMENT \
              GODEBUG GOOS GOARCH GOAMD64 GOARM GOARM64 GO386 CGO_ENABLED CC CXX \
              CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_LDFLAGS PKG_CONFIG PKG_CONFIG_PATH; do
    plan_env go "$name"
  done

  go_plan_domains "$goproxy" "$gosumdb"
}

# The toolchain: from apt if GOROOT belongs to apt packages (e.g. /usr/lib/go-1.24), else a copy.
go_plan_toolchain() {
  local goroot=$1 version=$2 owners
  if owners="$(apt_owners "$goroot")"; then
    # shellcheck disable=SC2086 # one word per package
    plan_packages go $owners
    plan_add toolchain go apt "$goroot" "$version" on-path
  else
    plan_copy toolchain go "$goroot" "$version" on-path
  fi
}

# The apt packages that provide the project's `#cgo pkg-config: NAME` libraries (the package
# that owns NAME.pc on the host), plus pkg-config itself. Without pkg-config on the host the
# host can't build such code either, so nothing is added.
go_plan_cgo_packages() {
  local names=() name dir packages=() owner
  command -v pkg-config >/dev/null 2>&1 || return 0
  # Lines like "// #cgo pkg-config: sqlite3 libpng" or "#cgo linux pkg-config: --static foo".
  mapfile -t names < <(grep -rhoE --include='*.go' --exclude-dir=.git --exclude-dir=.go-yolo \
                         '^[[:space:]]*(//[[:space:]]*)?#cgo( [^:]*)? pkg-config:.*' . 2>/dev/null \
                       | sed 's/^.*pkg-config: *//' | tr ' ' '\n' | grep -v -e '^-' -e '^$' | sort -u)
  ((${#names[@]})) || return 0

  for name in "${names[@]}"; do
    for dir in $(pkg-config --variable pc_path pkg-config | tr : ' '); do
      [[ -f $dir/$name.pc ]] || continue
      if owner="$(dpkg -S -- "$dir/$name.pc" 2>/dev/null)"; then packages+=("${owner%%: *}"); fi
      break
    done
  done
  if owner="$(dpkg -S -- "$(readlink -f "$(command -v pkg-config)")" 2>/dev/null)"; then
    packages+=("${owner%%: *}")
  fi
  # shellcheck disable=SC2046 # one word per package name
  plan_packages go $(printf '%s\n' "${packages[@]}" | sort -u)
}

# A go.work outside the repository (e.g. ~/src/go.work) puts the host into workspace mode:
# mount it, and the modules it uses that are outside the repository, read-only.
go_plan_workspace() {
  local gowork=$1 use dir
  if ! is_under "$gowork" "$PROJECT_DIR"; then plan_mount go "$gowork" outside-repo; fi
  # `go work edit -json` prints e.g. "Use": [ { "DiskPath": "../shared" } ].
  while IFS= read -r use; do
    if [[ $use == /* ]]; then dir=$use; else dir="${gowork%/*}/$use"; fi
    dir="$(realpath -m -- "$dir")"
    if ! is_under "$dir" "$PROJECT_DIR" && [[ -d $dir ]]; then plan_mount go "$dir" outside-repo; fi
  done < <(GOTOOLCHAIN=local go work edit -json "$gowork" 2>/dev/null \
             | sed -n 's/.*"DiskPath": *"\(.*\)".*/\1/p')
}

# Allow the GOPROXY hosts (not "direct", "off" or file:// entries) and the GOSUMDB host.
go_plan_domains() {
  local goproxy=$1 gosumdb=$2 entry host
  for entry in ${goproxy//[,|]/ }; do
    case $entry in direct|off|file://*) continue ;; esac
    host=${entry#*://}
    host=${host%%/*}
    plan_domain go "${host%%:*}"
    # proxy.golang.org serves module zips from storage.googleapis.com.
    if [[ $host == proxy.golang.org ]]; then plan_domain go storage.googleapis.com; fi
  done
  # GOSUMDB is "name", "name+key" or "name+key url"; the default name is sum.golang.org.
  if [[ $gosumdb != off ]]; then
    host=${gosumdb%%[+ ]*}
    plan_domain go "${host:-sum.golang.org}"
  fi
}

# --parity probe (see lib/parity.sh): Go's version, settings and tools.
go_probe() {
  local names=(GOROOT GOPATH GOBIN GOMODCACHE GOCACHE GOENV GOWORK GOPROXY GOFLAGS GOPRIVATE GONOSUMDB
               GOSUMDB GOINSECURE GOEXPERIMENT GOOS GOARCH GOAMD64 CGO_ENABLED CC CXX)
  local values=() i gobin
  if ! command -v go >/dev/null 2>&1; then
    printf 'go\t(missing)\n'
    return 0
  fi
  printf 'go version\t%s\n' "$(GOTOOLCHAIN=local go version)"
  mapfile -t values < <(GOTOOLCHAIN=local go env "${names[@]}")
  for i in "${!names[@]}"; do
    printf 'go env %s\t%s\n' "${names[i]}" "${values[i]}"
  done
  gobin=${values[2]:-${values[1]%%:*}/bin}
  printf 'go tools\t%s\n' "$(find "$gobin" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')"
}
