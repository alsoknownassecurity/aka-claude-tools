#!/usr/bin/env bash
# Upgrade / in-between (T16) — a profile installed by an OLDER kit, then upgraded by
# re-running THIS version's install.sh over it. The older profile is "in between":
#   • it is MISSING newly-added additions (its skills/ has none of the current kit's)
#   • it still carries RETIRED permission rules (denies this version no longer ships)
#   • it carries the USER's own permission rule (one the kit never shipped)
#   • it has an ORPHANED retired-addition's files (a whole addition the kit dropped)
# A non-interactive upgrade (--defaults) must, in ONE pass, reconcile all four:
#   new kit rules adopted (default), retired rules dropped (default), user rule kept,
#   and the retiredAdditions[].paths orphan deleted — while the new additions land.
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit, never touches a real
# ~/.claude*. The "older kit" state is hand-seeded inside the sandbox.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_older_kit:"

MP="$REPO_ROOT/config/managed-permissions.json"
BASE="$REPO_ROOT/config/settings.base.json"

# Sample data straight from the kit's own config so this stays correct as the kit
# evolves: one retired deny the kit no longer ships, one current deny it DOES ship.
RET_DENY="$(jq -r '.retired.deny[0] // empty' "$MP")"
CUR_DENY="$(jq -r '.permissions.deny[0] // empty' "$BASE")"
if [ -z "$RET_DENY" ] || [ -z "$CUR_DENY" ]; then
  pass "no retired/current deny rules to exercise (skip)"; t_summary; exit
fi
# Guard the premise: the sample retired rule must NOT also be in the current set
# (else "dropped" is unobservable). If the kit ever re-ships a retired rule, pick
# a different one rather than silently passing a meaningless assertion.
if jq -e --arg r "$RET_DENY" '.permissions.deny | index($r) != null' "$BASE" >/dev/null; then
  RET_DENY="$(jq -r --slurpfile b "$BASE" '.retired.deny[] | select(. as $x | ($b[0].permissions.deny | index($x)) == null)' "$MP" | head -1)"
fi
[ -z "$RET_DENY" ] && { pass "every retired deny is back in the current set (skip)"; t_summary; exit; }

SB="$(sandbox)"; touch "$SB/.bashrc"
PROFILE="$SB/.claude-aka"; mkdir -p "$PROFILE/skills"

USER_DENY='Read(//Users/me/secret-vault/**)'   # the user's own rule — kit never shipped it

# ── Seed the "older kit" profile state ───────────────────────────────────────
# (a) settings.json with a retired deny + the user's own deny, but WITHOUT the
#     current kit deny (an older kit predates it).
cat > "$PROFILE/settings.json" <<JSON
{ "permissions": { "deny": ["$RET_DENY", "$USER_DENY"] } }
JSON

# (b) an orphaned retired-addition's files at the first tombstoned path, IF the kit
#     currently tombstones any. (Behaviour is asserted conditionally below.)
RET_ADD_PATH="$(jq -r '.retiredAdditions[0].paths[0] // empty' "$MP")"
if [ -n "$RET_ADD_PATH" ]; then
  mkdir -p "$PROFILE/$RET_ADD_PATH"; echo "stale older-kit addition" > "$PROFILE/$RET_ADD_PATH/SKILL.md"
  assert_file "orphan retired-addition present before upgrade" "$PROFILE/$RET_ADD_PATH"
fi

# Sanity: the older profile carries NONE of the recommended skills yet (it predates
# them). Pick a recommended skill addition the current kit ships to prove it lands.
NEW_SKILL_REL="$(jq -r '.additions[] | select(.recommended==true) | .skill // empty' "$ADDITIONS" | head -1)"

# ── The upgrade: re-run THIS version's install non-interactively over the profile ─
SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
rc=$?
assert_eq "upgrade run exits 0" "0" "$rc"

S="$PROFILE/settings.json"
assert_ok "settings.json still valid JSON after upgrade" jq -e . "$S"

# (1) retired rule DROPPED (default non-interactive action).
assert_ok "retired deny rule was DROPPED on upgrade" \
  bash -c "jq -e --arg r '$RET_DENY' '.permissions.deny | index(\$r) == null' '$S' >/dev/null"

# (2) user's OWN rule KEPT — a reconcile must never touch a rule the kit never shipped.
assert_ok "user's own deny rule was KEPT" \
  bash -c "jq -e --arg u '$USER_DENY' '.permissions.deny | index(\$u) != null' '$S' >/dev/null"

# (3) new kit rule ADOPTED (the current deny the older profile lacked).
assert_ok "current-version deny rule was ADOPTED on upgrade" \
  bash -c "jq -e --arg c '$CUR_DENY' '.permissions.deny | index(\$c) != null' '$S' >/dev/null"

# (4) the deny set should now contain the full current kit set (every current deny
#     present), proving a broad adopt rather than a single-rule fluke.
assert_ok "all current-version deny rules present after upgrade" \
  bash -c "jq -e --slurpfile b '$BASE' '(\$b[0].permissions.deny - .permissions.deny) | length == 0' '$S' >/dev/null"

# (5) retired-addition orphan REMOVED (if the kit tombstones any).
if [ -n "$RET_ADD_PATH" ]; then
  [ -e "$PROFILE/$RET_ADD_PATH" ] \
    && fail "retired-addition orphan removed on upgrade" "still present: $RET_ADD_PATH" \
    || pass "retired-addition orphan removed on upgrade"
else
  pass "no retiredAdditions tombstones to exercise (skip orphan check)"
fi

# (6) the missing new addition is now installed (the upgrade actually layers in the
#     additions the older kit lacked).
if [ -n "$NEW_SKILL_REL" ]; then
  assert_file "newly-added recommended skill now installed: $NEW_SKILL_REL" "$PROFILE/$NEW_SKILL_REL"
else
  pass "no recommended skill addition to verify (skip)"
fi

# (7) no maintainer-only \$comment keys leaked into the merged settings.
assert_ok "no \$comment keys in upgraded settings" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$S' >/dev/null"

t_summary
