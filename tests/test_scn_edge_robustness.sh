#!/usr/bin/env bash
# Scenario edge_robustness (cross-vendor finding): the prune path must survive
# valid-JSON-but-wrong-SHAPE existing settings, not just wrong-typed permissions.
# Last round's coercion guarded permissions/hooks-event-arrays/env; GPT-5.4 caught
# that it did NOT guard: statusLine as a STRING, a hook-event array containing a
# NON-OBJECT element, and statusLine.command as an ARRAY — each of which made
# prune_statusline / prune_hook_regs abort jq mid-install (deselect path).
# A re-run that deselects statusline + the guards triggers both pruners over the
# seeded settings; with the fix the install survives and the secure baseline lands.
# Fully sandboxed: fake $HOME, --defaults --no-auth-inherit, never a real profile.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_edge_robustness:"

SB="$(sandbox)"; touch "$SB/.bashrc"
P="$SB/.claude-aka"; mkdir -p "$P"
# Valid JSON, hostile SHAPES the pruners historically choked on:
cat > "$P/settings.json" <<'JSON'
{
  "statusLine": "x",
  "hooks": {
    "PreToolUse": [
      "not-an-object",
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": ["/p/leak-guard.sh", "--flag"] } ] }
    ]
  },
  "permissions": { "deny": ["Read(/keep/**)"] }
}
JSON
assert_ok "seed is valid JSON" jq -e . "$P/settings.json"

# Install selecting only secure-settings → statusline + both guards are UNSELECTED,
# so their pruners run over the odd-shaped existing settings.
CT_ADDITIONS="secure-settings" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
rc=$?

assert_eq   "install over wrong-SHAPED settings exits 0 (prune does not abort)" "0" "$rc"
assert_nlit "no raw 'jq: error' leaked to the user" "jq: error" "$SB/log"
assert_ok   "settings.json is valid JSON after install" jq -e . "$P/settings.json"

KIT_DENY="$(jq -r '.permissions.deny[0]' "$REPO_ROOT/config/settings.base.json")"
assert_ok "kit secure-baseline deny enforced (baseline landed despite odd input)" \
  bash -c "jq -e --arg r '$KIT_DENY' '(.permissions.deny // []) | index(\$r) != null' '$P/settings.json' >/dev/null"
assert_ok "user's own deny preserved through the odd-shape prune" \
  bash -c "jq -e '(.permissions.deny // []) | index(\"Read(/keep/**)\") != null' '$P/settings.json' >/dev/null"

t_summary
