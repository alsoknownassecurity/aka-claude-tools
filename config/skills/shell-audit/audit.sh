#!/usr/bin/env bash
# audit.sh — read-only audit of the shell startup source graph.
# ─────────────────────────────────────────────────────────────────────────────
# Walks the rc file and EVERY file reachable through its `source`/`.` chain (with
# a visited-set, so cycles terminate), then reports four classes of finding:
#   1. Credentials/secrets hardcoded in startup files (values redacted)
#   2. Persistence-suspicious patterns (pipe-to-shell, eval-of-fetched, DYLD/LD
#      preload, reverse-shell shapes, writes into other startup files)
#   3. Alias hygiene (same name defined more than once; launcher aliases whose
#      target dir is missing)
#   4. Git-baseline drift (graph files modified vs HEAD, or untracked)
#
# Detective control + tripwire — NOT a security boundary. Heuristic: expect some
# false positives (legit eval/curl) and false negatives (obfuscated/runtime-
# fetched). Covers the shell-startup slice only; real persistence review must
# also check launchd/cron/login-items/ssh/git-hooks. Nothing is modified; no
# secret values are printed. Usage: audit.sh [rc-file]   (default: from $SHELL)
set -uo pipefail

RC="${1:-}"
if [ -z "$RC" ]; then
  case "$(basename "${SHELL:-zsh}")" in
    zsh)  RC="${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) [ -f "$HOME/.bashrc" ] && RC="$HOME/.bashrc" || RC="$HOME/.bash_profile" ;;
    *)    RC="$HOME/.profile" ;;
  esac
fi
[ -f "$RC" ] || { echo "shell-audit: no rc file at ${RC}"; exit 0; }

short(){ printf '%s' "${1/#$HOME/~}"; }

# ── enumerate the full startup source graph (cycle-safe BFS) ──────────────────
sourced_of(){ # FILE -> existing files it sources (one hop), paths expanded
  local f
  while IFS= read -r f; do
    f="${f%%#*}"; f="${f%"${f##*[![:space:]]}"}"
    # Strip one layer of surrounding quotes: `source "file"` / `. 'file'`.
    case "$f" in
      \"*\") f="${f#\"}"; f="${f%\"}" ;;
      \'*\') f="${f#\'}"; f="${f%\'}" ;;
    esac
    f="${f/#\~/$HOME}"; f="${f//\$HOME/$HOME}"; f="${f//\$\{HOME\}/$HOME}"
    f="${f//\$ZDOTDIR/${ZDOTDIR:-$HOME}}"; f="${f//\$\{ZDOTDIR\}/${ZDOTDIR:-$HOME}}"
    [ -n "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"
  done < <(grep -hE '^[[:space:]]*(source|\.)[[:space:]]+' "$1" 2>/dev/null \
           | sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+//')
}
graph=(); queue=("$RC"); seen=" "; gi=0
while [ "$gi" -lt "${#queue[@]}" ]; do
  cur="${queue[$gi]}"; gi=$((gi + 1))
  case "$seen" in *" $cur "*) continue ;; esac
  seen="$seen$cur "; graph+=("$cur")
  while IFS= read -r kid; do
    case "$seen" in *" $kid "*) continue ;; esac
    queue+=("$kid")
  done < <(sourced_of "$cur")
done

echo "shell-startup audit — ${#graph[@]} file(s) in the source graph of $(short "$RC"):"
for g in "${graph[@]}"; do echo "  • $(short "$g")"; done

total=0

# ── 1. credentials / secrets ─────────────────────────────────────────────────
echo ""; echo "[1] Credentials / secrets"
# token SHAPES (provider-specific) + secret-NAMED env assignments with a real value
shape_re='(-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9]{20,}|gh[posru]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{18,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})'
name_re='[A-Za-z_][A-Za-z0-9_]*(TOKEN|SECRET|API_?KEY|ACCESS_KEY|PASSWORD|PASSWD)[A-Za-z0-9_]*=[^[:space:]"'\'';#&|]{8,}'
# obvious placeholders that are NOT real secrets
ph_re='=(local|test|dummy|changeme|placeholder|example|xxx+|your[-_a-z]*|<[^>]*>|\$[A-Za-z_{]|""|'\'''\'')'
cn=0
for g in "${graph[@]}"; do
  while IFS=: read -r ln body; do
    [ -z "${ln:-}" ] && continue
    # redact: keep the assignment NAME / token-type, drop the value
    red="$(printf '%s' "$body" \
      | sed -E 's/((TOKEN|SECRET|KEY|PASSWORD|PASSWD)[A-Za-z0-9_]*)=[^[:space:]"'\'']*/\1=<redacted>/Ig' \
      | sed -E 's/(sk-[A-Za-z]{2}|sk-|gh[posru]_|AKIA|AIza|xox.|glpat-|eyJ)[A-Za-z0-9._-]+/\1<redacted>/g' \
      | sed -E 's/-----BEGIN[^-]*PRIVATE KEY-----/<private-key>/' )"
    red="$(printf '%s' "$red" | sed -E 's/^[[:space:]]+//' | cut -c1-72)"
    echo "  ⚠ $(short "$g"):${ln}  ${red}"
    cn=$((cn + 1))
  done < <(grep -nEi "$shape_re|$name_re" "$g" 2>/dev/null | grep -vEi "$ph_re")
done
if [ "$cn" = 0 ]; then echo "  none"; else
  echo "  → ${cn} potential secret(s). Startup files are world-readable to your user and"
  echo "    git-tracked here — move these to a keychain/credential helper and ROTATE if exposed."
  total=$((total + cn))
fi

# ── 2. persistence-suspicious patterns ───────────────────────────────────────
echo ""; echo "[2] Persistence / suspicious patterns"
persist_re='(\b(curl|wget|fetch)\b[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|d|k)?sh\b|eval[[:space:]]+"?\$\(|base64[[:space:]]+(-D|-d|--decode)[^|]*\|[[:space:]]*(ba|z)?sh|DYLD_INSERT_LIBRARIES=|LD_PRELOAD=|/dev/tcp/|\bnc\b[^#]*-e\b|>>?[[:space:]]*~?/?\.?(zshrc|zshenv|zprofile|bashrc|bash_profile|profile)\b)'
pn=0
for g in "${graph[@]}"; do
  while IFS=: read -r ln body; do
    [ -z "${ln:-}" ] && continue
    echo "  ⚠ $(short "$g"):${ln}  $(printf '%s' "$body" | sed -E 's/^[[:space:]]+//' | cut -c1-72)"
    pn=$((pn + 1))
  done < <(grep -nE "$persist_re" "$g" 2>/dev/null)
done
if [ "$pn" = 0 ]; then echo "  none"; else
  echo "  → ${pn} line(s) to eyeball. Most are likely legit (setup scripts) — confirm each"
  echo "    fetches/execs only what you intend, and that nothing writes to another rc."
  total=$((total + pn))
fi

# ── 3. alias hygiene ─────────────────────────────────────────────────────────
echo ""; echo "[3] Alias hygiene"
names="$(for g in "${graph[@]}"; do grep -hoE '^[[:space:]]*alias[[:space:]]+[A-Za-z0-9_-]+=' "$g" 2>/dev/null \
        | sed -E 's/^[[:space:]]*alias[[:space:]]+//; s/=$//'; done)"
dups="$(printf '%s\n' "$names" | sort | uniq -d)"
hn=0
if [ -n "$dups" ]; then
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    echo "  ⚠ alias '${d}' defined in:"
    for g in "${graph[@]}"; do
      grep -nE "^[[:space:]]*alias[[:space:]]+${d}=" "$g" 2>/dev/null \
        | while IFS=: read -r ln _; do echo "      $(short "$g"):${ln}"; done
    done
    hn=$((hn + 1))
  done < <(printf '%s\n' "$dups")
fi
# launcher aliases whose CLAUDE_CONFIG_DIR target is missing
for g in "${graph[@]}"; do
  while IFS= read -r line; do
    t="$(printf '%s' "$line" | sed -n 's/.*CLAUDE_CONFIG_DIR=//p' | sed "s/^[\"']//; s/[\"'].*$//")"
    t="${t/#\~/$HOME}"; t="${t//\$HOME/$HOME}"; t="${t//\$\{HOME\}/$HOME}"
    # skip targets that are still an unresolved shell variable (e.g. $CC_FLEET_DIR)
    case "$t" in *'$'*) continue ;; esac
    [ -n "$t" ] && [ ! -d "$t" ] && { echo "  ⚠ alias targets a missing dir: $(short "$t")  (in $(short "$g"))"; hn=$((hn + 1)); }
  done < <(grep -hE '^[[:space:]]*alias[[:space:]]+[A-Za-z0-9_-]+=.*CLAUDE_CONFIG_DIR=' "$g" 2>/dev/null)
done
if [ "$hn" = 0 ]; then echo "  no duplicate or dangling aliases"; else total=$((total + hn)); fi

# ── 4. git-baseline drift ────────────────────────────────────────────────────
echo ""; echo "[4] Git-baseline drift"
dn=0
for g in "${graph[@]}"; do
  d="$(dirname "$g")"
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "  • $(short "$g") — not git-tracked (no baseline)"; continue; }
  st="$(git -C "$d" status --porcelain -- "$g" 2>/dev/null)"
  if [ -n "$st" ]; then
    echo "  ⚠ $(short "$g") — ${st%% *} (differs from git HEAD / untracked)"
    dn=$((dn + 1))
  else
    echo "  ✓ $(short "$g") — matches git HEAD"
  fi
done
[ "$dn" -gt 0 ] && { echo "  → ${dn} startup file(s) drift from their git baseline — confirm the change is yours."; total=$((total + dn)); }

echo ""
echo "summary: ${total} item(s) to review across ${#graph[@]} startup file(s)."
echo "(detective tripwire — covers shell startup only; not launchd/cron/login-items/ssh/git-hooks.)"
exit 0
