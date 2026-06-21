#!/usr/bin/env bash
# Settings merge — a layer-in-place install over a profile that already has the
# USER's own permission rules and hooks must UNION them in (never drop the user's
# protections), adopt the kit's rules, and strip maintainer-only "$comment" keys.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_settings_merge:"

SB="$(sandbox)"; touch "$SB/.bashrc"
PROFILE="$SB/.claude-aka"; mkdir -p "$PROFILE"

# A pre-existing profile carrying rules the kit NEVER ships (the user's own) +
# a user hook. None of these are kit rules or in managed-permissions retired, so
# reconciliation must leave every one of them untouched.
U_DENY='Read(//Users/me/secret/**)'
U_ALLOW='Bash(mytool:*)'
U_HOOK='echo USER_HOOK_SENTINEL'
cat > "$PROFILE/settings.json" <<JSON
{
  "permissions": { "deny": ["$U_DENY"], "allow": ["$U_ALLOW"] },
  "hooks": { "PreToolUse": [ {"matcher":"Bash","hooks":[{"type":"command","command":"$U_HOOK"}]} ] }
}
JSON

SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
assert_eq "install exits 0 over an existing profile" "0" "$?"

S="$PROFILE/settings.json"
assert_ok "settings.json still valid JSON" jq -e . "$S"

# The user's own rules/hook survive the merge (union, not replace).
assert_ok "user deny preserved"  bash -c "jq -e '.permissions.deny  | index(\"$U_DENY\")  != null' '$S' >/dev/null"
assert_ok "user allow preserved" bash -c "jq -e '.permissions.allow | index(\"$U_ALLOW\") != null' '$S' >/dev/null"
assert_ok "user hook preserved"  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command] | index(\"$U_HOOK\") != null' '$S' >/dev/null"

# The kit's own rules were adopted alongside (a representative secure-settings deny).
assert_ok "kit denies adopted (union added kit rules)" \
  bash -c "jq -e '(.permissions.deny | length) > 1' '$S' >/dev/null"

# Maintainer-only "\$comment" keys never leak into the user's settings.
assert_ok "no \$comment keys in merged settings" \
  bash -c "jq -e 'any(.. | objects; has(\"\$comment\")) | not' '$S' >/dev/null"

t_summary
