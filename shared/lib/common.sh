#!/usr/bin/env bash
# common.sh — shared helpers for the aka-claude-tools installer. Sourced, not run.

# ── output ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_BLU=$'\033[34m'; C_RED=$'\033[31m'; C_RST=$'\033[0m'
else
  C_BOLD=''; C_DIM=''; C_GRN=''; C_YLW=''; C_BLU=''; C_RED=''; C_RST=''
fi
say()  { printf '%s\n' "$*"; }
# interactive-only say: suppressed under CT_NONINTERACTIVE (menus/headers are
# noise when every prompt auto-takes its default).
isay() { [ "${CT_NONINTERACTIVE:-0}" = "1" ] && return 0; say "$@"; }
info() { printf '%s%s%s\n' "$C_BLU" "$*" "$C_RST"; }
ok()   { printf '%s✓ %s%s\n' "$C_GRN" "$*" "$C_RST"; }
warn() { printf '%s! %s%s\n' "$C_YLW" "$*" "$C_RST" >&2; }
die()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RST" >&2; exit 1; }
hr()   { printf '%s────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RST"; }

# ── prompts (honor CT_NONINTERACTIVE=1 to take all defaults) ──────────────────
# prompt VAR "Question" "default"
prompt() {
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  if [ "${CT_NONINTERACTIVE:-0}" = "1" ]; then printf -v "$__var" '%s' "$__def"; return; fi
  if [ -n "$__def" ]; then printf '%s %s[%s]%s ' "$__q" "$C_DIM" "$__def" "$C_RST" >&2
  else printf '%s ' "$__q" >&2; fi
  read -r __ans </dev/tty || __ans=""
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# confirm "Question" "Y|N"  → returns 0 for yes, 1 for no. Second arg = default.
confirm() {
  local __q="$1" __def="${2:-N}" __ans=""
  if [ "${CT_NONINTERACTIVE:-0}" = "1" ]; then [ "$__def" = "Y" ]; return; fi
  local __hint="[y/N]"; [ "$__def" = "Y" ] && __hint="[Y/n]"
  printf '%s %s%s%s ' "$__q" "$C_DIM" "$__hint" "$C_RST" >&2
  read -r __ans </dev/tty || __ans=""
  __ans="${__ans:-$__def}"
  [[ "$__ans" =~ ^[Yy] ]]
}

# parse_selection "<input>" <max> → echoes unique, sorted, in-range indices,
# space-separated. Accepts: "all"/"a", space- or comma-separated numbers, and
# ranges like "1-3". Out-of-range and junk tokens are ignored. Empty → nothing.
parse_selection() {
  local input="${1//,/ }" max="$2" out=() tok i
  case "$input" in
    all|a|ALL|A) for ((i=1;i<=max;i++)); do out+=("$i"); done ;;
    *) for tok in $input; do
         if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
           for ((i=BASH_REMATCH[1];i<=BASH_REMATCH[2];i++)); do
             [ "$i" -ge 1 ] && [ "$i" -le "$max" ] && out+=("$i")
           done
         elif [[ "$tok" =~ ^[0-9]+$ ]]; then
           [ "$tok" -ge 1 ] && [ "$tok" -le "$max" ] && out+=("$tok")
         fi
       done ;;
  esac
  [ ${#out[@]} -eq 0 ] && return 0
  printf '%s\n' "${out[@]}" | sort -n -u | tr '\n' ' ' | sed 's/ $//'
}

# is_selected <id> <space-padded-list>  → 0 if " <id> " appears in the list.
# Used to drive the build step from the addition ids the user picked, so the
# menu's single source of truth stays config/additions.json.
is_selected() { case "$2" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# place_file <src> <dst-dir> [+x]
# Copy a payload file into a profile dir WITHOUT writing through an inherited
# symlink at the destination. If migration copied a symlinked hook/command into
# the profile, a bare `cp` onto that path would follow the link and clobber the
# link's TARGET (a file OUTSIDE the profile, e.g. ~/docs/shared/hooks/...). The
# rm -f first guarantees we replace the link itself with a real file. Pass "+x"
# as the third arg to also mark the result executable.
place_file() {
  local src="$1" dst
  dst="$2/$(basename "$1")"
  rm -f "$dst"
  cp "$src" "$dst"
  [ "${3:-}" = "+x" ] && chmod +x "$dst" || true
}

# ── session/history migration (opt-in) ───────────────────────────────────────
# Runtime/personal state a user means by "my history": conversation transcripts,
# REPL input history, and session/todo state. Migrated ONLY when the user opts in
# at the migrate prompt — it's personal and can be large. Deliberately EXCLUDES
# anything that can capture a secret: .credentials.json (auth), shell-snapshots/ &
# session-env/ (shell/env dumps that may hold exported tokens), paste-cache/
# (pasted text), file-history/ (snapshots of edited files, which may be a .env),
# and telemetry/. Those stay behind even when session history is migrated.
CT_SESSION_ITEMS="history.jsonl projects sessions todos tasks"

# migrate_sessions <src> <dst> — copy the opt-in session items that exist in src
# into dst, MERGING into existing dirs (union — a fresh profile has little/none,
# and an explicit opt-in means the user wants src's history brought over).
migrate_sessions() {
  local src="$1" dst="$2" item n=0 copied=()
  for item in $CT_SESSION_ITEMS; do
    [ -e "$src/$item" ] || continue
    if [ -d "$src/$item" ]; then
      mkdir -p "$dst/$item"
      # Copy the dir CONTENTS (src/item/.) so existing items in dst are merged,
      # not replaced wholesale. -R recursive; BSD and GNU cp agree on this form.
      cp -R "$src/$item/." "$dst/$item/" 2>/dev/null && { copied+=("$item/"); n=$((n+1)); }
    else
      cp "$src/$item" "$dst/$item" 2>/dev/null && { copied+=("$item"); n=$((n+1)); }
    fi
  done
  if [ "$n" -gt 0 ]; then ok "Migrated session history (${copied[*]}) — secrets, shell/env & paste caches left behind"
  else say "  ${C_DIM}no session history found to migrate${C_RST}"; fi
}

# place_dir <src-dir> <dst-parent> — directory analogue of place_file (skills).
# Replaces the destination so re-installs never leave stale files behind.
place_dir() {
  local src="$1" dst
  dst="$2/$(basename "$1")"
  mkdir -p "$2"
  rm -rf "$dst"
  cp -RL "$src" "$dst"
}

# ── dependency install ───────────────────────────────────────────────────────
# Best install command for a tool given the available package managers, or "".
# bun is intentionally NOT offered via `curl … | bash` (our own command-guard
# blocks pipe-to-shell on principle) — brew/npm only, else manual.
pm_install_cmd() {
  local tool="$1"
  case "$tool" in
    jq|trufflehog)
      if   command -v brew    >/dev/null 2>&1; then echo "brew install $tool"
      elif command -v apt-get >/dev/null 2>&1 && [ "$tool" = jq ]; then echo "sudo apt-get update && sudo apt-get install -y jq"
      elif command -v dnf     >/dev/null 2>&1 && [ "$tool" = jq ]; then echo "sudo dnf install -y jq"
      elif command -v pacman  >/dev/null 2>&1 && [ "$tool" = jq ]; then echo "sudo pacman -S --noconfirm jq"
      fi ;;
    bun)
      if   command -v brew >/dev/null 2>&1; then echo "brew install oven-sh/bun/bun"
      elif command -v npm  >/dev/null 2>&1; then echo "npm install -g bun"
      fi ;;
    rtk)
      # `cargo install rtk` is the WRONG crate — rtk must come from its repo.
      if   command -v brew  >/dev/null 2>&1; then echo "brew install rtk"
      elif command -v cargo >/dev/null 2>&1; then echo "cargo install --git https://github.com/rtk-ai/rtk"
      else echo "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh"
      fi ;;
  esac
}

# Offer to install Homebrew when no package manager is available — it's the
# universal one (covers jq/bun/trufflehog/rtk). Returns 0 if brew is present or
# was installed. Skipped non-interactively (the official installer needs a TTY
# for its sudo/RETURN prompts). curl|bash is the *only* official brew installer,
# runs in the user's own shell (not a CC hook), and only with explicit consent.
ensure_brew() {
  command -v brew >/dev/null 2>&1 && return 0
  [ "${CT_NONINTERACTIVE:-0}" = "1" ] && return 1
  confirm "  • No package manager found. Install Homebrew now (official installer, brew.sh)?" "Y" || return 1
  info "installing Homebrew (you may be prompted for your password)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && break
  done
  command -v brew >/dev/null 2>&1 && { ok "Homebrew installed."; return 0; }
  warn "Homebrew didn't complete — see https://brew.sh"; return 1
}

# ensure_dep <tool> <label> <required:0|1>
# If <tool> is missing, offer to install it via the detected package manager
# (offering to install Homebrew first if there's no package manager at all).
# Returns 0 if present/installed, 1 otherwise. Dies if required.
# Non-interactive runs NEVER install anything: install commands may need sudo
# (would hang with no TTY) or run a vendor installer script — both require a
# human consenting at a prompt. We warn (or die, if required) instead.
ensure_dep() {
  local tool="$1" label="${2:-$1}" required="${3:-0}" cmd
  command -v "$tool" >/dev/null 2>&1 && return 0
  cmd="$(pm_install_cmd "$tool")"
  if [ "${CT_NONINTERACTIVE:-0}" = "1" ]; then
    if [ "$required" = "1" ]; then
      die "${label} not found. Install it first${cmd:+ (e.g.: ${cmd})}, then re-run."
    fi
    warn "${label} not found — skipping install in non-interactive mode${cmd:+ (install manually: ${cmd})}."
    return 1
  fi
  # No package manager can install this tool → offer to bootstrap Homebrew, retry.
  if [ -z "$cmd" ] && ensure_brew; then cmd="$(pm_install_cmd "$tool")"; fi
  if [ -n "$cmd" ]; then
    if confirm "  • ${label} not found — install via: ${cmd} ?" "Y"; then
      info "installing ${tool}…"
      if eval "$cmd" && command -v "$tool" >/dev/null 2>&1; then ok "${tool} installed."; return 0; fi
      warn "${tool} install failed — install it manually: ${cmd}"
    fi
  elif [ "$tool" = bun ]; then
    warn "${label} not found and no brew/npm — install bun manually: https://bun.sh/install"
  elif [ "$tool" = jq ]; then
    warn "${label} not found and no supported package manager — install jq manually: https://jqlang.github.io/jq/download/"
  else
    warn "${label} not found and no supported package manager — install it manually."
  fi
  [ "$required" = "1" ] && die "${tool} is required. Aborting."
  return 1
}

# ── shell rc detection ────────────────────────────────────────────────────────
# Echoes the path to the interactive-shell rc file for the user's login shell.
detect_shell_rc() {
  local sh; sh="$(basename "${SHELL:-/bin/bash}")"
  case "$sh" in
    zsh)  printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [ -f "$HOME/.bashrc" ]; then printf '%s\n' "$HOME/.bashrc"; else printf '%s\n' "$HOME/.bash_profile"; fi ;;
    *)    printf '%s\n' "$HOME/.profile" ;;
  esac
}

# ── idempotent managed-block writer ──────────────────────────────────────────
# write_managed_block FILE ID CONTENT
# Inserts/replaces a block delimited by markers keyed on ID. Re-running with the
# same ID replaces the prior block instead of appending a duplicate.
write_managed_block() {
  local file="$1" id="$2" content="$3"
  local begin="# >>> aka-claude-tools managed: ${id} >>>"
  local end="# <<< aka-claude-tools managed: ${id} <<<"
  touch "$file"
  local tmp; tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '
    $0==b {skip=1} $0==e {skip=0; next} skip!=1 {print}
  ' "$file" > "$tmp"
  printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$tmp"
  mv "$tmp" "$file"
}

# remove_managed_block FILE ID — delete our marker-delimited block if present.
# Returns 0 if it removed one, 1 if there was none. Used to drop a now-redundant
# alias block when the same alias is already provided elsewhere.
remove_managed_block() {
  local file="$1" id="$2"
  local begin="# >>> aka-claude-tools managed: ${id} >>>"
  local end="# <<< aka-claude-tools managed: ${id} <<<"
  [ -f "$file" ] || return 1
  grep -qF "$begin" "$file" || return 1
  local tmp; tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '$0==b {skip=1} $0==e {skip=0; next} skip!=1 {print}' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# sourced_paths FILE — print the existing files FILE `source`s / `.`-includes
# (one hop), with ~ / $HOME / $ZDOTDIR expanded. Best-effort, no eval; relative
# or var-built paths that don't expand here are skipped.
sourced_paths() {
  local src="$1" f
  [ -f "$src" ] || return 0
  while IFS= read -r f; do
    f="${f%%#*}"; f="${f%"${f##*[![:space:]]}"}"
    f="${f/#\~/$HOME}"; f="${f//\$HOME/$HOME}"; f="${f//\$\{HOME\}/$HOME}"
    f="${f//\$ZDOTDIR/${ZDOTDIR:-$HOME}}"; f="${f//\$\{ZDOTDIR\}/${ZDOTDIR:-$HOME}}"
    [ -n "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"
  done < <(grep -hE '^[[:space:]]*(source|\.)[[:space:]]+' "$src" 2>/dev/null | sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+//')
}

# alias_target_elsewhere NAME RC — if alias NAME is already defined OUTSIDE our
# own managed block — in RC or ANY file reachable through its `source` chain
# (fully recursive) — print the CLAUDE_CONFIG_DIR it resolves to (expanded), or
# "OTHER" if it's an alias of that name that isn't a Claude-config launcher.
# Empty = not defined in that scope. Lets the installer avoid duplicating or
# shadowing an alias the user already has (e.g. one a fleet-wide aliases file
# provides). Walks the WHOLE source graph with a visited-set, so a source cycle
# (A sources B sources A, or self-source) can't loop and each file is scanned
# once — cost is O(distinct files), a handful in any real rc.
alias_target_elsewhere() {
  local name="$1" rc="$2"
  [ -f "$rc" ] || return 0
  local begin="# >>> aka-claude-tools managed: ${name} >>>"
  local end="# <<< aka-claude-tools managed: ${name} <<<"
  local stripped; stripped="$(mktemp)"
  # RC with our own block removed, so we only see OTHER definitions.
  awk -v b="$begin" -v e="$end" '$0==b {skip=1} $0==e {skip=0; next} skip!=1 {print}' "$rc" > "$stripped"
  # Breadth-first over the source graph. queue = files to expand; seen = files
  # already expanded (cycle/repeat guard, space-delimited); files = what to grep
  # (rc represented by its stripped copy). Index walk — no array slicing, so it's
  # safe under set -u on old bash.
  local files=("$stripped") queue=("$rc") seen=" " cur kid i=0
  while [ "$i" -lt "${#queue[@]}" ]; do
    cur="${queue[$i]}"; i=$((i + 1))
    case "$seen" in *" $cur "*) continue ;; esac
    seen="$seen$cur "
    while IFS= read -r kid; do
      case "$seen" in *" $kid "*) continue ;; esac
      files+=("$kid"); queue+=("$kid")
    done < <(sourced_paths "$cur")
  done
  local def; def="$(grep -hE "^[[:space:]]*alias[[:space:]]+${name}=" "${files[@]}" 2>/dev/null | tail -1)"
  rm -f "$stripped"
  [ -z "$def" ] && return 0
  local t; t="$(printf '%s\n' "$def" | sed -n 's/.*CLAUDE_CONFIG_DIR=//p' | sed "s/^[\"']//; s/[\"'].*$//")"
  if [ -z "$t" ]; then printf 'OTHER\n'; return 0; fi
  t="${t/#\~/$HOME}"; t="${t//\$HOME/$HOME}"; t="${t//\$\{HOME\}/$HOME}"
  printf '%s\n' "$t"
}
