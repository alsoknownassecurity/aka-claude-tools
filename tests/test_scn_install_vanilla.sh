#!/usr/bin/env bash
# Scenario T6 — INSTALL/in-between: layer over a VANILLA stock profile.
#
# Models the common "I already use Claude Code with a stock config" case: a
# profile dir that EXISTS but carries only the user's own cosmetic prefs (a
# bare settings.json = {theme} — like a fresh ~/.claude-mobile), no kit hooks,
# no permissions, no kit. Re-pointing the installer at that dir under --defaults
# must LAYER IN PLACE (not rebuild): the default for any non-default existing
# profile is layer, not back-up-and-rebuild (install.sh setup_one_config 1b).
#
# Invariants asserted:
#   • layer-in-place, NOT rebuild  → no .claude-aka.backup-* dir is created.
#   • the user's cosmetic key (theme) survives the settings deep-merge.
#   • any other arbitrary user top-level key (a "real-shaped" extra) survives.
#   • kit settings are unioned in (permissions adopted, kit hook registered).
#   • no data loss: a pre-existing user file in the profile is untouched.
#   • $comment maintainer keys never leak; result is valid JSON.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit, never touches a
# real ~/.claude*. Stable recommended subset (no optional runtime) so CI is
# deterministic.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_vanilla:"

SB="$(sandbox)"
RC="$SB/.bashrc"; touch "$RC"
PROFILE="$SB/.claude-aka"               # default config dir under --defaults

# ── seed a VANILLA stock profile at the target dir ───────────────────────────
# settings.json carries ONLY the user's theme (a bare stock config). No hooks,
# no permissions, no kit. Plus an unrelated user file to prove no data loss and
# an extra arbitrary settings key the merge must pass through untouched.
mkdir -p "$PROFILE"
cat > "$PROFILE/settings.json" <<'JSON'
{
  "theme": "dark",
  "cleanupPeriodDays": 42
}
JSON
echo "# my own global memory" > "$PROFILE/CLAUDE.md"   # pre-existing user data

# Deterministic recommended subset that needs no optional runtime (bun/rtk/
# trufflehog), so the scenario is stable in CI: base settings + a hook + a
# command + a skill + a statusline.
SEL="secure-settings leak-guard wrap-up shell-audit statusline"

CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
rc=$?

assert_eq   "install exits 0 over a vanilla profile" "0" "$rc"
assert_file "profile dir still present" "$PROFILE"

S="$PROFILE/settings.json"
assert_ok   "settings.json is valid JSON" jq -e . "$S"

# ── layer-in-place, NOT rebuild ──────────────────────────────────────────────
# A rebuild would move the dir to .claude-aka.backup-* first; layer-in-place
# never does. The default for a non-default existing profile is layer.
n_bak=$(find "$SB" -maxdepth 1 -type d -name '.claude-aka.backup-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq   "no rebuild backup created (layered in place)" "0" "$n_bak"

# ── user's cosmetic prefs survive the deep-merge ─────────────────────────────
assert_ok   "user theme preserved" \
  bash -c "jq -e '.theme == \"dark\"' '$S' >/dev/null"
assert_ok   "other arbitrary user key preserved" \
  bash -c "jq -e '.cleanupPeriodDays == 42' '$S' >/dev/null"

# ── no data loss: pre-existing user file untouched ───────────────────────────
assert_file "pre-existing CLAUDE.md still present" "$PROFILE/CLAUDE.md"
assert_grep "CLAUDE.md content intact"            'my own global memory' "$PROFILE/CLAUDE.md"

# ── kit settings unioned in ──────────────────────────────────────────────────
# The vanilla profile had NO permissions; the kit's secure-settings denies must
# now be present (union added them).
assert_ok   "kit denies adopted (permissions unioned in)" \
  bash -c "jq -e '((.permissions.deny // []) | length) > 0' '$S' >/dev/null"
# The kit hook (leak-guard) was placed and registered in settings.
assert_file "kit hook placed: leak-guard.sh" "$PROFILE/hooks/leak-guard.sh"
assert_ok   "leak-guard registered in settings.PreToolUse" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.sh\"))' '$S' >/dev/null"
assert_ok   "statusLine wired in settings" \
  bash -c "jq -e '(.statusLine.command // \"\") | endswith(\"/statusline.ts\")' '$S' >/dev/null"

# ── selected kit artifacts placed ────────────────────────────────────────────
assert_file "command placed: wrap-up.md"  "$PROFILE/commands/wrap-up.md"
assert_file "skill placed: shell-audit"   "$PROFILE/skills/shell-audit"
assert_file "statusline hook placed"      "$PROFILE/hooks/statusline.ts"

# ── no maintainer-only $comment leak ─────────────────────────────────────────
assert_ok   "no \$comment keys in layered settings" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$S' >/dev/null"

# Install reported success.
assert_grep "install reported done" 'Done|ready' "$SB/log"

t_summary
