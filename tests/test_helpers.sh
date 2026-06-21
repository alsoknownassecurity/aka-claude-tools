#!/usr/bin/env bash
# Unit tests for install.sh's pure helpers. install.sh is SOURCED (its entrypoint
# is source-guarded) inside a SUBSHELL so its top-level `set -euo`/traps/preflight
# stay contained and never corrupt the test shell. No install is performed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_helpers:"

# Run a helper in a sourced subshell. stdin (for the prune helpers) is inherited;
# only the helper's stdout is returned (the source's banner is silenced).
src() { ( source "$REPO_ROOT/install.sh" >/dev/null 2>&1; "$@" ); }
jqe() { printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }   # quiet jq predicate

# ── merge_settings: deep-merge, UNION permission + hook arrays, strip $comment ──
E='{"permissions":{"deny":["Read(~/a)"],"allow":["Bash(x)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"user.sh"}]}]},"model":"opus"}'
A='{"permissions":{"deny":["Read(~/b)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"kit.sh"}]}]},"$comment":["maintainer note"]}'
M="$(src merge_settings "$E" "$A")"

assert_ok "merge output is valid JSON"            jqe "$M" '.'
assert_ok "deny is the UNION of both inputs"      jqe "$M" '.permissions.deny | (index("Read(~/a)")!=null) and (index("Read(~/b)")!=null)'
assert_ok "user allow preserved through merge"    jqe "$M" '.permissions.allow | index("Bash(x)")!=null'
assert_ok "hook arrays unioned (both commands)"   jqe "$M" '[.hooks.PreToolUse[].hooks[].command] | (index("user.sh")!=null) and (index("kit.sh")!=null)'
assert_ok "scalar deep-merge keeps existing key"  jqe "$M" '.model == "opus"'
assert_ok "\$comment stripped from merged result" jqe "$M" 'has("$comment") | not'

# Idempotent union: re-merging the same additions doesn't grow the deny array.
M2="$(src merge_settings "$M" "$A")"
n1="$(printf %s "$M"  | jq '.permissions.deny | length')"
n2="$(printf %s "$M2" | jq '.permissions.deny | length')"
assert_eq "re-merging same additions is idempotent (deny count stable)" "$n1" "$n2"

# ── prune_hook_regs: remove a kit hook by basename, leave the user's own ──────
S='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/p/hooks/leak-guard.sh"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"echo USER"}]}]}}'
P="$(printf %s "$S" | src prune_hook_regs leak-guard.sh)"
assert_ok "prune removed the targeted kit hook"     jqe "$P" '[.hooks.PreToolUse[]?.hooks[].command] | index("/p/hooks/leak-guard.sh") == null'
assert_ok "prune left the user's own hook untouched" jqe "$P" '[.hooks.PreToolUse[]?.hooks[].command] | index("echo USER") != null'

# Pruning the only hook drops the now-empty PreToolUse event entirely.
SONLY='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/p/hooks/leak-guard.sh"}]}]}}'
PONLY="$(printf %s "$SONLY" | src prune_hook_regs leak-guard.sh)"
assert_ok "pruning the last hook removes the empty event" jqe "$PONLY" '(.hooks // {}) == {}'

# ── prune_statusline: drop the kit statusLine, keep an unrelated one ──────────
PL="$(printf %s '{"statusLine":{"command":"/p/hooks/statusline.sh"}}' | src prune_statusline statusline.sh)"
assert_ok "statusLine removed when basename matches" jqe "$PL" 'has("statusLine") | not'
KEEP="$(printf %s '{"statusLine":{"command":"/my/own.sh"}}' | src prune_statusline statusline.sh)"
assert_ok "unrelated statusLine kept" jqe "$KEEP" '.statusLine.command == "/my/own.sh"'

# ── ct_rebuild_rollback: restores a pre-planted backup over a missing target ──
SB="$(sandbox)"
bk="$SB/backup"; tg="$SB/target"
mkdir -p "$bk"; echo SENTINEL > "$bk/keepme"        # backup holds the "real" config
( source "$REPO_ROOT/install.sh" >/dev/null 2>&1
  _CT_REBUILD_BACKUP="$bk"; _CT_REBUILD_TARGET="$tg"; _CT_REBUILD_DONE=0; _CT_ROLLBACK_RAN=0
  ct_rebuild_rollback >/dev/null 2>&1 )
assert_file "interrupted rebuild restores target from backup" "$tg/keepme"
assert_grep "restored content is intact" 'SENTINEL' "$tg/keepme"

# When the rebuild COMPLETED (_CT_REBUILD_DONE=1), rollback is a no-op.
bk2="$SB/backup2"; tg2="$SB/target2"; mkdir -p "$bk2"; echo X > "$bk2/keepme"
( source "$REPO_ROOT/install.sh" >/dev/null 2>&1
  _CT_REBUILD_BACKUP="$bk2"; _CT_REBUILD_TARGET="$tg2"; _CT_REBUILD_DONE=1; _CT_ROLLBACK_RAN=0
  ct_rebuild_rollback >/dev/null 2>&1 )
[ -e "$tg2" ] && fail "completed rebuild is NOT rolled back" "target restored despite DONE=1" \
              || pass "completed rebuild is NOT rolled back"

t_summary
