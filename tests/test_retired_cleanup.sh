#!/usr/bin/env bash
# Retired-addition cleanup — an addition the kit shipped before and has since
# dropped entirely (so it's gone from additions.json) is tombstoned in
# managed-permissions.json (.retiredAdditions[].paths). On upgrade, the installer
# must delete its orphaned files from the profile — WITHOUT touching the user's own.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_retired_cleanup:"

# This test is meaningful only while there's at least one tombstone to exercise.
n_ret=$(jq '.retiredAdditions // [] | length' "$REPO_ROOT/config/managed-permissions.json")
if [ "${n_ret:-0}" -eq 0 ]; then pass "no retiredAdditions tombstones — nothing to clean (skip)"; t_summary; exit; fi

SB="$(sandbox)"; touch "$SB/.bashrc"
PROFILE="$SB/.claude-aka"
SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log1" 2>&1

# Plant (a) an orphan at the FIRST tombstoned path, and (b) a user-owned skill the
# cleanup must never touch.
RET_PATH="$(jq -r '.retiredAdditions[0].paths[0]' "$REPO_ROOT/config/managed-permissions.json")"
mkdir -p "$PROFILE/$RET_PATH";              echo stale > "$PROFILE/$RET_PATH/SKILL.md"
mkdir -p "$PROFILE/skills/my-own-skill";    echo mine  > "$PROFILE/skills/my-own-skill/SKILL.md"

assert_file "orphan present before upgrade" "$PROFILE/$RET_PATH"

# Re-run = upgrade.
SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log2" 2>&1
assert_eq "upgrade exits 0" "0" "$?"

[ -e "$PROFILE/$RET_PATH" ] && fail "retired-addition orphan removed on upgrade" "still present: $RET_PATH" \
                            || pass "retired-addition orphan removed on upgrade"
assert_file "user-owned skill left untouched" "$PROFILE/skills/my-own-skill/SKILL.md"

t_summary
