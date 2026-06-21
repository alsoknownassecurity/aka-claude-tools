#!/usr/bin/env bash
# Managed-permission reconciliation — on a re-run/upgrade over an existing profile,
# a permission rule the kit shipped before and has since RETIRED (listed in
# config/managed-permissions.json .retired) is dropped, while a rule the kit never
# shipped (the user's own) is always kept. A plain union could never remove a rule.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_reconcile:"

RET="$(jq -r '.retired.deny[0] // empty' "$REPO_ROOT/config/managed-permissions.json")"
if [ -z "$RET" ]; then pass "no retired deny rules to exercise (skip)"; t_summary; exit; fi

SB="$(sandbox)"; touch "$SB/.bashrc"
PROFILE="$SB/.claude-aka"; mkdir -p "$PROFILE"
USER_DENY='Read(//Users/me/private/**)'

# A profile carrying one retired kit rule + one rule that's purely the user's own.
cat > "$PROFILE/settings.json" <<JSON
{ "permissions": { "deny": ["$RET", "$USER_DENY"] } }
JSON

# Re-run (CT_NONINTERACTIVE takes the default reconcile action: adopt new / retire dropped).
SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
assert_eq "reconcile run exits 0" "0" "$?"

S="$PROFILE/settings.json"
assert_ok "retired kit rule was DROPPED on upgrade" \
  bash -c "jq -e --arg r '$RET' '.permissions.deny | index(\$r) == null' '$S' >/dev/null"
assert_ok "user's own rule was KEPT" \
  bash -c "jq -e '.permissions.deny | index(\"$USER_DENY\") != null' '$S' >/dev/null"
assert_ok "current kit denies still adopted (set non-empty)" \
  bash -c "jq -e '(.permissions.deny | length) > 1' '$S' >/dev/null"

t_summary
