#!/usr/bin/env bash
# Upgrade / add-option (T17) — a profile with a CLEAN install of one subset is
# re-run with a PREVIOUSLY-UNSELECTED addition added to the selection. This is the
# "I want one more tool" upgrade path, distinct from a fresh install (test_install),
# an exact deselect (test_uninstall), or a pure idempotent re-run (test_idempotency).
#
# Invariants pinned:
#   (a) the newly-selected additions' files are deployed (path-remapped),
#   (b) the new hook is registered in settings (union add — no duplicate regs),
#   (c) the PREVIOUSLY-selected additions are untouched: their files survive
#       byte-identical and their settings registrations remain,
#   (d) the user's own (non-kit) permission rule planted before the upgrade survives.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit; never touches a
# real ~/.claude*. Selection is driven non-interactively via CT_ADDITIONS, exactly
# as the sibling select/uninstall/smoke tests do (the menu reads /dev/tty).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_add_option:"

SB="$(sandbox)"
RC="$SB/.bashrc"; touch "$RC"
PROFILE="$SB/.claude-aka"

# Stable initial subset that needs no optional runtime (bun/rtk/trufflehog), so the
# probe is deterministic in CI — same rationale as test_scn_smoke_roundtrip's SEL.
# A hook (leak-guard), a command (wrap-up), a skill (shell-audit), a statusLine
# (statusline), plus base settings (secure-settings).
BASE_SEL="secure-settings leak-guard wrap-up shell-audit statusline"

run() { CT_ADDITIONS="$1" SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# ── (0) seed: plant a user-owned (non-kit) deny rule so we can prove the upgrade
#        preserves the user's own settings, not just the kit's ─────────────────
mkdir -p "$PROFILE"
U_DENY='Read(//Users/me/upgrade-secret/**)'
cat > "$PROFILE/settings.json" <<JSON
{ "permissions": { "deny": ["$U_DENY"] } }
JSON

# ── (1) clean install of the base subset ─────────────────────────────────────
run "$BASE_SEL"; rc1=$?
assert_eq   "clean base install exits 0" "0" "$rc1"
assert_file "base hook deployed: leak-guard.sh"     "$PROFILE/hooks/leak-guard.sh"
assert_file "base command deployed: wrap-up.md"    "$PROFILE/commands/wrap-up.md"
assert_file "base skill deployed: shell-audit"     "$PROFILE/skills/shell-audit"
assert_file "base statusline hook deployed"        "$PROFILE/hooks/statusline.ts"
assert_ok   "settings.json valid JSON after base install" jq -e . "$PROFILE/settings.json"

# The two additions we will ADD on upgrade must NOT be present yet.
[ -e "$PROFILE/workflows/secure-deep-research.js" ] \
  && fail "secure-deep-research absent before upgrade" "present too early" \
  || pass "secure-deep-research absent before upgrade"
[ -e "$PROFILE/hooks/harness-pointer.sh" ] \
  && fail "harness-pointer absent before upgrade" "present too early" \
  || pass "harness-pointer absent before upgrade"

# Snapshot pre-upgrade state of the previously-selected additions + settings.
S="$PROFILE/settings.json"
WG_SUM_BEFORE="$(cksum < "$PROFILE/hooks/leak-guard.sh")"
WU_SUM_BEFORE="$(cksum < "$PROFILE/commands/wrap-up.md")"
SL_SUM_BEFORE="$(cksum < "$PROFILE/hooks/statusline.ts")"
cp "$S" "$SB/settings.before.json"
# leak-guard registration count (it registers under TWO matchers by design).
WG_REGS_BEFORE=$(jq '[.hooks.PreToolUse[]?.hooks[].command | select(endswith("/leak-guard.sh"))] | length' "$S")

# ── (2) UPGRADE: re-run with the same base PLUS two previously-unselected ids ─
ADD_SEL="$BASE_SEL secure-deep-research harness-pointer"
run "$ADD_SEL"; rc2=$?
assert_eq   "upgrade (add-option) re-run exits 0" "0" "$rc2"
assert_ok   "settings.json valid JSON after upgrade" jq -e . "$S"

# (a) the newly-selected additions' files are deployed (path-remapped).
assert_file "added: secure-deep-research workflow deployed" "$PROFILE/workflows/secure-deep-research.js"
assert_file "added: harness-pointer hook deployed"          "$PROFILE/hooks/harness-pointer.sh"
# harness-pointer is config-driven (usesConfig) → its config template lands too.
assert_file "added: harness-pointer config template placed" "$PROFILE/aka-claude-tools.config"

# (b) the new hook is registered in settings, exactly once (union add, no dupe).
assert_ok   "added harness-pointer registered in PreToolUse" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/harness-pointer.sh\"))' '$S' >/dev/null"
HP_REGS=$(jq '[.hooks.PreToolUse[]?.hooks[].command | select(endswith("/harness-pointer.sh"))] | length' "$S")
assert_eq   "harness-pointer registered exactly once" "1" "$HP_REGS"

# No duplicate PreToolUse registrations overall (the union must not double-add).
n_tot=$(jq '.hooks.PreToolUse | length' "$S")
n_uniq=$(jq '.hooks.PreToolUse | unique_by(tojson) | length' "$S")
assert_eq   "no duplicate PreToolUse registrations after upgrade" "$n_tot" "$n_uniq"

# (c) previously-selected additions UNTOUCHED — files byte-identical, regs intact.
assert_file "prev leak-guard hook still present"  "$PROFILE/hooks/leak-guard.sh"
assert_file "prev wrap-up command still present" "$PROFILE/commands/wrap-up.md"
assert_file "prev shell-audit skill still present" "$PROFILE/skills/shell-audit"
assert_file "prev statusline hook still present"  "$PROFILE/hooks/statusline.ts"
assert_eq   "prev leak-guard hook content unchanged"  "$WG_SUM_BEFORE" "$(cksum < "$PROFILE/hooks/leak-guard.sh")"
assert_eq   "prev wrap-up command content unchanged" "$WU_SUM_BEFORE" "$(cksum < "$PROFILE/commands/wrap-up.md")"
assert_eq   "prev statusline hook content unchanged" "$SL_SUM_BEFORE" "$(cksum < "$PROFILE/hooks/statusline.ts")"

assert_ok   "prev leak-guard registration retained" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.sh\"))' '$S' >/dev/null"
WG_REGS_AFTER=$(jq '[.hooks.PreToolUse[]?.hooks[].command | select(endswith("/leak-guard.sh"))] | length' "$S")
assert_eq   "prev leak-guard registration count unchanged" "$WG_REGS_BEFORE" "$WG_REGS_AFTER"
assert_ok   "statusLine still wired after upgrade" \
  bash -c "jq -e '(.statusLine.command // \"\") | endswith(\"/statusline.ts\")' '$S' >/dev/null"

# (d) the user's own (non-kit) deny rule planted before install survives the upgrade.
assert_ok   "user's own deny rule preserved through upgrade" \
  bash -c "jq -e '.permissions.deny | index(\"$U_DENY\") != null' '$S' >/dev/null"

# No maintainer-only \$comment keys leaked through the merge.
assert_ok   "no \$comment keys in merged settings after upgrade" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$S' >/dev/null"

# Single managed alias block in rc — the upgrade must not append a second.
n_block=$(grep -c '>>> aka-claude-tools managed' "$RC")
assert_eq   "single managed alias block in rc after upgrade" "1" "$n_block"

t_summary
