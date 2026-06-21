#!/usr/bin/env bash
# Scenario statusline_location (cross-vendor finding): the statusline addition can
# pin a weather location into .preferences.location at install, but deselect only
# pruned the .statusLine command — so the pinned .preferences.location survived an
# uninstall as residue. Fix: prune_addition_from_settings also drops the kit-pinned
# .preferences.location (and an emptied .preferences) when statusline is deselected.
# The interactive geocode isn't reachable in-sandbox, so we simulate the pinned
# location by injecting it, then deselect. Fully sandboxed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_statusline_location:"

SB="$(sandbox)"; touch "$SB/.bashrc"
P="$SB/.claude-aka"; S="$P/settings.json"

# Install statusline → .statusLine registered.
CT_ADDITIONS="statusline" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log1" 2>&1
assert_eq "install statusline exits 0" "0" "$?"
assert_ok "statusLine registered after install" bash -c "jq -e '.statusLine' '$S' >/dev/null"

# Simulate a pinned location (what the interactive geocode would write).
tmp="$(mktemp)"; jq '.preferences.location = {latitude:1.0, longitude:2.0, countryCode:"US", regionCode:"CA"}' "$S" > "$tmp" && mv "$tmp" "$S"
assert_ok "seeded preferences.location present" bash -c "jq -e '.preferences.location' '$S' >/dev/null"

# Deselect statusline (re-run without it) → both .statusLine AND the pinned location go.
CT_ADDITIONS="secure-settings" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log2" 2>&1
assert_eq "deselect statusline exits 0" "0" "$?"
assert_ok "settings.json valid JSON after deselect" jq -e . "$S"
assert_ok "statusLine removed on deselect" bash -c "jq -e '(.statusLine // null) == null' '$S' >/dev/null"
assert_ok "pinned preferences.location removed on deselect (no residue)" \
  bash -c "jq -e '(.preferences.location // null) == null' '$S' >/dev/null"

t_summary
