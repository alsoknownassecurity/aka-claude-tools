#!/usr/bin/env bash
# test_statusline_injection.sh — the statusline is now config/hooks/statusline.ts (bun),
# a behaviour-preserving port of the old statusline.sh. The original RCE class the .sh
# version defended against — values derived from the git ref / repo dir / weather cache
# being SOURCED as shell fragments (CWE-78), guarded with printf %q — NO LONGER EXISTS:
# the .ts version uses typed JSON.parse + argv-array subprocesses and never `source`s or
# `eval`s anything. This test is repurposed as the regression net that PROVES that: feed
# the port crafted branch / dir / session_name values full of shell metacharacters and
# assert (a) it exits 0, (b) the crafted value still renders, (c) NO sentinel side-effect
# file is created (nothing was evaluated). If a future edit reintroduces a shell eval, the
# sentinel fires and this fails.
#
# The port runs its git subprocesses with cwd = the JSON current_dir (explicit, no longer
# the implicit process cwd), so we point current_dir at the crafted repo/dir directly.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_statusline_injection:"

SL="$REPO_ROOT/config/hooks/statusline.ts"
SB="$(sandbox)"
export HOME="$SB" TMPDIR="$SB"          # cache dir derives from HOME/TMPDIR — keep sandboxed
unset CLAUDE_CONFIG_DIR XDG_RUNTIME_DIR
CFG="$SB/cfg"; mkdir -p "$CFG"
export CLAUDE_CONFIG_DIR="$CFG"
# Pre-seed a fresh PINNED location cache with NO lat/lon so the render fires no network
# (pinned → no IP lookup; no coords → no weather fetch). Keeps the test offline + fast.
KEY="$(printf '%s' "$CFG" | tr -c 'A-Za-z0-9' '_')"
CACHE="$SB/aka-claude-tools-${USER:-anon}"; mkdir -p "$CACHE"; chmod 700 "$CACHE"
printf '%s\n' '{"country_code":"US","region_code":"NY","city":"NYC","success":true,"pinned":true}' > "$CACHE/location-$KEY.json"

# Normal-width render (shows dir/branch on the card + session on the ambient line). Native
# rate_limits supplied so the usage segment needs no network either.
sl_input(){ # $1 = current_dir, $2 = session_name
  jq -cn --arg d "$1" --arg s "$2" \
    '{workspace:{current_dir:$d},model:{id:"claude-opus-4-8"},context_window:{used_percentage:5},
      session_name:$s, rate_limits:{five_hour:{used_percentage:1},seven_day:{used_percentage:1}}}'
}
run_sl(){ # $1 = current_dir, $2 = session_name ; runs FROM the sandbox so a stray sentinel lands here
  ( cd "$SB" && printf '%s' "$(sl_input "$1" "$2")" | COLUMNS=120 bun "$SL" ); }

# ── (1) crafted DIRECTORY name (non-git) — basename flows into the rendered card ──
EVIL_DIR="$SB/proj\$(touch DIR_INJECTED)';touch DIR_INJECTED;'"
mkdir -p "$EVIL_DIR"
rm -f "$SB/DIR_INJECTED"
out="$(run_sl "$EVIL_DIR" "" 2>/dev/null)"; rc=$?
if [ -e "$SB/DIR_INJECTED" ]; then
  fail "crafted dir name does NOT inject (no shell eval)" "sentinel created — injection fired"
elif [ "$rc" -ne 0 ] || [ -z "$out" ]; then
  fail "crafted dir name does NOT inject (no shell eval)" "statusline did not render (rc=$rc, empty=$([ -z "$out" ] && echo yes || echo no))"
else
  pass "crafted dir name does NOT inject (no shell eval)"
fi
# The crafted basename still renders verbatim (it is text, not code).
case "$out" in
  *"touch DIR_INJECTED"*) pass "crafted dir basename is rendered as text" ;;
  *) fail "crafted dir basename is rendered as text" "not found in output" ;;
esac

# ── (2) crafted BRANCH name — git refnames forbid spaces but ALLOW ' ; > ─────────
# The payload uses a space-free redirection (>BR_INJECTED), not `touch X` (a space is an
# invalid refname char), so the branch is creatable AND would write the sentinel if eval'd.
BRH="$SB/branch-host"; mkdir -p "$BRH"
EVIL_BR="x';>BR_INJECTED;'y"
( cd "$BRH" && git init -q \
  && git -c user.email=t@t.test -c user.name=test commit -q --allow-empty -m i \
  && git checkout -q -b "$EVIL_BR" ) 2>/dev/null
got_br="$(cd "$BRH" && git symbolic-ref --short -q HEAD 2>/dev/null || true)"
if [ "$got_br" != "$EVIL_BR" ]; then
  fail "crafted branch name does NOT inject (no shell eval)" "test setup vacuous: branch is '${got_br:-<unborn>}'"
else
  rm -f "$SB/BR_INJECTED"
  out="$(run_sl "$BRH" "" 2>/dev/null)"; rc=$?
  if [ -e "$SB/BR_INJECTED" ]; then
    fail "crafted branch name does NOT inject (no shell eval)" "sentinel created — injection fired"
  elif [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    fail "crafted branch name does NOT inject (no shell eval)" "statusline did not render (rc=$rc)"
  else
    pass "crafted branch name does NOT inject (no shell eval)"
  fi
  case "$out" in
    *">BR_INJECTED"*) pass "crafted branch name is rendered as text" ;;
    *) fail "crafted branch name is rendered as text" "not found in output" ;;
  esac
fi

# ── (3) crafted SESSION name — flows from JSON straight into the ambient line ─────
rm -f "$SB/SESS_INJECTED"
EVIL_SESS="s\$(touch SESS_INJECTED);touch SESS_INJECTED"
out="$(run_sl "$SB" "$EVIL_SESS" 2>/dev/null)"; rc=$?
if [ -e "$SB/SESS_INJECTED" ]; then
  fail "crafted session_name does NOT inject (no shell eval)" "sentinel created — injection fired"
elif [ "$rc" -ne 0 ] || [ -z "$out" ]; then
  fail "crafted session_name does NOT inject (no shell eval)" "statusline did not render (rc=$rc)"
else
  pass "crafted session_name does NOT inject (no shell eval)"
fi
# Session is uppercased in the render; assert the uppercased crafted text appears.
case "$out" in
  *"TOUCH SESS_INJECTED"*) pass "crafted session_name is rendered as (uppercased) text" ;;
  *) fail "crafted session_name is rendered as (uppercased) text" "not found in output" ;;
esac

t_summary
