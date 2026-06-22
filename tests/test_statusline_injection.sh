#!/usr/bin/env bash
# test_statusline_injection.sh — statusline.sh builds per-run "fragments" that it
# SOURCES. Values derived from the git ref + the repo dir/remote name (branch, repo)
# and the weather cache MUST be shell-quoted before being written into those sourced
# fragments, or a crafted branch / maliciously-named clone directory injects code on
# render (CWE-78). Regression net for the printf %q fix.
#
# statusline runs its git block in its PROCESS cwd (not the JSON current_dir), so —
# like Claude Code launching it inside the project dir, and like the real attack — we
# run it FROM INSIDE the crafted repo. A successful injection drops a relative marker
# in that cwd.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_statusline_injection:"

SL="$REPO_ROOT/config/hooks/statusline.sh"
SB="$(sandbox)"
export HOME="$SB"          # statusline caches under HOME — keep it sandboxed

sl_input(){ printf '{"workspace":{"current_dir":%s},"model":{"display_name":"Opus"},"session_id":"x"}' \
  "$(printf '%s' "$1" | jq -R .)"; }
# Run statusline FROM inside repo dir $1 (cwd = the repo, as the harness does).
run_in_repo(){ ( cd "$1" && printf '%s' "$(sl_input "$1")" | bash "$SL" ); }

# (1) RCE: a repo directory whose basename breaks out of the raw single-quoted
#     assignment and runs a command must NOT execute on render. (A space is fine inside
#     the SOURCED fragment — only git branch names forbid spaces, not dir names.)
EVIL="$SB/z';touch INJECTED;'"
mkdir -p "$EVIL" && ( cd "$EVIL" && git init -q && git commit -q --allow-empty -m i ) 2>/dev/null
rm -f "$EVIL/INJECTED"
run_in_repo "$EVIL" >/dev/null 2>&1
[ -e "$EVIL/INJECTED" ] \
  && fail "crafted repo dir name does NOT inject code (RCE blocked)" "marker created — injection fired" \
  || pass "crafted repo dir name does NOT inject code (RCE blocked)"

# (2) A LEGITIMATE repo name with an apostrophe (e.g. O'Brien) must render without a
#     fragment source error — the old raw single-quoting broke on this.
OBR="$SB/O'Brien-app"
mkdir -p "$OBR" && ( cd "$OBR" && git init -q && git commit -q --allow-empty -m i ) 2>/dev/null
err="$(run_in_repo "$OBR" 2>&1 >/dev/null)"
case "$err" in
  *git.sh*|*"unexpected EOF"*|*"syntax error"*)
    fail "apostrophe repo name renders without a fragment source error" "got: $err" ;;
  *) pass "apostrophe repo name renders without a fragment source error" ;;
esac
out="$(run_in_repo "$OBR" 2>/dev/null)"
[ -n "$out" ] \
  && pass "statusline still renders a non-empty line on the apostrophe repo" \
  || fail "statusline still renders a non-empty line on the apostrophe repo" "empty output"

t_summary
