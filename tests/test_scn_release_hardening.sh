#!/usr/bin/env bash
# Scenario release_hardening (hook-migration): regressions for the legacy pre-marker
# hook cleanup shipped for the public release —
#   C2  hook-rename owner-stamp matches a $HOME-LITERAL registration (not just
#       the expanded absolute path) — the form that left old+new guards both firing.
#   H2  install.sh auto-cleans legacy pre-marker hooks (the migrate fold-in): no
#       double-registration, legacy files removed, a backup is taken first.
#   N3  hook-rename does NOT rewrite / falsely report on an already-current profile.
#   anchoring: the matcher is END-anchored + inner-hook precise — a user command that merely
#       mentions a legacy path, and a user hook sharing a matcher group, are preserved.
# Fully sandboxed: fake $HOME, throwaway profiles, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_release_hardening:"

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
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command] | any(endswith(\"/leak-guard.sh\"))' '$P/settings.json' >/dev/null"
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

# ── anchoring: a USER command that merely MENTIONS a legacy path is NOT deleted; an
#    ARRAY-form legacy registration IS matched (end-anchored, type-safe) ──
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P/hooks"
echo legit > "$P/hooks/leak-guard.sh"
echo mine  > "$P/hooks/my-tool.sh"
cat > "$P/settings.json" <<JSON
{"hooks":{"PreToolUse":[
  {"matcher":"WebSearch|WebFetch","hooks":[{"type":"command","command":["bash","\$HOME/.claude-aka/hooks/leak-guard.sh"]}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"echo ref \$HOME/.claude-aka/hooks/command-guard.ts && \$HOME/.claude-aka/hooks/my-tool.sh"}]}
]}}
JSON
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="leak-guard" bash "$REPO_ROOT/install.sh" --apply >/dev/null 2>&1
assert_ngrep "anchor: ARRAY-form legacy registration is pruned" "leak-guard.sh" "$P/settings.json"
assert_ok   "anchor: user cmd MENTIONING a legacy path mid-string is preserved (end-anchored)" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command | strings] | any(contains(\"my-tool.sh\"))' '$P/settings.json' >/dev/null"
assert_ok   "anchor: the user's own hook file is NOT deleted" bash -c "[ -f '$P/hooks/my-tool.sh' ]"

# A user hook SHARING a matcher group with a legacy hook must survive (inner-hook prune).
SB="$(sandbox)"; P="$SB/.claude-aka"; mkdir -p "$P/hooks"; echo x > "$P/hooks/command-guard.ts"
cat > "$P/settings.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
  {"type":"command","command":"\$HOME/.claude-aka/hooks/command-guard.ts"},
  {"type":"command","command":"\$HOME/.claude-aka/hooks/keep-me.sh"}
]}]}}
JSON
HOME="$SB" CT_CONFIG_DIR="$P" CT_ADDITIONS="command-guard" bash "$REPO_ROOT/install.sh" --apply >/dev/null 2>&1
assert_ngrep "anchor: legacy hook in a shared group is pruned" "command-guard.ts" "$P/settings.json"
assert_ok   "anchor: a SIBLING user hook in the same group is preserved" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command | strings] | any(endswith(\"/keep-me.sh\"))' '$P/settings.json' >/dev/null"

t_summary
