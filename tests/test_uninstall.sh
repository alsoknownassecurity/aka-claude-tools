#!/usr/bin/env bash
# Uninstall on deselect — the "idempotent BOTH ways" promise. Installing an
# addition then re-running WITHOUT it must delete its files and prune its settings
# registrations, while leaving still-selected additions (and the user) intact.
# Uses CT_ADDITIONS for a deterministic non-interactive selection.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_uninstall:"

SB="$(sandbox)"; touch "$SB/.bashrc"
PROFILE="$SB/.claude-aka"
run() { CT_ADDITIONS="$1" SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# Install leak-guard + wrap-up.
run "leak-guard wrap-up"
assert_file "leak-guard hook deployed"      "$PROFILE/hooks/leak-guard.ts"
assert_file "wrap-up command deployed"     "$PROFILE/commands/wrap-up.md"
assert_ok   "leak-guard registered in settings" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.ts\"))' '$PROFILE/settings.json' >/dev/null"

# Re-run WITHOUT leak-guard → it must be uninstalled, wrap-up retained.
run "wrap-up"
assert_eq "re-run (deselect) exits 0" "0" "$?"
[ -e "$PROFILE/hooks/leak-guard.ts" ] && fail "leak-guard hook file removed on deselect" "still present" \
                                     || pass "leak-guard hook file removed on deselect"
assert_ok   "leak-guard registration pruned from settings" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.ts\")) | not' '$PROFILE/settings.json' >/dev/null"
assert_file "still-selected wrap-up retained" "$PROFILE/commands/wrap-up.md"
assert_ok   "settings.json still valid JSON after uninstall" jq -e . "$PROFILE/settings.json"

t_summary
