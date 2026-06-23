#!/usr/bin/env bash
# Upgrade migration: leak-guard.sh → leak-guard.ts (the in-kit .sh→.ts port). A profile that
# already has the managed-marked bash hook `leak-guard.sh` registered is re-run with the
# CURRENT manifest (which ships leak-guard.ts). This pins that the marker-based self-clean
# (install.sh 4d-pre2) migrates a renamed PreToolUse hook cleanly — the path the generic
# manifest/deselect pruners do NOT cover, since a `.sh` command is not full-command-equal to
# the new `.ts` command.
#
# It also pins the SUBSUMED matcher-broadening case: the pre-port reg carries the OLD
# pre-SearXNG matcher "WebSearch|WebFetch". Because the marker self-clean prunes the old
# leak-guard.sh reg by BASENAME (matcher-agnostic), the stale narrow-matcher reg is removed
# and the merge re-adds a single reg under the CURRENT broadened matcher — no double-fire,
# no coverage loss — without any AKA_SUPERSEDED_MATCHERS entry (that entry is now empty;
# the file rename subsumes it).
#
# Invariants pinned:
#   (a) the old leak-guard.sh hook FILE is removed (no orphaned payload),
#   (b) the old leak-guard.sh REGISTRATION is pruned (no stale/double registration),
#   (c) exactly one leak-guard.ts registration exists, launched via bun (absolute path),
#       under the CURRENT broadened web-egress matcher,
#   (d) an unrelated user-owned hook + its registration are left untouched.
#
# Fully sandboxed: fake $HOME, --no-auth-inherit; never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_leakguard_ts:"

# leak-guard.ts is a bun hook; the install gate aborts selection without bun. Skip cleanly
# on a bun-less leg (the missing-deps scenario covers the abort path explicitly).
if ! command -v bun >/dev/null 2>&1; then
  pass "skipped (bun absent — leak-guard.ts upgrade path needs bun)"
  t_summary; exit 0
fi

SB="$(sandbox)"
RC="$SB/.bashrc"; touch "$RC"
PROFILE="$SB/.claude-aka"; mkdir -p "$PROFILE/hooks"

run() { CT_ADDITIONS="$1" SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# ── (0) seed a PRE-PORT profile: managed-marked leak-guard.sh registered on the OLD
#        pre-SearXNG matcher, plus an unrelated user-owned web hook we expect to survive ──
printf '#!/bin/bash\n# aka-claude-tools:managed-hook — installer-owned.\nexit 0\n' > "$PROFILE/hooks/leak-guard.sh"
chmod +x "$PROFILE/hooks/leak-guard.sh"
printf '#!/bin/bash\n# my own thing\nexit 0\n' > "$PROFILE/hooks/my-own.sh"   # unmarked = user's
chmod +x "$PROFILE/hooks/my-own.sh"
cat > "$PROFILE/settings.json" <<JSON
{ "hooks": { "PreToolUse": [
  { "matcher": "WebSearch|WebFetch", "hooks": [ { "type": "command", "command": "$PROFILE/hooks/leak-guard.sh" } ] },
  { "matcher": "WebFetch", "hooks": [ { "type": "command", "command": "$PROFILE/hooks/my-own.sh" } ] }
] } }
JSON

# ── (1) upgrade: re-run install with the current manifest, selecting leak-guard ─────
run "secure-settings leak-guard"; rc=$?
assert_eq "upgrade install exits 0" "0" "$rc"

# (a) old .sh file removed; (new) .ts placed
[ -e "$PROFILE/hooks/leak-guard.sh" ] && fail "old leak-guard.sh file removed" "still present" || pass "old leak-guard.sh file removed"
assert_file "leak-guard.ts placed" "$PROFILE/hooks/leak-guard.ts"

S="$PROFILE/settings.json"
assert_ok "settings.json valid JSON after upgrade" jq -e . "$S"

# (b) old .sh registration pruned; (c) exactly one .ts reg, via bun, under the current matcher
sh_regs="$(jq '[.hooks.PreToolUse[].hooks[].command | select(type=="string" and contains("leak-guard.sh"))] | length' "$S")"
ts_regs="$(jq '[.hooks.PreToolUse[].hooks[].command | select(type=="string" and contains("leak-guard.ts"))] | length' "$S")"
bun_ts="$(jq '[.hooks.PreToolUse[].hooks[].command | select(type=="string" and test("bun.*leak-guard\\.ts"))] | length' "$S")"
assert_eq "no stale leak-guard.sh registration" "0" "$sh_regs"
assert_eq "exactly one leak-guard.ts registration" "1" "$ts_regs"
assert_eq "leak-guard.ts registered via bun" "1" "$bun_ts"
# the surviving reg carries the CURRENT broadened web-egress matcher (incl. SearXNG), not the
# stale narrow "WebSearch|WebFetch" — no double-fire, no coverage loss.
lg_matcher="$(jq -r '[.hooks.PreToolUse[] | select(.hooks[].command | type=="string" and test("leak-guard\\.ts")) | .matcher][0]' "$S")"
assert_eq "surviving leak-guard reg uses the current broadened matcher" \
  "WebSearch|WebFetch|mcp__searxng__" "$lg_matcher"
assert_nlit "the stale bare WebSearch|WebFetch leak-guard group is gone" \
  '"matcher":"WebSearch|WebFetch","hooks"' "$S"

# (d) unrelated user hook + registration untouched
assert_file "user hook my-own.sh kept" "$PROFILE/hooks/my-own.sh"
assert_lit  "user my-own.sh registration kept" "$PROFILE/hooks/my-own.sh" "$S"

# (e) idempotent: a second upgrade keeps exactly one .ts reg
run "secure-settings leak-guard"; rc=$?
assert_eq "second upgrade exits 0" "0" "$rc"
ts_regs2="$(jq '[.hooks.PreToolUse[].hooks[].command | select(type=="string" and contains("leak-guard.ts"))] | length' "$S")"
assert_eq "still exactly one leak-guard.ts registration (idempotent)" "1" "$ts_regs2"

t_summary
