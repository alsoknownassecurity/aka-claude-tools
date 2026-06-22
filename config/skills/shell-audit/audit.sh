#!/usr/bin/env bash
# audit.sh — read-only audit of the shell startup source graph.
# ─────────────────────────────────────────────────────────────────────────────
# Walks the rc file and every RESOLVABLE file reachable through its `source`/`.` chain
# (variable-built/unresolvable includes are reported, never silently skipped) (with
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
# fetched). The persistence patterns use `\b` word boundaries, which work on the
# supported matrix (macOS BSD grep + GNU, verified) but not strict-POSIX/BusyBox
# grep — completeness there is reduced. Covers the shell-startup slice only; real
# persistence review must
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

# short: ~-abbreviate a path AND redact it — a secret-shaped value embedded in a
# filename or source-line argument must not leak through a LOCATION print either.
# (redact is a no-op on an ordinary path; defined just below, resolved at call time.)
# Every caller uses it in $(…), which strips the trailing newline redact's sed adds.
short(){ redact "${1/#$HOME/~}"; }

# ── redaction: strip secret VALUES, keep the NAME / shape label ───────────────
# Used by BOTH the credentials section AND the persistence section, so a secret on
# ANY printed line is scrubbed (a flagged `curl -H "Authorization: Bearer …"` would
# otherwise leak). $_red_shape MUST cover every shape in $shape_re below — a
# detected-but-unredacted shape is a value leak; tests/ has a parity self-test that
# fails if the two drift. Handles "double", 'single', and bare values.
_red_name='s/((TOKEN|SECRET|KEY|PASSWORD|PASSWD)[A-Za-z0-9_]*)=("[^"]*"|'\''[^'\'']*'\''|[^[:space:];#&|]*)/\1=<redacted>/Ig'
_red_shape='s/(github_pat_|sk-ant-|sk-[A-Za-z]{2}|sk-|gh[posru]_|AKIA|AIza|xox.|glpat-|eyJ)[A-Za-z0-9._-]+/\1<redacted>/g'
_red_pem='s/-----BEGIN[^-]*PRIVATE KEY-----/<private-key>/'
# Generic carriers a secret can ride even without a known shape or NAME= (common on a
# flagged persistence command): an HTTP bearer token, and url/query secret params.
_red_gen='s/([Bb]earer )[A-Za-z0-9._~+/=-]{6,}/\1<redacted>/g; s/([?&][A-Za-z0-9_]*(api[_-]?key|token|access[_-]?key|access[_-]?token|secret|password)=)[^[:space:]&"'\'']{4,}/\1<redacted>/Ig'
redact(){ printf '%s' "$1" | sed -E "$_red_name" | sed -E "$_red_shape" | sed -E "$_red_pem" | sed -E "$_red_gen"; }

# ── read-only git ─────────────────────────────────────────────────────────────
# Auditing a file INSIDE a repo means running git in that repo's dir, which reads
# its .git/config. A hostile repo can set core.fsmonitor / a hooksPath to an
# arbitrary command that `git status` would EXECUTE — a code-exec vector that breaks
# the read-only guarantee. Neutralize both on the command line (highest precedence,
# overrides repo config) and take no locks so we never write the index.
gitq(){ GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"; }

# ── enumerate the full startup source graph (cycle-safe BFS) ──────────────────
sourced_of(){ # FILE -> TAB records: "OK<TAB>abspath" (resolved) | "NO<TAB>rawline" (unresolved)
  local src="$1" dir f raw
  dir="$(dirname "$src")"
  while IFS= read -r raw; do
    f="${raw%%#*}"; f="${f%"${f##*[![:space:]]}"}"
    # Strip one layer of surrounding quotes: `source "file"` / `. 'file'`.
    case "$f" in
      \"*\") f="${f#\"}"; f="${f%\"}" ;;
      \'*\') f="${f#\'}"; f="${f%\'}" ;;
    esac
    f="${f/#\~/$HOME}"; f="${f//\$HOME/$HOME}"; f="${f//\$\{HOME\}/$HOME}"
    f="${f//\$ZDOTDIR/${ZDOTDIR:-$HOME}}"; f="${f//\$\{ZDOTDIR\}/${ZDOTDIR:-$HOME}}"
    [ -z "$f" ] && continue
    # A still-unexpanded variable ($DOTFILES, $XDG_…) can't be resolved without eval
    # (which we won't do) → report it as UNRESOLVED rather than silently dropping it.
    case "$f" in *'$'*) printf 'NO\t%s\n' "$raw"; continue ;; esac
    # Resolve a RELATIVE include against the including file's dir (not the CWD).
    case "$f" in /*) ;; *) f="$dir/$f" ;; esac
    if [ -f "$f" ]; then printf 'OK\t%s\n' "$f"; else printf 'NO\t%s\n' "$raw"; fi
  done < <(grep -hE '^[[:space:]]*(source|\.)[[:space:]]+' "$src" 2>/dev/null \
           | sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+//')
}
graph=(); queue=("$RC"); seen=" "; gi=0; unresolved=(); un=0
while [ "$gi" -lt "${#queue[@]}" ]; do
  cur="${queue[$gi]}"; gi=$((gi + 1))
  case "$seen" in *" $cur "*) continue ;; esac
  seen="$seen$cur "; graph+=("$cur")
  while IFS=$'\t' read -r kind val; do
    if [ "$kind" = OK ]; then
      case "$seen" in *" $val "*) continue ;; esac
      queue+=("$val")
    elif [ "$kind" = NO ]; then
      unresolved+=("$(short "$cur")	$val"); un=$((un + 1))
    fi
  done < <(sourced_of "$cur")
done

echo "shell-startup audit — ${#graph[@]} file(s) in the source graph of $(short "$RC"):"
for g in "${graph[@]}"; do echo "  • $(short "$g")"; done
if [ "$un" -gt 0 ]; then
  echo "  ⚠ ${un} source line(s) could NOT be resolved — COVERAGE IS PARTIAL"
  echo "    (variable-built or missing includes; these files were NOT audited):"
  for u in "${unresolved[@]}"; do echo "      ${u%%	*}: source $(redact "${u#*	}")"; done
fi

total=0

# ── 1. credentials / secrets ─────────────────────────────────────────────────
echo ""; echo "[1] Credentials / secrets"
# token SHAPES (provider-specific) + secret-NAMED env assignments with a real value
shape_re='(-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9]{20,}|gh[posru]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|glpat-[A-Za-z0-9_-]{18,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})'
# Value may be double-quoted, single-quoted, or bare — quoted is the COMMON form and
# was previously missed (the bare class stops at a quote). $_red_name redacts all
# three in lockstep, so widening detection here never widens what leaks.
name_re='[A-Za-z0-9_]*(TOKEN|SECRET|API_?KEY|ACCESS_KEY|PASSWORD|PASSWD)[A-Za-z0-9_]*=("[^"]{8,}"|'\''[^'\'']{8,}'\''|[^[:space:]"'\'';#&|]{8,})'
# obvious placeholders that are NOT real secrets (incl. a quoted variable reference)
ph_re='=["'\'']?(local|test|dummy|changeme|placeholder|example|xxx+|your[-_a-z]*|<[^>]*>|\$[A-Za-z_{]|""|'\'''\'')'
cn=0
for g in "${graph[@]}"; do
  while IFS=: read -r ln body; do
    [ -z "${ln:-}" ] && continue
    # redact the value (keep the NAME / token-type), then trim + cap width
    red="$(redact "$body" | sed -E 's/^[[:space:]]+//' | cut -c1-72)"
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
# classify_persist BODY -> a short, secret-free category label for a matched line.
# We deliberately do NOT print the matched command body: a persistence line is an
# ARBITRARY command and can carry a secret in any shape (a custom header like
# `X-Api-Key:`, basic-auth in a URL, a `--password` flag) that no redaction list can
# fully enumerate. Reporting location + category keeps the "never print a secret
# VALUE" guarantee absolute for this section; the user opens the file to eyeball.
classify_persist(){
  case "$1" in
    *DYLD_INSERT_LIBRARIES=*|*LD_PRELOAD=*) printf 'dylib/library preload injection' ;;
    */dev/tcp/*) printf 'reverse-shell shape (/dev/tcp)' ;;
    *) if   printf '%s' "$1" | grep -qE '(curl|wget|fetch)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|d|k)?sh\b'; then printf 'pipe-to-shell (download | shell)'
       elif printf '%s' "$1" | grep -qE 'base64[[:space:]]+(-D|-d|--decode)[^|]*\|[[:space:]]*(ba|z)?sh';        then printf 'base64-decode piped to shell'
       elif printf '%s' "$1" | grep -qE 'eval[[:space:]]+"?\$\(';                                                then printf 'eval of command substitution'
       elif printf '%s' "$1" | grep -qE '\bnc\b[^#]*-e\b';                                                       then printf 'netcat -e (reverse shell)'
       elif printf '%s' "$1" | grep -qE '>>?[[:space:]]*~?/?\.?(zshrc|zshenv|zprofile|bashrc|bash_profile|profile)\b'; then printf 'writes into a shell startup file'
       else printf 'suspicious pattern'
       fi ;;
  esac
}
pn=0
for g in "${graph[@]}"; do
  while IFS=: read -r ln body; do
    [ -z "${ln:-}" ] && continue
    echo "  ⚠ $(short "$g"):${ln} — $(classify_persist "$body")  (open the file to inspect)"
    pn=$((pn + 1))
  done < <(grep -nE "$persist_re" "$g" 2>/dev/null)
done
if [ "$pn" = 0 ]; then echo "  none"; else
  echo "  → ${pn} line(s) to eyeball (locations only — the matched command is not printed,"
  echo "    so a secret on it can't leak). Confirm each execs only what you intend."
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
    echo "  ⚠ alias '$(redact "$d")' defined in:"
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
  gitq -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "  • $(short "$g") — not git-tracked (no baseline)"; continue; }
  st="$(gitq -C "$d" status --porcelain -- "$g" 2>/dev/null)"
  if [ -n "$st" ]; then
    echo "  ⚠ $(short "$g") — ${st%% *} (differs from git HEAD / untracked)"
    dn=$((dn + 1))
  else
    echo "  ✓ $(short "$g") — matches git HEAD"
  fi
done
[ "$dn" -gt 0 ] && { echo "  → ${dn} startup file(s) drift from their git baseline — confirm the change is yours."; total=$((total + dn)); }

echo ""
echo "summary: ${total} item(s) to review across ${#graph[@]} startup file(s)$([ "$un" -gt 0 ] && printf ' (+%s UNRESOLVED include(s) — coverage partial)' "$un")."
echo "(detective tripwire — covers shell startup only; not launchd/cron/login-items/ssh/git-hooks.)"
exit 0
