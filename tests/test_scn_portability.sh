#!/usr/bin/env bash
# tests/test_scn_portability.sh — SHELL PORTABILITY (BSD vs GNU).
#
# This product ships shell that runs on BOTH macOS (BSD coreutils) and Linux
# (GNU). A GNU-only construct (e.g. `sed -i` with no backup arg, `date -d`,
# `readlink -f`, `grep -P`, `mapfile`) fails IDENTICALLY across every install /
# upgrade / uninstall scenario on a BSD host — so one portability slip is a
# fleet-wide blocker, not a one-off. This test pins the invariant: every shipped
# script is syntax-clean AND free of un-gated GNU-only invocations.
#
# Scope = exactly the scripts that actually execute on a user's machine:
#   install.sh, hook-rename.sh, shared/lib/*.sh, and every config/**/*.sh
#   hook/skill that the installer deploys.
#
# Sandboxed by construction: this test only reads repo files and runs `bash -n`
# / `grep`; it never installs, never touches a real ~/.claude* profile.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_portability:"

# ── Collect the shipped scripts ──────────────────────────────────────────────
# Top-level executables + lib + every shell script under config/ (hooks/skills
# that get deployed into the profile). Globbed dynamically so new hooks are
# covered automatically.
SCRIPTS=(
  "$REPO_ROOT/install.sh"
  "$REPO_ROOT/hook-rename.sh"
)
while IFS= read -r f; do SCRIPTS+=("$f"); done < <(find "$REPO_ROOT/shared/lib" -name '*.sh' 2>/dev/null)
while IFS= read -r f; do SCRIPTS+=("$f"); done < <(find "$REPO_ROOT/config" -name '*.sh' 2>/dev/null)

assert_ok "found scripts to audit" test "${#SCRIPTS[@]}" -gt 0

# ── 1. Every shipped script is bash-syntax-clean ─────────────────────────────
# install.sh runs under bash; a syntax error here breaks EVERY scenario.
for s in "${SCRIPTS[@]}"; do
  rel="${s#$REPO_ROOT/}"
  assert_ok "bash -n clean: $rel" bash -n "$s"
done

# ── 2. No un-gated GNU-only INVOCATIONS ──────────────────────────────────────
# We grep for the *command at the head of a pipeline / statement* — not bare
# substrings — so a GNU flag mentioned inside a regex string or comment (e.g. a
# guard pattern that DETECTS `sed -i` in user input) is not a false positive. A
# real invocation begins a command: line start, after | ; & (
# or `$(`. We deliberately do NOT match inside single/double-quoted regex args.
#
# Helper: does FILE contain a real invocation of CMD with the GNU-only flag?
# We check for the construct at a command position, then exclude lines where it
# is clearly a quoted pattern (the construct sits inside a grep -E "...").
gnu_hit() {  # gnu_hit FILE EREGEX  -> prints offending "FILE:LINE:line"
  local file="$1" re="$2"
  /usr/bin/grep -nE "$re" "$file" 2>/dev/null \
    | /usr/bin/grep -vE '^[0-9]+:[[:space:]]*#' \
    | sed "s|^|${file#$REPO_ROOT/}:|"
}

# Each pattern anchors the command at a command position:
#   (^|[|;&(]|\$\()[[:space:]]*  before the command
# --- GNU `sed -i` (BSD requires `sed -i ''`; GNU `sed -i` differs). The repo
#     uses the portable `> tmp && mv` idiom instead, so a real `sed -i`
#     invocation must NOT appear. (Pattern-string mentions are excluded because
#     they are inside a quoted grep regex, never at a command position.)
SED_I='(^|[|;&(]|\$\()[[:space:]]*sed[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-i([[:space:]]|$)'
# --- GNU `date -d` / `date --date` (BSD date has no -d; uses -r / -jf).
DATE_D='(^|[|;&(]|\$\()[[:space:]]*date[[:space:]]+([^|]*[[:space:]])?(-d|--date)([[:space:]]|=)'
# --- GNU `readlink -f` / `-m` / `-e` (BSD readlink has none of these).
READLINK_F='(^|[|;&(]|\$\()[[:space:]]*readlink[[:space:]]+(-[a-zA-Z]*[fme])'
# --- GNU `grep -P` (PCRE; BSD grep has no -P).
GREP_P='(^|[|;&(]|\$\()[[:space:]]*g?n?u?grep[[:space:]]+([^|]*[[:space:]])?-[a-zA-Z]*P([[:space:]]|$)'
# --- GNU `stat -c` (BSD stat uses -f).
STAT_C='(^|[|;&(]|\$\()[[:space:]]*stat[[:space:]]+([^|]*[[:space:]])?-c([[:space:]]|$)'
# --- `mapfile` / `readarray` (bash 4+; macOS ships bash 3.2 — not available).
MAPFILE='(^|[|;&(]|\$\()[[:space:]]*(mapfile|readarray)([[:space:]]|$)'
# --- GNU long-opt `cp --…` / `mv --…` (BSD cp/mv reject GNU long options).
CP_LONG='(^|[|;&(]|\$\()[[:space:]]*(cp|mv)[[:space:]]+([^|]*[[:space:]])?--[a-z]'
# --- bash 4 case-mod expansions ${v^^} / ${v,,} (bash 3.2 on macOS chokes).
CASEMOD='\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)'
# --- GNU `base64 -w` (line-wrap; BSD base64 uses -b).
BASE64_W='(^|[|;&(]|\$\()[[:space:]]*base64[[:space:]]+([^|]*[[:space:]])?-w'

# For each construct, assert NO shipped script contains it. (gnu_hit prints the
# offenders; an empty result = portable.)
check_construct() {  # check_construct LABEL EREGEX [GATE_REGEX]
  # If GATE_REGEX is given, a hit in a file that ALSO matches GATE_REGEX is
  # treated as portable (the construct is explicitly flavor-gated with a BSD
  # fallback — verified separately in section 3). This is how `date -d` /
  # `stat -c` legitimately appear: behind a DATE_FLAVOR/STAT_FLAVOR probe.
  local label="$1" re="$2" gate="${3:-}" hits="" s
  for s in "${SCRIPTS[@]}"; do
    local h; h="$(gnu_hit "$s" "$re")"
    [ -z "$h" ] && continue
    if [ -n "$gate" ] && /usr/bin/grep -qE "$gate" "$s"; then continue; fi
    hits="$hits$h"$'\n'
  done
  if [ -z "$hits" ]; then
    pass "no un-gated GNU-only $label invocation"
  else
    fail "no un-gated GNU-only $label invocation" "found: $(printf '%s' "$hits" | tr '\n' ' ')"
  fi
}

check_construct "sed -i"            "$SED_I"
check_construct "date -d"           "$DATE_D"      'DATE_FLAVOR'
check_construct "readlink -f/-m/-e" "$READLINK_F"
check_construct "grep -P"           "$GREP_P"
check_construct "stat -c"           "$STAT_C"      'STAT_FLAVOR'
check_construct "mapfile/readarray" "$MAPFILE"
check_construct "cp/mv --longopt"   "$CP_LONG"
check_construct "\${v^^}/\${v,,}"   "$CASEMOD"
check_construct "base64 -w"         "$BASE64_W"

# ── 3. Where a GNU-only date/stat IS used, it must be FLAVOR-GATED ────────────
# A general guard, not tied to any one script: if a shipped `.sh` uses `date -d` or
# `stat -c` (GNU-only), it must do so ONLY inside a probed `if [ "$DATE_FLAVOR" = "gnu" ]`
# / STAT_FLAVOR branch with a BSD fallback — otherwise the BSD path is missing and macOS
# scenarios silently produce wrong output. (The statusline once needed this carve-out; it
# is now statusline.ts, which uses Date/Intl and forks no `date`/`stat`, so no shipped
# script currently trips this — the check stays as a tripwire for future hooks.)
for s in "${SCRIPTS[@]}"; do
  rel="${s#$REPO_ROOT/}"
  if /usr/bin/grep -qE 'date[[:space:]]+-d|date[[:space:]]+--date' "$s"; then
    assert_grep "date -d in $rel is flavor-gated (DATE_FLAVOR probe present)" \
      'DATE_FLAVOR' "$s"
    assert_grep "date -d in $rel has a BSD fallback (date -r or -jf)" \
      'date[[:space:]]+(-r|-jf)' "$s"
  fi
  if /usr/bin/grep -qE 'stat[[:space:]]+(-[a-zA-Z]*[[:space:]])?-c([[:space:]]|$)|stat[[:space:]]+-c' "$s"; then
    assert_grep "stat -c in $rel is flavor-gated (STAT_FLAVOR probe present)" \
      'STAT_FLAVOR' "$s"
    assert_grep "stat -c in $rel has a BSD fallback (stat -f)" \
      'stat[[:space:]]+-f' "$s"
  fi
done

# ── 4. The cp idioms the repo relies on are the BSD+GNU-agreeing forms ────────
# common.sh's directory copy must use `cp -R` (both BSD and GNU honor it),
# never the GNU-only `cp -r --` long-opt or `cp -a` semantics it doesn't need.
COMMON="$REPO_ROOT/shared/lib/common.sh"
if [ -f "$COMMON" ]; then
  assert_grep "common.sh copies dirs with portable cp -R" 'cp[[:space:]]+-R' "$COMMON"
fi

t_summary
