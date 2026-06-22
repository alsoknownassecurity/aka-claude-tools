#!/usr/bin/env bash
# Scenario — --apply STAMPS the .aka-claude-tools-meta managed marker.
#
# agent-install Step 1 detects a kit-managed profile by EITHER a .aka-claude-tools-meta
# file OR a recognizable kit hook (command-guard.ts / leak-guard.sh) in settings.json.
# Before this, the marker was written only by --alias, so a MINIMAL selection installed
# via --apply (e.g. secure-settings + statusline — no recognizable hooks) produced a
# profile that carried NEITHER signal and was undetectable as kit-managed. --apply now
# stamps managed=aka-claude-tools so any kit-installed profile is detectable.
#
# Invariants:
#   A. A minimal --apply (no command-guard/leak-guard) creates the marker.
#   B. Stamping is idempotent — re-apply never duplicates the managed= line.
#   C. --alias adds alias= WITHOUT clobbering managed=, and a later --apply preserves alias=.
#
# Fully sandboxed: fake $HOME, --no-auth-inherit, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_apply_meta:"

INSTALL="$REPO_ROOT/install.sh"
# Minimal selection on purpose: neither addition registers a Step-1-recognized hook,
# so the marker file is the ONLY thing that makes the profile detectable.
MIN="secure-settings statusline"

# ── A. minimal --apply stamps the marker ─────────────────────────────────────
SB="$(sandbox)"; DIR="$SB/.claude-aka"
CT_CONFIG_DIR="$DIR" CT_ADDITIONS="$MIN" HOME="$SB" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB/log" 2>&1
assert_eq   "minimal --apply exits 0" "0" "$?"
META="$DIR/.aka-claude-tools-meta"
assert_file "marker created by --apply" "$META"
assert_grep "marker carries managed=aka-claude-tools" "^managed=aka-claude-tools$" "$META"
# Prove the gap this closes: neither Step-1 hook signal is present in this selection.
assert_ngrep "no command-guard/leak-guard hook signal (marker is the only signal)" \
  "command-guard\.ts|leak-guard\.sh" "$DIR/settings.json"

# ── B. idempotent — re-apply must not duplicate managed= ──────────────────────
CT_CONFIG_DIR="$DIR" CT_ADDITIONS="$MIN" HOME="$SB" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB/log2" 2>&1
n="$(grep -c '^managed=' "$META" 2>/dev/null || echo 0)"
assert_eq "re-apply keeps exactly one managed= line" "1" "$n"

# ── C. --alias adds alias= without clobbering managed=; later --apply preserves alias= ─
export HOME="$SB"; RC="$SB/.zshrc"; touch "$RC"
SHELL=/bin/zsh CT_CONFIG_DIR="$DIR" CT_ALIAS="tmpaka" \
  bash "$INSTALL" --alias --no-auth-inherit >"$SB/log3" 2>&1
assert_grep "managed= survives --alias" "^managed=aka-claude-tools$" "$META"
assert_grep "alias= written by --alias"  "^alias=tmpaka$" "$META"
# A later --apply must NOT drop the alias= line a prior --alias wrote.
CT_CONFIG_DIR="$DIR" CT_ADDITIONS="$MIN" HOME="$SB" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB/log4" 2>&1
assert_grep "alias= preserved across a later --apply" "^alias=tmpaka$" "$META"
assert_grep "managed= still present after that --apply" "^managed=aka-claude-tools$" "$META"

t_summary
