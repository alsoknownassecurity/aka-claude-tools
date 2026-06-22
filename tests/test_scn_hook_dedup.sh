#!/usr/bin/env bash
# Scenario — kit hook registrations dedup by RESOLVED TARGET, not exact string.
#
# The settings union dedups hook registrations by exact command string. Converting a
# profile that already registered a kit hook with a different path SPELLING than the
# canonical one the kit writes (e.g. `$HOME/.claude-x/hooks/harness-pointer.sh` vs the
# kit's single-quoted absolute form) left BOTH after the union — the hook double-fired.
# --apply now prunes any existing reg that RESOLVES to a kit hook file it (re)registers.
#
# Invariants:
#   A. A $HOME-spelled reg of a kit hook is collapsed to the single canonical reg
#      (no duplicate) on --apply.
#   B. PATH-AWARE: a USER hook sharing the kit basename but living elsewhere is PRESERVED
#      (the anti-criterion — never silently drop another profile's own hook).
#   C. Idempotent: a second --apply does not re-introduce a duplicate.
#
# Fully sandboxed: fake $HOME, --no-auth-inherit, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_hook_dedup:"

INSTALL="$REPO_ROOT/install.sh"
SB="$(sandbox)"; export HOME="$SB"; DIR="$SB/prof"
mkdir -p "$DIR/hooks"

# Pre-seed: a kit hook registered with the $HOME path spelling (the foreign/converted
# form) + a USER hook that shares the basename but lives in a DIFFERENT dir.
cat > "$DIR/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/prof/hooks/harness-pointer.sh"}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/myhooks/harness-pointer.sh"}]}
]}}
JSON

CT_CONFIG_DIR="$DIR" CT_ADDITIONS="harness-pointer" HOME="$SB" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB/log" 2>&1
assert_eq "--apply exits 0" "0" "$?"
S="$DIR/settings.json"
assert_ok "settings.json still valid JSON" jq -e . "$S"

# A: the $HOME-spelled kit reg is GONE; exactly one OTHER (canonical) kit reg remains;
#    total harness-pointer regs == 2 (kit canonical + the user's own — no duplicate).
assert_ok "the foreign \$HOME-spelled kit reg was pruned" \
  bash -c "jq -e '[.hooks.PreToolUse[]|select(.hooks[].command==\"\$HOME/prof/hooks/harness-pointer.sh\")]|length==0' '$S' >/dev/null"
assert_ok "exactly one canonical kit reg remains (neither the foreign nor the user form)" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command|select(test(\"harness-pointer\"))|select(.!=\"\$HOME/prof/hooks/harness-pointer.sh\" and .!=\"\$HOME/myhooks/harness-pointer.sh\")]|length==1' '$S' >/dev/null"
assert_ok "no kit-hook duplicate: 2 harness-pointer regs total (kit + user, not 3)" \
  bash -c "jq -e '[.hooks.PreToolUse[]|select(.hooks[].command|test(\"harness-pointer\"))]|length==2' '$S' >/dev/null"

# B: the user's same-basename hook at a DIFFERENT path is preserved.
assert_ok "user hook (\$HOME/myhooks/...) with the same basename is PRESERVED" \
  bash -c "jq -e '[.hooks.PreToolUse[]|select(.hooks[].command==\"\$HOME/myhooks/harness-pointer.sh\")]|length==1' '$S' >/dev/null"

# C: idempotent — re-apply keeps exactly one canonical kit reg + the user hook.
CT_CONFIG_DIR="$DIR" CT_ADDITIONS="harness-pointer" HOME="$SB" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB/log2" 2>&1
assert_ok "re-apply keeps exactly ONE canonical kit reg (idempotent)" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command|select(test(\"harness-pointer\"))|select(.!=\"\$HOME/prof/hooks/harness-pointer.sh\" and .!=\"\$HOME/myhooks/harness-pointer.sh\")]|length==1' '$S' >/dev/null"
assert_ok "re-apply: still 2 harness-pointer regs total (no re-introduced dup)" \
  bash -c "jq -e '[.hooks.PreToolUse[]|select(.hooks[].command|test(\"harness-pointer\"))]|length==2' '$S' >/dev/null"

# ── D. multi-token (bun-prefixed) command-guard reg dedups too, even if the foreign
#    reg used a DIFFERENT bun path — tfile compares the /hooks/ token, not the prefix. ──
SB2="$(sandbox)"; export HOME="$SB2"; D2="$SB2/cgp"; mkdir -p "$D2/hooks"
if command -v bun >/dev/null 2>&1; then
  BUN="$(command -v bun)"
  # foreign reg: SAME bun, $HOME spelling (un-quoted dir) — normalizes byte-equal to the
  # kit's single-quoted absolute form, so it is a pure spelling-dup and must collapse.
  jq -n --arg c "$BUN \$HOME/cgp/hooks/command-guard.ts" \
    '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c}]}]}}' > "$D2/settings.json"
  CT_CONFIG_DIR="$D2" CT_ADDITIONS="command-guard" HOME="$SB2" \
    bash "$INSTALL" --apply --no-auth-inherit >"$SB2/log" 2>&1
  assert_eq "command-guard --apply exits 0" "0" "$?"
  assert_ok "bun-prefixed command-guard spelling-dup (same bun, \$HOME form) collapsed to ONE" \
    bash -c "jq -e '[.hooks.PreToolUse[]|select(.hooks[].command|test(\"command-guard\"))]|length==1' '$D2/settings.json' >/dev/null"
else
  echo "  (skip command-guard dedup case — bun not present)"
fi

# ── D2. AUGMENTED kit invocation (same file, EXTRA flag) is PRESERVED — full-command
#    equality, not file identity. The memory-flagged over-prune class (install-merge
#    contract: union preserves user hook tweaks). ──
SBx="$(sandbox)"; export HOME="$SBx"; Dx="$SBx/prof"; mkdir -p "$Dx/hooks"
cat > "$Dx/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/prof/hooks/harness-pointer.sh --extra-flag"}]}
]}}
JSON
CT_CONFIG_DIR="$Dx" CT_ADDITIONS="harness-pointer" HOME="$SBx" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SBx/log" 2>&1
assert_eq "augmented-invocation --apply exits 0" "0" "$?"
assert_ok "user's AUGMENTED kit invocation (--extra-flag) is PRESERVED, not collapsed" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command]|index(\"\$HOME/prof/hooks/harness-pointer.sh --extra-flag\")!=null' '$Dx/settings.json' >/dev/null"
assert_ok "the kit's own canonical harness-pointer reg is ALSO present (added alongside)" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command|select(test(\"harness-pointer\"))]|length==2' '$Dx/settings.json' >/dev/null"

# ── E. PER-HOOK granularity: a kit-dup hook and a USER hook in the SAME entry object
#    → only the kit-dup hook is removed; the sibling user hook in that object survives. ──
SB3="$(sandbox)"; export HOME="$SB3"; D3="$SB3/prof"; mkdir -p "$D3/hooks"
cat > "$D3/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[
    {"type":"command","command":"$HOME/prof/hooks/harness-pointer.sh"},
    {"type":"command","command":"$HOME/prof/hooks/sibling-user-hook.sh"}
  ]}
]}}
JSON
CT_CONFIG_DIR="$D3" CT_ADDITIONS="harness-pointer" HOME="$SB3" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB3/log" 2>&1
assert_eq "mixed-object --apply exits 0" "0" "$?"
assert_ok "sibling user hook in the SAME entry object is PRESERVED (per-hook prune)" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command]|index(\"\$HOME/prof/hooks/sibling-user-hook.sh\")!=null' '$D3/settings.json' >/dev/null"
assert_ok "the kit-dup hook was removed from that object (no duplicate)" \
  bash -c "jq -e '[.hooks.PreToolUse[].hooks[].command]|map(select(.==\"\$HOME/prof/hooks/harness-pointer.sh\"))|length==0' '$D3/settings.json' >/dev/null"

# ── F. malformed .command (an object, not string/array): the dedup prune (tfiles) must
#    be type-robust and not abort --apply. (A separate, pre-existing pruner on the
#    deselect path emits a cosmetic jq warning on this exotic shape — out of PR-C scope,
#    tracked as its own hardening. Here we assert the install still succeeds + stays valid.)
SB4="$(sandbox)"; export HOME="$SB4"; D4="$SB4/prof"; mkdir -p "$D4/hooks"
cat > "$D4/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":{"oops":"object-not-string"}}]}
]},"permissions":{"deny":["Read(/keep/**)"]}}
JSON
CT_CONFIG_DIR="$D4" CT_ADDITIONS="harness-pointer" HOME="$SB4" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB4/log" 2>&1
assert_eq "malformed .command (object): --apply exits 0 (dedup prune does not crash)" "0" "$?"
assert_ok "settings.json still valid JSON after install" jq -e . "$D4/settings.json"

t_summary
