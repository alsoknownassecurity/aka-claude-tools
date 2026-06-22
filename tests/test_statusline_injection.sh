#!/usr/bin/env bash
# test_statusline_injection.sh — statusline.sh builds per-run "fragments" that it
# SOURCES. Values derived from the git ref + the repo dir/remote name (branch, repo)
# and the weather cache MUST be shell-quoted before being written into those sourced
# fragments, or a crafted branch / maliciously-named clone directory injects code on
# render (CWE-78). Regression net for the printf %q fix. This net directly exercises
# the two attacker-reachable sinks — the repo-dir basename and the git branch name —
# from inside a crafted repo; the weather/usage fragments are quoted by the same
# printf %q construct (verified by the fix), not re-exercised here.
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
out="$(run_in_repo "$EVIL" 2>/dev/null)"; rc=$?
if [ -e "$EVIL/INJECTED" ]; then
  fail "crafted repo dir name does NOT inject code (RCE blocked)" "marker created — injection fired"
elif [ "$rc" -ne 0 ] || [ -z "$out" ]; then
  # A clean exit + a rendered line proves statusline ran THROUGH the sourced fragment;
  # without this, an early abort before the sink would make marker-absence a false pass.
  fail "crafted repo dir name does NOT inject code (RCE blocked)" "statusline did not render the sink (rc=$rc, empty=$([ -z "$out" ] && echo yes || echo no)) — marker-absence would be a false pass"
else
  pass "crafted repo dir name does NOT inject code (RCE blocked)"
fi

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

# (3) RCE via a crafted BRANCH name. The branch flows into the same SOURCED git
#     fragment (branch='...') as the repo name. git refnames FORBID spaces but ALLOW '
#     and ; — so the payload uses a space-free redirection (>BR_INJECTED), not `touch`,
#     to break out of the single-quoted assignment. (Verified: this exact name fires on
#     the pre-fix code, so the test has teeth.)
BRH="$SB/branch-host"
EVIL_BR="x';>BR_INJECTED;'y"
# Inline git identity so the commit succeeds on ANY host: CI redirects HOME to the
# sandbox (no git identity), and without this the commit fails, the branch stays unborn,
# and HEAD reads back as 'HEAD' — making the test vacuously "pass". checkout -b then
# creates the payload branch.
mkdir -p "$BRH" && ( cd "$BRH" && git init -q \
  && git -c user.email=t@t.test -c user.name=test commit -q --allow-empty -m i \
  && git checkout -q -b "$EVIL_BR" ) 2>/dev/null
# Anti-vacuous guard: if git ever rejects the payload (or the commit failed) HEAD won't
# be the payload branch, and the no-injection check would pass for the WRONG reason.
got_br="$(cd "$BRH" && git symbolic-ref --short -q HEAD 2>/dev/null || true)"
if [ "$got_br" != "$EVIL_BR" ]; then
  fail "crafted branch name does NOT inject code (RCE blocked)" "test setup vacuous: branch is '${got_br:-<unborn/detached>}', not the payload"
else
  rm -f "$BRH/BR_INJECTED"
  out="$(run_in_repo "$BRH" 2>/dev/null)"; rc=$?
  if [ -e "$BRH/BR_INJECTED" ]; then
    fail "crafted branch name does NOT inject code (RCE blocked)" "marker created — injection fired"
  elif [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    fail "crafted branch name does NOT inject code (RCE blocked)" "statusline did not render the sink (rc=$rc) — marker-absence would be a false pass"
  else
    pass "crafted branch name does NOT inject code (RCE blocked)"
  fi
fi

t_summary
