#!/usr/bin/env bash
# Scenario release_hardening: regressions for the pre-public-release fixes —
#   C1  a DANGLING aka-claude-tools.config symlink must not abort the install.
#   H1  a user's existing statusLine is stashed on install and RESTORED on deselect.
#   C2  hook-rename owner-stamp matches a $HOME-LITERAL registration (not just
#       the expanded absolute path) — the form that left old+new guards both firing.
#   H2  install.sh auto-cleans legacy pre-marker hooks (the migrate fold-in): no
#       double-registration, legacy files removed, a backup is taken first.
#   N3  hook-rename does NOT rewrite / falsely report on an already-current profile.
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

# ── H2 + C2: legacy pre-marker hooks ($HOME-literal regs) cleaned on upgrade ──
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P/hooks"
echo "old web egress" > "$P/hooks/leak-guard.sh"
echo "old bash egress" > "$P/hooks/command-guard.ts"
cat > "$P/settings.json" <<JSON
{"hooks":{"PreToolUse":[
  {"matcher":"WebSearch|WebFetch","hooks":[{"type":"command","command":"\$HOME/.claude-aka/hooks/leak-guard.sh"}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"\$HOME/.claude-aka/hooks/command-guard.ts"}]}
]}}
JSON
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="leak-guard command-guard" bash "$REPO_ROOT/install.sh" --apply >"$SB/h2.log" 2>&1
assert_eq   "H2: upgrade over a legacy profile exits 0" "0" "$?"
assert_ngrep "H2: NO legacy leak-guard registration survives" \
  "leak-guard.sh" "$P/settings.json"
assert_ngrep "H2: NO legacy command-guard registration survives" \
  "command-guard.ts" "$P/settings.json"
assert_ok   "H2: new leak-guard registered" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command] | any(endswith(\"/leak-guard.ts\"))' '$P/settings.json' >/dev/null"
assert_ok   "H2: legacy hook FILES removed" \
  bash -c "[ ! -e '$P/hooks/leak-guard.sh' ] && [ ! -e '$P/hooks/command-guard.ts' ]"
assert_ok   "H2: a backup of the legacy hooks was taken first" \
  bash -c "ls -d '$P'/backups/legacy-hooks-* >/dev/null 2>&1 && [ -f '$P'/backups/legacy-hooks-*/command-guard.ts ]"

# ── C2 + N3: hook-rename standalone — owner-stamp, idempotent, no false write
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P/hooks"
echo x > "$P/hooks/command-guard.ts"
cat > "$P/settings.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\$HOME/.claude-aka/hooks/command-guard.ts"}]}]}}
JSON
HOME="$SB" bash "$REPO_ROOT/hook-rename.sh" "$P" >"$SB/m.log" 2>&1
assert_ok   "C2: migrate removed the \$HOME-literal-registered legacy hook" \
  bash -c "[ ! -e '$P/hooks/command-guard.ts' ]"
assert_ngrep "C2: legacy registration pruned from settings" "command-guard.ts" "$P/settings.json"
# Already-current now → must report Nothing to migrate AND not rewrite the file.
before="$(cat "$P/settings.json")"
HOME="$SB" bash "$REPO_ROOT/hook-rename.sh" "$P" >"$SB/m2.log" 2>&1
assert_grep "N3: already-current run reports Nothing to migrate" "Nothing to migrate" "$SB/m2.log"
assert_ngrep "N3: already-current run does NOT claim it pruned anything" "pruned stale" "$SB/m2.log"
assert_eq   "N3: settings.json byte-identical on the no-op run" "$before" "$(cat "$P/settings.json")"

# user's OWN same-named hook (no kit registration resolving here) is KEPT
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P/hooks"
echo mine > "$P/hooks/leak-guard.sh"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/elsewhere/leak-guard.sh"}]}]}}' > "$P/settings.json"
HOME="$SB" bash "$REPO_ROOT/hook-rename.sh" "$P" >/dev/null 2>&1
assert_ok   "C2: a user's own same-named hook (different path) is preserved" \
  bash -c "[ -f '$P/hooks/leak-guard.sh' ]"

# ── C2 (anchoring): a USER command that merely MENTIONS a legacy path is NOT deleted,
#    and an ARRAY-form legacy registration IS matched (adversarial command shapes) ──
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P/hooks"
echo legit > "$P/hooks/leak-guard.sh"          # a real legacy file (array-registered)
echo mine  > "$P/hooks/my-tool.sh"                        # the user's own hook
# The user's hook MENTIONS a legacy path mid-string (as an echo/ref) but its command
# ENDS with the user's own hook — end-anchoring must keep it. The array-form legacy reg
# (joined to a string that ENDS with the legacy path) must be pruned.
cat > "$P/settings.json" <<JSON
{"hooks":{"PreToolUse":[
  {"matcher":"WebSearch|WebFetch","hooks":[{"type":"command","command":["bash","\$HOME/.claude-aka/hooks/leak-guard.sh"]}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"echo ref \$HOME/.claude-aka/hooks/command-guard.ts && \$HOME/.claude-aka/hooks/my-tool.sh"}]}
]}}
JSON
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="leak-guard" bash "$REPO_ROOT/install.sh" --apply >/dev/null 2>&1
assert_ngrep "C2-anchor: ARRAY-form legacy registration is pruned" "leak-guard.sh" "$P/settings.json"
assert_ok   "C2-anchor: user cmd MENTIONING a legacy path mid-string is preserved (end-anchored)" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command | strings] | any(contains(\"my-tool.sh\"))' '$P/settings.json' >/dev/null"
assert_ok   "C2-anchor: the user's own hook file is NOT deleted" bash -c "[ -f '$P/hooks/my-tool.sh' ]"

# A user hook SHARING a matcher group with a legacy hook must survive (prune at the
# inner-hook level, not the whole group — cross-vendor review catch).
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P/hooks"; echo x > "$P/hooks/command-guard.ts"
cat > "$P/settings.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
  {"type":"command","command":"\$HOME/.claude-aka/hooks/command-guard.ts"},
  {"type":"command","command":"\$HOME/.claude-aka/hooks/keep-me.sh"}
]}]}}
JSON
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="command-guard" bash "$REPO_ROOT/install.sh" --apply >/dev/null 2>&1
assert_ngrep "C2-anchor: legacy hook in a shared group is pruned" "command-guard.ts" "$P/settings.json"
assert_ok   "C2-anchor: a SIBLING user hook in the same group is preserved" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command | strings] | any(endswith(\"/keep-me.sh\"))' '$P/settings.json' >/dev/null"

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
