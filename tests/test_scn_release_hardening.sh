#!/usr/bin/env bash
# Scenario release_hardening: regressions for the pre-public-release fixes —
#   C1  a DANGLING aka-claude-tools.config symlink must not abort the install.
#   H1  a user's existing statusLine is stashed on install and RESTORED on deselect.
#   M1  the corrupt-settings die message names a REAL recovery (no phantom --clean flag).
#   M3  targeting the default ~/.claude warns (engine mode) instead of modifying silently.
# Fully sandboxed: fake $HOME, throwaway profiles, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_release_hardening:"

# ── C1: dangling config symlink must not abort the install ────────────────────
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P"
ln -s "$SB/moved-away.config" "$P/aka-claude-tools.config"   # symlink to a missing target
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="leak-guard" bash "$REPO_ROOT/install.sh" --apply >"$SB/c1.log" 2>&1
assert_eq   "C1: install over a dangling config symlink exits 0" "0" "$?"
assert_ok   "C1: config is now a real file, not a dangling link" \
  bash -c "[ -f '$P/aka-claude-tools.config' ] && [ ! -L '$P/aka-claude-tools.config' ]"

# ── H1: user statusLine stashed on install, restored on deselect ──────────────
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P"
printf '%s\n' '{"statusLine":{"type":"command","command":"myframework/my-statusline.sh"}}' > "$P/settings.json"
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="statusline" bash "$REPO_ROOT/install.sh" --apply >/dev/null 2>&1
assert_ok   "H1: kit statusLine installed" \
  bash -c "jq -e '.statusLine.command | endswith(\"/hooks/statusline.ts\")' '$P/settings.json' >/dev/null"
assert_ok   "H1: user's prior statusLine stashed" \
  bash -c "jq -e '._aka_prior_statusLine.command == \"myframework/my-statusline.sh\"' '$P/settings.json' >/dev/null"
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="" bash "$REPO_ROOT/install.sh" --apply >/dev/null 2>&1
assert_ok   "H1: prior statusLine RESTORED on deselect" \
  bash -c "jq -e '.statusLine.command == \"myframework/my-statusline.sh\"' '$P/settings.json' >/dev/null"
assert_ok   "H1: stash key removed after restore" \
  bash -c "jq -e 'has(\"_aka_prior_statusLine\") | not' '$P/settings.json' >/dev/null"

# ── H1 (anchoring): a NON-kit statusLine that only RESEMBLES the kit path — a suffix
#    (.../statusline.sh-wrapper) or a mid-string mention — must NOT be mistaken for the
#    kit's. End-anchored (endswith), so it is stashed verbatim on install and restored on
#    deselect; a substring `contains` would mis-classify it and silently lose it. ──
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P"
printf '%s\n' '{"statusLine":{"type":"command","command":"/opt/custom/hooks/statusline.sh-wrapper"}}' > "$P/settings.json"
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="statusline" bash "$REPO_ROOT/install.sh" --apply >/dev/null 2>&1
assert_ok   "H1-anchor: a suffix-named (...statusline.sh-wrapper) user statusLine is stashed, not mistaken for the kit's" \
  bash -c "jq -e '._aka_prior_statusLine.command == \"/opt/custom/hooks/statusline.sh-wrapper\"' '$P/settings.json' >/dev/null"
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="" bash "$REPO_ROOT/install.sh" --apply >/dev/null 2>&1
assert_ok   "H1-anchor: the suffix-named user statusLine is RESTORED verbatim on deselect" \
  bash -c "jq -e '.statusLine.command == \"/opt/custom/hooks/statusline.sh-wrapper\"' '$P/settings.json' >/dev/null"

# ── M1: corrupt-settings die message names a REAL recovery (no phantom --clean) ─
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P"
printf '%s' '{ this is not json' > "$P/settings.json"
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="secure-settings" bash "$REPO_ROOT/install.sh" --apply >"$SB/m1.log" 2>&1
assert_eq   "M1: corrupt settings aborts non-zero" "1" "$?"
assert_lit  "M1: message names a real recovery (move it aside)" "move it aside" "$SB/m1.log"
assert_nlit "M1: message does NOT reference the non-existent --clean flag" "--clean" "$SB/m1.log"

# ── M3: targeting the default ~/.claude warns (engine mode) ───────────────────
SB="$(sandbox)"
HOME="$SB" CT_CONFIG_DIR="$SB/.claude" CT_ADDITIONS="secure-settings" bash "$REPO_ROOT/install.sh" --apply >"$SB/m3.log" 2>&1
assert_eq   "M3: --apply onto the default dir still succeeds" "0" "$?"
assert_grep "M3: a DEFAULT-profile heads-up is printed" "DEFAULT Claude Code config" "$SB/m3.log"

t_summary
