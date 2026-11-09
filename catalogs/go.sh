# shellcheck shell=bash
# The Go catalog: the host's Go, as the host has it.
#
#   toolchain  GOROOT: the go.dev release (checked against go.dev's SHA-256 and the host's bin/go
#              and VERSION), or its apt packages, or a copy (a Go built from source); with it the
#              settings the container needs (GOPATH, GOMODCACHE, GOCACHE, GOENV, ...) and the
#              GOPROXY and GOSUMDB hosts for --net allowlist
#   tool       each of your `go install`ed tools in GOBIN (or the first GOPATH entry's bin/):
#              built again with `go install path@version` at the host's paths and checked
#              against the host's binary; copied when that can't give the same binary (built
#              from local sources, with another Go, with -ldflags, from a private module)
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
declare -A GO_SETTINGS=() GO_TOOL=()

# A hint for the setup picker: a Go project has a go.mod or go.work.
go_detect() { [[ -f go.mod || -f go.work ]]; }

# Read the host's Go settings into GO_SETTINGS (GOROOT, GOVERSION, ...; GOBIN made explicit).
go_settings() {
  local names=(GOROOT GOVERSION GOPATH GOBIN GOMODCACHE GOCACHE GOENV GOWORK GOPROXY GOSUMDB GOPRIVATE
               GONOPROXY GOHOSTOS GOHOSTARCH)
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
  printf 'image\ttoolchain\t-\t%s\t%s\tGo %s (%s) · %s\n' "$hint" "${GO_SETTINGS[GOROOT]}" "${GO_SETTINGS[GOVERSION]}" \
    "${GO_SETTINGS[GOROOT]}" "$(go_toolchain_how "${GO_SETTINGS[GOROOT]}" "${GO_SETTINGS[GOVERSION]}")"
  tools=${GO_SETTINGS[tools]}
  if picked go tools -; then
    printf 'image\ttools\t-\t1\t%s\tevery tool in %s (an older pick: pick single tools instead)\n' "$tools" "$tools"
  fi
  while IFS= read -r name; do
    go_tool_info "$tools/$name"
    printf 'image\ttool\t%s\t%s\t%s\ttool %s%s (%s) · %s\n' "$name" "$hint" "$tools/$name" "$name" \
      "${GO_TOOL[version]:+ ${GO_TOOL[version]}}" "$tools/$name" "$(go_tool_how)"
  done < <(find "$tools" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
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
    go_plan_toolchain "${GO_SETTINGS[GOROOT]}" "${GO_SETTINGS[GOVERSION]}" "$(picked_mode go toolchain -)"
    plan_env go GOPATH "${GO_SETTINGS[GOPATH]}"
    if [[ -n ${GO_SETTINGS[GOBIN]} ]]; then plan_env go GOBIN "${GO_SETTINGS[GOBIN]}"; fi
    plan_env go GOMODCACHE "${GO_SETTINGS[GOMODCACHE]}"
    plan_env go GOCACHE "${GO_SETTINGS[GOCACHE]}"
    plan_env go GOENV "${GO_SETTINGS[GOENV]}"
    go_plan_domains "${GO_SETTINGS[GOPROXY]}" "${GO_SETTINGS[GOSUMDB]}"
  fi
  if picked go tools -; then   # an older pick: every tool in GOBIN
    while IFS= read -r name; do
      go_plan_tool "${GO_SETTINGS[tools]}/$name" image
    done < <(find "${GO_SETTINGS[tools]}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
  fi
  while IFS= read -r name; do
    go_plan_tool "${GO_SETTINGS[tools]}/$name" "$(picked_mode go tool "$name")"
  done < <(picked_ids go tool)
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

# go_plan_toolchain GOROOT VERSION MODE — the toolchain: from apt if GOROOT belongs to apt packages
# (e.g. /usr/lib/go-1.24), else the go.dev release, else (or with MODE copy) a copy.
go_plan_toolchain() {
  local goroot=$1 version=$2 mode=$3 owners url
  if [[ $mode == copy ]]; then
    plan_copy toolchain go "$goroot" "$version" on-path,copy-picked
  elif owners="$(apt_owners "$goroot")"; then
    # shellcheck disable=SC2086 # one word per package
    plan_packages go $owners
    plan_add toolchain go apt "$goroot" "$version" on-path
  elif go_is_release "$goroot" "$version"; then
    url="https://dl.google.com/go/$version.${GO_SETTINGS[GOHOSTOS]}-${GO_SETTINGS[GOHOSTARCH]}.tar.gz"
    plan_download toolchain go "$goroot" "$version" on-path "$url" sha256 "$url.sha256" bin/go VERSION
  else
    plan_copy toolchain go "$goroot" "$version" on-path,no-recipe
  fi
}

# go_is_release GOROOT VERSION — true if GOROOT looks like an unpacked go.dev release: a release
# version (go1.27.0, go1.28rc1), also in GOROOT/VERSION. A Go built from source says "devel".
go_is_release() {
  [[ $2 =~ ^go[0-9]+(\.[0-9]+)*((rc|beta)[0-9]+)?$ && -f $1/bin/go ]] || return 1
  [[ $(head -n 1 -- "$1/VERSION" 2>/dev/null) == "$2" ]]
}

# go_toolchain_how GOROOT VERSION — how the picker says the toolchain gets into the image.
go_toolchain_how() {
  if apt_owners "$1" >/dev/null; then printf 'install: apt'
  elif go_is_release "$1" "$2"; then printf 'install: go.dev release (sha256)'
  else printf 'copy: not a go.dev release'
  fi
}

# go_plan_tool FILE MODE — a tool in GOBIN: built again with go install, or (with MODE copy, or
# when go install can't give the same binary) copied.
go_plan_tool() {
  local file=$1 mode=$2 reason
  if [[ ! -f $file ]]; then plan_add tool go skip "$file" - gone; return 0; fi
  go_tool_info "$file"
  reason=${GO_TOOL[reason]}
  if [[ $mode == copy ]]; then
    reason=copy-picked
  elif [[ -z $reason ]] && ! plan_has toolchain "$(realpath -m -- "${GO_SETTINGS[GOROOT]}")"; then
    reason=no-go
  fi
  if [[ -n $reason ]]; then
    plan_copy_file tool go "$file" "$reason"
  else
    plan_build tool go "$file" "${GO_TOOL[path]}@${GO_TOOL[version]}" "$(go_tool_command)"
  fi
}

# go_tool_info FILE — read what `go version -m` says about a Go binary into GO_TOOL: go (the Go
# that built it), path, version, flags and env (the build settings to repeat), reason (a copy
# reason when go install can't repeat the build, else empty). For example:
#
#   /home/me/go/bin/gopls: go1.27.0
#   <TAB>path<TAB>golang.org/x/tools/gopls
#   <TAB>mod<TAB>golang.org/x/tools/gopls<TAB>v0.23.0<TAB>h1:Dn6m...
#   <TAB>build<TAB>-buildmode=exe
#   <TAB>build<TAB>CGO_ENABLED=1
go_tool_info() {
  local file=$1 output line key value rest name
  GO_TOOL=([go]="" [path]="" [version]="" [flags]="" [env]="" [reason]="")
  if ! output="$(GOTOOLCHAIN=local go version -m "$file" 2>/dev/null)" || [[ -z $output ]]; then
    GO_TOOL[reason]=not-go-binary
    return 0
  fi
  GO_TOOL[go]=${output%%$'\n'*}
  GO_TOOL[go]=${GO_TOOL[go]##*: }
  while IFS=$'\t' read -r key value rest; do
    case $key in
      path) GO_TOOL[path]=$value ;;
      mod) GO_TOOL[version]=${rest%%$'\t'*} ;;
      '=>') go_tool_reason local-build ;;   # a replaced module: built in a checkout
      build) go_tool_setting "$value" ;;
    esac
  done < <(tail -n +2 <<<"$output")

  name=${GO_TOOL[path]##*/}
  # A major version suffix isn't the command's name: example.com/cmd/foo/v2 installs foo.
  if [[ $name =~ ^v[0-9]+$ && ${GO_TOOL[path]} == */*/* ]]; then name=${GO_TOOL[path]%/*}; name=${name##*/}; fi
  if [[ -z ${GO_TOOL[path]} || -z ${GO_TOOL[version]} || ${GO_TOOL[version]} == '(devel)' ]]; then
    go_tool_reason local-build
  elif [[ ${GO_TOOL[go]} != "${GO_SETTINGS[GOVERSION]}" ]]; then
    go_tool_reason "other-go=${GO_TOOL[go]}"
  elif go_is_private "${GO_TOOL[path]}"; then
    go_tool_reason private-module
  elif [[ $name != "${file##*/}" ]]; then
    go_tool_reason renamed
  fi
}

# go_tool_reason FLAG — set GO_TOOL's copy reason, unless it has one already.
go_tool_reason() { if [[ -z ${GO_TOOL[reason]} ]]; then GO_TOOL[reason]=$1; fi; }

# go_tool_setting SETTING — one "build" line of go version -m: repeat it, or give a reason.
go_tool_setting() {
  local setting=$1
  if [[ $setting == *[\"\ ]* ]]; then go_tool_reason custom-build; return 0; fi  # quoted values
  case $setting in
    -buildmode=exe|-compiler=gc|DefaultGODEBUG=*) ;;
    -trimpath=true) GO_TOOL[flags]+=" -trimpath" ;;
    -tags=*) GO_TOOL[flags]+=" $setting" ;;
    vcs=*|vcs.*) go_tool_reason local-build ;;
    CGO_ENABLED=*|CGO_CFLAGS=*|CGO_CPPFLAGS=*|CGO_CXXFLAGS=*|CGO_LDFLAGS=*|GOOS=*|GOARCH=*|GOEXPERIMENT=*|\
    GO386=*|GOAMD64=*|GOARM=*|GOARM64=*|GOMIPS=*|GOMIPS64=*|GOPPC64=*|GORISCV64=*|GOWASM=*)
      GO_TOOL[env]+=" $setting" ;;
    *) go_tool_reason custom-build ;;   # -ldflags, -gcflags, -race, -pgo, ...
  esac
}

# go_is_private PATH — true if module PATH matches GOPRIVATE or GONOPROXY: the build can't fetch
# it without credentials. A pattern matches a prefix of the path's elements, as in Go.
go_is_private() {
  local path=$1 pattern prefix patterns=() elements
  IFS=, read -r -a patterns <<<"${GO_SETTINGS[GOPRIVATE]},${GO_SETTINGS[GONOPROXY]}"
  for pattern in "${patterns[@]}"; do
    [[ -n $pattern ]] || continue
    elements=${pattern//[^\/]/}
    prefix="$(cut -d/ -f "1-$((${#elements} + 1))" <<<"$path")"
    # shellcheck disable=SC2053 # the pattern is a glob
    if [[ $prefix == $pattern ]]; then return 0; fi
  done
  return 1
}

# go_tool_how — how the picker says the tool in GO_TOOL gets into the image.
go_tool_how() {
  local reason=${GO_TOOL[reason]}
  if [[ -z $reason ]]; then printf 'install: go install …@%s' "${GO_TOOL[version]}"; return 0; fi
  printf 'copy: %s' "$(flag_note "$reason" - | sed 's/^copied from the host: //')"
}

# go_tool_command — the build stage's command for the tool in GO_TOOL: go install at the host's
# version, Go, paths (they end up in the binary) and build settings, into "$OUT".
go_tool_command() {
  local words=(env GOTOOLCHAIN=local GOENV=off GOFLAGS= "GOPATH=${GO_SETTINGS[GOPATH]}"
               "GOMODCACHE=${GO_SETTINGS[GOMODCACHE]}" GOCACHE=/tmp/go-yolo-build/go-build)
  local env=() flags=() name
  for name in GOPROXY GOSUMDB; do
    if [[ -n ${GO_SETTINGS[$name]} ]]; then words+=("$name=${GO_SETTINGS[$name]}"); fi
  done
  read -r -a env <<<"${GO_TOOL[env]}"
  read -r -a flags <<<"${GO_TOOL[flags]}"
  words+=("${env[@]}" "${GO_SETTINGS[GOROOT]}/bin/go" install "${flags[@]}" "${GO_TOOL[path]}@${GO_TOOL[version]}")
  # shellcheck disable=SC2016 # $OUT is the build stage's, not ours
  printf 'GOBIN="$OUT" %s' "$(shell_words "${words[@]}")"
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
