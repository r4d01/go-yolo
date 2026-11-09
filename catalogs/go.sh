# shellcheck shell=bash
# The Go catalog: the host's Go, as the host has it.
#
#   toolchain  GOROOT, copied into the image at the same path (or its apt packages); with it the
#              settings the container needs (GOPATH, GOMODCACHE, GOCACHE, GOENV, ...) and the
#              GOPROXY and GOSUMDB hosts for --net allowlist
#   tools      GOBIN, or the first GOPATH entry's bin/: your `go install`ed tools, owned by you
#   cache      GOMODCACHE (modules) and GOCACHE (build) at the host's paths, in the project's
#              volumes go-mod and go-build (they start empty: the host's caches are never shared)
#   mount      the GOENV file (`go env -w` settings); a go.work outside the repository, and the
#              modules it uses outside the repository (read-only)
#   env        the Go variables set in the host's environment
#
# The host's own GOPATH, module cache and build cache are never read or written. The host's
# settings are read with GOTOOLCHAIN=local: just reading them must not make the host download a
# newer toolchain that a go.mod asks for.

# The Go variables offered from the host's environment.
GO_ENV_NAMES=(GOPROXY GOFLAGS GOPRIVATE GONOPROXY GONOSUMDB GOSUMDB GOINSECURE GOTOOLCHAIN
              GOEXPERIMENT GODEBUG GOOS GOARCH GOAMD64 GOARM GOARM64 GO386 CGO_ENABLED CC CXX
              CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_LDFLAGS PKG_CONFIG PKG_CONFIG_PATH)
declare -A GO_SETTINGS=()

# A hint for the setup picker: a Go project has a go.mod or go.work.
go_detect() { [[ -f go.mod || -f go.work ]]; }

# Read the host's Go settings into GO_SETTINGS (GOROOT, GOVERSION, ...; GOBIN made explicit).
go_settings() {
  local names=(GOROOT GOVERSION GOPATH GOBIN GOMODCACHE GOCACHE GOENV GOWORK GOPROXY GOSUMDB)
  local values=() i
  mapfile -t values < <(GOTOOLCHAIN=local go env "${names[@]}")
  for i in "${!names[@]}"; do GO_SETTINGS[${names[i]}]=${values[i]:-}; done
  # Tools go to GOBIN, or bin/ of the first GOPATH entry, as `go install` would use.
  GO_SETTINGS[tools]=${GO_SETTINGS[GOBIN]:-${GO_SETTINGS[GOPATH]%%:*}/bin}
}

# Candidates for the setup picker (see lib/setup.sh): "mode kind id hint name description".
go_discover() {
  local hint=0 name tools gowork
  command -v go >/dev/null 2>&1 || return 0
  go_settings
  if go_detect; then hint=1; fi
  printf 'image\ttoolchain\t-\t%s\t%s\tGo %s (%s)\n' "$hint" "${GO_SETTINGS[GOROOT]}" "${GO_SETTINGS[GOVERSION]}" "${GO_SETTINGS[GOROOT]}"
  tools=${GO_SETTINGS[tools]}
  if [[ -d $tools ]]; then
    printf 'image\ttools\t-\t%s\t%s\ttools in %s: %s\n' "$hint" "$tools" "$tools" \
      "$(find "$tools" -maxdepth 1 -type f -printf '%f\n' | sort | tr '\n' ' ')"
  fi
  printf 'cache\tcache\tmodules\t%s\t%s\tmodule cache (a project volume at %s)\n' "$hint" "${GO_SETTINGS[GOMODCACHE]}" "${GO_SETTINGS[GOMODCACHE]}"
  if [[ ${GO_SETTINGS[GOCACHE]} != off ]]; then
    printf 'cache\tcache\tbuild\t%s\t%s\tbuild cache (a project volume at %s)\n' "$hint" "${GO_SETTINGS[GOCACHE]}" "${GO_SETTINGS[GOCACHE]}"
  fi
  if [[ -f ${GO_SETTINGS[GOENV]} ]]; then
    printf 'mount\tmount\tgoenv\t%s\t%s\tgo env -w settings: %s (read-only)\n' "$hint" "${GO_SETTINGS[GOENV]}" "${GO_SETTINGS[GOENV]}"
  fi
  gowork=${GO_SETTINGS[GOWORK]}
  if [[ -n $gowork && $gowork != off ]] && ! is_under "$gowork" "$PROJECT_DIR"; then
    printf 'mount\tmount\tgowork\t%s\t%s\t⚠ go.work outside the repository: %s, with the modules it uses (read-only)\n' "$hint" "$gowork" "$gowork"
  fi
  for name in "${GO_ENV_NAMES[@]}"; do
    [[ -n ${!name:-} ]] || continue
    if looks_secret "$name" "${!name}"; then
      printf 'env\tenv\t%s\t0\t%s\t%s (⚠ looks like a secret: its value is never shown)\n' "$name" "$name" "$name"
    else
      printf 'env\tenv\t%s\t%s\t%s\t%s=%s\n' "$name" "$hint" "$name" "$name" "${!name}"
    fi
  done
}

go_resolve() {
  local name gowork
  catalog_picked go || return 0
  if [[ -n ${GOYOLO_GOPATH_MODE+set} ]]; then
    warn "GOYOLO_GOPATH_MODE is no longer used: GOPATH isn't mounted any more (see the go items in the plan)"
  fi
  if ! command -v go >/dev/null 2>&1; then
    warn "Go items are picked, but go isn't on PATH: the container gets no Go either"
    plan_add toolchain go skip go - gone
    return 0
  fi
  go_settings

  if picked go toolchain -; then
    go_plan_toolchain "${GO_SETTINGS[GOROOT]}" "${GO_SETTINGS[GOVERSION]}"
    plan_env go GOPATH "${GO_SETTINGS[GOPATH]}"
    if [[ -n ${GO_SETTINGS[GOBIN]} ]]; then plan_env go GOBIN "${GO_SETTINGS[GOBIN]}"; fi
    plan_env go GOMODCACHE "${GO_SETTINGS[GOMODCACHE]}"
    plan_env go GOCACHE "${GO_SETTINGS[GOCACHE]}"
    plan_env go GOENV "${GO_SETTINGS[GOENV]}"
    go_plan_domains "${GO_SETTINGS[GOPROXY]}" "${GO_SETTINGS[GOSUMDB]}"
  fi
  if picked go tools -; then
    if [[ -d ${GO_SETTINGS[tools]} ]]; then
      plan_copy tools go "${GO_SETTINGS[tools]}" "$(dir_fingerprint "${GO_SETTINGS[tools]}")"
    else
      plan_add tools go skip "${GO_SETTINGS[tools]}" - gone
    fi
  fi
  if picked go cache modules; then plan_cache go "${GO_SETTINGS[GOMODCACHE]}" go-mod; fi
  if picked go cache build && [[ ${GO_SETTINGS[GOCACHE]} != off ]]; then plan_cache go "${GO_SETTINGS[GOCACHE]}" go-build; fi
  if picked go mount goenv; then
    if [[ -f ${GO_SETTINGS[GOENV]} ]]; then plan_mount go "${GO_SETTINGS[GOENV]}"; else plan_add mount go skip goenv - gone; fi
  fi
  gowork=${GO_SETTINGS[GOWORK]}
  if picked go mount gowork; then
    if [[ -n $gowork && $gowork != off ]]; then go_plan_workspace "$gowork"; else plan_add mount go skip go.work - gone; fi
  fi
  while IFS= read -r name; do plan_env go "$name"; done < <(picked_ids go env)
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
