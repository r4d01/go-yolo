# shellcheck shell=bash
# Shell aliases (gy-claude, gy-codex, ...): --print-aliases, --install-aliases, --uninstall-aliases.

ALIAS_BEGIN='# >>> go-yolo aliases >>>'
ALIAS_END='# <<< go-yolo aliases <<<'

# One alias line per agent, using the launcher's absolute path.
alias_lines() {
  local agent value
  for agent in "${AGENTS[@]}"; do
    value="$(printf '%q' "$SELF") $agent"
    printf "alias gy-%s='%s'\n" "$agent" "${value//\'/\'\\\'\'}"
  done
}

# The rc files to manage: ~/.bashrc always, ~/.zshrc if it exists.
rc_files() {
  printf '%s\n' "$HOME/.bashrc"
  if [[ -f $HOME/.zshrc ]]; then printf '%s\n' "$HOME/.zshrc"; fi
}

# Print the file without the go-yolo alias block.
strip_alias_block() {
  awk -v b="$ALIAS_BEGIN" -v e="$ALIAS_END" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip' "$1"
}

# Overwrite in place, keeping the inode (rc files are often symlinks into a dotfiles repo).
replace_contents() {
  local file=$1 tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

install_aliases() {
  local file files
  mapfile -t files < <(rc_files)
  for file in "${files[@]}"; do
    if [[ -e $file ]]; then
      # On a re-install keep the existing backup: it predates the go-yolo block.
      if [[ ! -e $file.go-yolo.bak ]] || ! grep -qxF "$ALIAS_BEGIN" "$file"; then
        cp -p -- "$file" "$file.go-yolo.bak"
      fi
    else
      : >"$file"
    fi
    {
      strip_alias_block "$file"
      printf '%s\n' "$ALIAS_BEGIN"
      alias_lines
      printf '%s\n' "$ALIAS_END"
    } | replace_contents "$file"
    note "updated $file (backup: $file.go-yolo.bak)"
  done
  note "open a new shell or run: source ${files[0]}"
}

uninstall_aliases() {
  local file files changed=0
  mapfile -t files < <(rc_files)
  for file in "${files[@]}"; do
    if [[ ! -f $file ]] || ! grep -qxF "$ALIAS_BEGIN" "$file"; then continue; fi
    strip_alias_block "$file" | replace_contents "$file"
    note "removed go-yolo aliases from $file"
    changed=1
  done
  if ((changed)); then
    note "open a new shell for the change to take effect (or: unalias gy-claude gy-codex gy-vibe gy-opencode gy-shell)"
  else
    note "no go-yolo aliases found"
  fi
}
