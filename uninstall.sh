#!/usr/bin/env bash
# uninstall.sh — one-shot teardown for an aka-claude-tools profile. Removes the
# isolated config dir AND every shell-rc alias block the kit wrote for it.
#
# The rc blocks are matched MARKER + DIR, not by alias name: any block delimited
# by our `# >>> aka-claude-tools managed: … >>>` markers whose body points
# CLAUDE_CONFIG_DIR at THIS profile is removed — whatever the alias was called.
# Blocks for other profiles, and anything outside our markers, are never touched.
#
# Usage:  ./uninstall.sh [CONFIG_DIR] [--yes]
#         CONFIG_DIR  the profile dir to remove. Defaults to ~/.claude-aka.
#         --yes (-y)  skip the confirmation prompt (for scripted teardown).
#
# SAFETY — env isolation. This is a destructive `rm -rf`, so unlike install.sh it
# NEVER reads the ambient $CLAUDE_CONFIG_DIR as the target (that env var leaking
# into a subprocess is how a profile gets wiped by accident). Two guards:
#   • $CLAUDE_CONFIG_DIR is used only as a TRIPWIRE — if the resolved target is
#     the profile THIS process is running inside, we refuse outright. Uninstall a
#     profile from a plain shell or a different profile, not from within itself.
#   • The default ~/.claude is the real Claude Code config; removing it always
#     requires an interactive confirmation that --yes does NOT bypass.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/lib/common.sh
source "$REPO_DIR/shared/lib/common.sh"

ASSUME_YES=0
CFG=""
for arg in "$@"; do
  case "$arg" in
    --yes|-y)   ASSUME_YES=1 ;;
    -*)         die "unknown flag: $arg" ;;
    *)          [ -z "$CFG" ] && CFG="$arg" || die "unexpected extra argument: $arg" ;;
  esac
done
# Default target is a FIXED path, never $CLAUDE_CONFIG_DIR — see the SAFETY note.
CFG="${CFG:-$HOME/.claude-aka}"
CFG="${CFG/#\~/$HOME}"
CFG="${CFG%/}"                                  # normalize: drop any trailing slash

case "$CFG" in
  ""|"/"|"$HOME") die "refusing to operate on '${CFG:-<empty>}'." ;;
esac

disp() { printf '%s' "${1/#$HOME/~}"; }
norm() { local p="${1/#\~/$HOME}"; printf '%s' "${p%/}"; }   # expand ~, strip trailing /

# Tripwire: never delete the profile this very session is running inside. The
# ambient $CLAUDE_CONFIG_DIR is consulted ONLY here, and only to REFUSE.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$(norm "$CLAUDE_CONFIG_DIR")" = "$CFG" ]; then
  die "refusing to remove $(disp "$CFG") — it is the profile THIS session is running inside (\$CLAUDE_CONFIG_DIR). Run uninstall from a plain shell or a different profile."
fi

# ── rc files that might carry our blocks ──────────────────────────────────────
# The login shell's standard rc files plus any files they `source` (one hop) — a
# block can live in a fleet-wide aliases file the rc sources. Existing files only,
# de-duplicated. Index-built so it is safe under `set -u` on bash 3.2.
rc_candidates() {
  local out=() seen=" " c kid n i
  for c in "$(detect_shell_rc)" "$HOME/.zshrc" "${ZDOTDIR:-$HOME}/.zshrc" \
           "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -f "$c" ] || continue
    case "$seen" in *" $c "*) ;; *) out+=("$c"); seen="$seen$c " ;; esac
  done
  n=${#out[@]}
  for ((i = 0; i < n; i++)); do                # one hop of source-includes
    while IFS= read -r kid; do
      case "$seen" in *" $kid "*) continue ;; esac
      out+=("$kid"); seen="$seen$kid "
    done < <(sourced_paths "${out[$i]}")
  done
  [ ${#out[@]} -gt 0 ] && printf '%s\n' "${out[@]}"
}

# prune_blocks FILE — remove every managed block whose body points
# CLAUDE_CONFIG_DIR at $CFG. Echoes the number removed; rewrites FILE only if it
# removed at least one. Name-independent: keys off the marker + the embedded dir.
prune_blocks() {
  local file="$1"
  [ -f "$file" ] || { echo 0; return 0; }
  local tmp cnt; tmp="$(mktemp)"; cnt="$(mktemp)"
  awk -v cfg="$CFG" -v cntfile="$cnt" '
    /^# >>> aka-claude-tools managed: .* >>>$/ { inblk=1; buf=$0 ORS; hit=0; next }
    inblk && /^# <<< aka-claude-tools managed: .* <<<$/ {
      buf=buf $0 ORS
      if (hit) dropped++; else printf "%s", buf
      inblk=0; buf=""; next
    }
    inblk {
      buf=buf $0 ORS
      if (index($0, "CLAUDE_CONFIG_DIR=\"" cfg "\"")) hit=1
      next
    }
    { print }
    END { if (inblk) printf "%s", buf; print dropped+0 > cntfile }
  ' "$file" > "$tmp"
  local n; n="$(cat "$cnt")"; rm -f "$cnt"
  if [ "${n:-0}" -gt 0 ]; then mv "$tmp" "$file"; else rm -f "$tmp"; fi
  echo "${n:-0}"
}

say ""
printf '%s%s aka-claude-tools uninstaller %s\n' "$C_BOLD" "$C_BLU" "$C_RST"

# The default ~/.claude footgun guard — always interactive, never --yes-able.
if [ "$CFG" = "$HOME/.claude" ]; then
  warn "$(disp "$CFG") is your DEFAULT Claude Code config — the installer never aliases it."
  confirm "  Really remove your default ~/.claude profile?" "N" || die "Aborted — nothing changed."
fi

rcs=()
while IFS= read -r r; do [ -n "$r" ] && rcs+=("$r"); done < <(rc_candidates)

say "  Profile : $(disp "$CFG")$( [ -d "$CFG" ] && printf '' || printf '  (already gone)')"
say "  RC scan : ${#rcs[@]} file(s) for managed alias blocks"
if [ "$ASSUME_YES" != 1 ]; then
  confirm "Remove this profile and its managed alias block(s)?" "N" || die "Aborted — nothing changed."
fi

removed=0
if [ ${#rcs[@]} -gt 0 ]; then
  for r in "${rcs[@]}"; do
    n="$(prune_blocks "$r")"
    if [ "$n" -gt 0 ]; then ok "Removed $n managed alias block(s) from $(disp "$r")"; removed=$((removed + n)); fi
  done
fi
[ "$removed" = 0 ] && say "  ${C_DIM}No managed alias blocks pointed at this profile.${C_RST}"

if [ -d "$CFG" ]; then
  rm -rf "$CFG"
  ok "Removed profile dir $(disp "$CFG")"
else
  say "  ${C_DIM}Profile dir already gone — nothing to delete.${C_RST}"
fi

say ""
ok "Uninstalled. Open a new shell (or re-source your rc) to drop the alias from the current session."
