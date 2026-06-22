#!/usr/bin/env bash
# Scenario — superseded kit-MATCHER migration on upgrade.
#
# When the kit BROADENS a hook's matcher across versions (leak-guard gained the SearXNG MCP
# surface: "WebSearch|WebFetch" -> "WebSearch|WebFetch|mcp__searxng__", #59) the hook FILE is
# unchanged, so the rename cleanup (AKA_LEGACY_HOOKS) doesn't apply, and the matcher-gated
# dedup (prune_hook_regs_resolving) reads the stale OLD-matcher reg as a deliberate user tweak
# and keeps it — leaving leak-guard registered under BOTH matchers (double-firing on the web
# tools). The upgrade now prunes the stale KIT reg (matcher == a known superseded default AND
# command resolves to a kit hook file) before the merge re-adds the current one, while:
#   • a GENUINE user matcher tweak (any matcher NOT in the superseded set) is preserved;
#   • a user's OWN hook sharing the superseded matcher group is preserved (per-hook prune);
#   • a same-named hook under a DIFFERENT path (not this profile's) is never touched.
#
# Fully sandboxed: fake $HOME, --no-auth-inherit, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_matcher_migration:"

INSTALL="$REPO_ROOT/install.sh"

# n_lg <settings-file> → number of leak-guard.sh registrations (across all groups)
n_lg() { jq '[.hooks.PreToolUse[]?|.hooks[]?|select((.command|type)=="string" and (.command|test("leak-guard")))]|length' "$1"; }
# matcher of the group registering leak-guard.sh at THIS profile (the kit's canonical reg)
lg_matchers() { jq -r --arg c "$1" '[.hooks.PreToolUse[]?|select(.hooks[]?|(.command|type)=="string" and (.command|test("leak-guard")) and (.command|test($c)))|.matcher]|sort|join(",")' "$2"; }

# ── 1. the core fix: a stale superseded-matcher reg is collapsed to ONE current reg ──
SB="$(sandbox)"; export HOME="$SB"; CFG="$SB/prof"; mkdir -p "$CFG/hooks"
cp "$REPO_ROOT/config/hooks/leak-guard.sh" "$CFG/hooks/leak-guard.sh"
cat > "$CFG/settings.json" <<JSON
{"hooks":{"PreToolUse":[
  {"matcher":"WebSearch|WebFetch","hooks":[{"type":"command","command":"$CFG/hooks/leak-guard.sh"}]}
]}}
JSON
CT_CONFIG_DIR="$CFG" CT_ADDITIONS="leak-guard" HOME="$SB" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB/log" 2>&1
assert_eq "upgrade --apply exits 0" "0" "$?"
assert_ok "settings.json still valid JSON" jq -e . "$CFG/settings.json"
assert_eq "exactly ONE leak-guard reg after upgrade (no double-fire)" "1" "$(n_lg "$CFG/settings.json")"
assert_eq "the surviving reg carries the CURRENT (broadened) matcher" \
  "WebSearch|WebFetch|mcp__searxng__" "$(jq -r '[.hooks.PreToolUse[]?|select(.hooks[]?.command|test("leak-guard"))|.matcher][0]' "$CFG/settings.json")"
assert_nlit "the stale bare WebSearch|WebFetch leak-guard group is gone" \
  '"matcher":"WebSearch|WebFetch","hooks"' "$CFG/settings.json"
# idempotent: a second apply does not re-introduce a duplicate
CT_CONFIG_DIR="$CFG" CT_ADDITIONS="leak-guard" HOME="$SB" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB/log2" 2>&1
assert_eq "second --apply still exactly ONE leak-guard reg (idempotent)" "1" "$(n_lg "$CFG/settings.json")"

# ── 2. a GENUINE user matcher tweak (not the superseded default) is PRESERVED ──
SB2="$(sandbox)"; export HOME="$SB2"; CFG2="$SB2/prof"; mkdir -p "$CFG2/hooks"
cp "$REPO_ROOT/config/hooks/leak-guard.sh" "$CFG2/hooks/leak-guard.sh"
cat > "$CFG2/settings.json" <<JSON
{"hooks":{"PreToolUse":[
  {"matcher":"WebFetch","hooks":[{"type":"command","command":"$CFG2/hooks/leak-guard.sh"}]}
]}}
JSON
CT_CONFIG_DIR="$CFG2" CT_ADDITIONS="leak-guard" HOME="$SB2" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB2/log" 2>&1
assert_eq "user-tweak --apply exits 0" "0" "$?"
assert_ok "the user's re-scoped matcher (WebFetch) survives the upgrade" \
  bash -c "jq -e '[.hooks.PreToolUse[]?|select(.matcher==\"WebFetch\")]|length==1' '$CFG2/settings.json' >/dev/null"
assert_ok "the user-tweak reg still points at the profile's leak-guard.sh" \
  bash -c "jq -e '[.hooks.PreToolUse[]?|select(.matcher==\"WebFetch\")|.hooks[]?.command|select(test(\"leak-guard\"))]|length==1' '$CFG2/settings.json' >/dev/null"

# ── 3. a user's OWN hook in the superseded matcher group is KEPT (per-hook prune) ──
SB3="$(sandbox)"; export HOME="$SB3"; CFG3="$SB3/prof"; mkdir -p "$CFG3/hooks"
cp "$REPO_ROOT/config/hooks/leak-guard.sh" "$CFG3/hooks/leak-guard.sh"
printf '#!/bin/sh\necho mine\n' > "$CFG3/hooks/my-own.sh"
cat > "$CFG3/settings.json" <<JSON
{"hooks":{"PreToolUse":[
  {"matcher":"WebSearch|WebFetch","hooks":[
    {"type":"command","command":"$CFG3/hooks/leak-guard.sh"},
    {"type":"command","command":"$CFG3/hooks/my-own.sh"}
  ]}
]}}
JSON
CT_CONFIG_DIR="$CFG3" CT_ADDITIONS="leak-guard" HOME="$SB3" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB3/log" 2>&1
assert_eq "sibling-case --apply exits 0" "0" "$?"
assert_lit "the user's own my-own.sh hook is preserved" "my-own.sh" "$CFG3/settings.json"
assert_ok "my-own.sh remains under the WebSearch|WebFetch group it was in" \
  bash -c "jq -e '[.hooks.PreToolUse[]?|select(.matcher==\"WebSearch|WebFetch\")|.hooks[]?.command|select(test(\"my-own\"))]|length==1' '$CFG3/settings.json' >/dev/null"
assert_eq "exactly ONE leak-guard reg (the stale kit hook was pruned from the group)" "1" "$(n_lg "$CFG3/settings.json")"

# ── 4. a same-named hook under a DIFFERENT path (not kit-owned) is NOT touched ──
SB4="$(sandbox)"; export HOME="$SB4"; CFG4="$SB4/prof"; mkdir -p "$CFG4/hooks"
cp "$REPO_ROOT/config/hooks/leak-guard.sh" "$CFG4/hooks/leak-guard.sh"
cat > "$CFG4/settings.json" <<JSON
{"hooks":{"PreToolUse":[
  {"matcher":"WebSearch|WebFetch","hooks":[{"type":"command","command":"/elsewhere/hooks/leak-guard.sh"}]}
]}}
JSON
CT_CONFIG_DIR="$CFG4" CT_ADDITIONS="leak-guard" HOME="$SB4" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB4/log" 2>&1
assert_eq "diff-path --apply exits 0" "0" "$?"
assert_lit "a superseded-matcher reg pointing ELSEWHERE is left untouched" \
  "/elsewhere/hooks/leak-guard.sh" "$CFG4/settings.json"

# ── 5. equivalent path SPELLINGS of the stale reg are ALL collapsed (the prune reuses
#    prune_hook_regs_resolving's full normalizer — $HOME / $CLAUDE_CONFIG_DIR / both quote
#    forms — so a stale reg written in any of them is caught, not just the kit's canonical
#    single-quoted absolute form). And an AUGMENTED user invocation under the old matcher is
#    PRESERVED (full-command equality, not a suffix match) — the anti-criterion.
spell_case() {  # <desc> <existing-cmd-with-@CFG@/@HOME@> <expect-count>
  local sb cfg; sb="$(sandbox)"; cfg="$sb/prof"; mkdir -p "$cfg/hooks"
  cp "$REPO_ROOT/config/hooks/leak-guard.sh" "$cfg/hooks/leak-guard.sh"
  local cmd; cmd="$(printf '%s' "$2" | sed "s#@CFG@#$cfg#g")"
  jq -n --arg c "$cmd" '{hooks:{PreToolUse:[{matcher:"WebSearch|WebFetch",hooks:[{type:"command",command:$c}]}]}}' > "$cfg/settings.json"
  CT_CONFIG_DIR="$cfg" CT_ADDITIONS="leak-guard" HOME="$sb" \
    bash "$INSTALL" --apply --no-auth-inherit >"$sb/log" 2>&1
  assert_eq "$1: --apply exits 0" "0" "$?"
  assert_eq "$1: leak-guard reg count" "$3" "$(n_lg "$cfg/settings.json")"
}
spell_case "stale reg in \$HOME spelling collapses"            '$HOME/prof/hooks/leak-guard.sh' 1
spell_case "stale reg in \$CLAUDE_CONFIG_DIR spelling collapses" '$CLAUDE_CONFIG_DIR/hooks/leak-guard.sh' 1
spell_case "stale reg double-quoted collapses"                 '"@CFG@/hooks/leak-guard.sh"' 1
spell_case "AUGMENTED invocation under old matcher PRESERVED (kit + user = 2)" 'bash @CFG@/hooks/leak-guard.sh --extra' 2

# ── 5b. build_superseded_add is a pure transform: it maps the kit add onto the superseded
#    matcher(s), and yields {} when the add registers nothing superseded. ──
real_add='{"hooks":{"PreToolUse":[{"matcher":"WebSearch|WebFetch|mcp__searxng__","hooks":[{"type":"command","command":"'"$CFG"'/hooks/leak-guard.sh"}]}]}}'
syn="$( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1; build_superseded_add "$real_add" )"
assert_eq "build_superseded_add maps the kit reg onto the SUPERSEDED matcher" \
  "WebSearch|WebFetch" "$(printf '%s' "$syn" | jq -r '.hooks.PreToolUse[0].matcher')"
assert_eq "build_superseded_add carries the SAME command the kit registers" \
  "$CFG/hooks/leak-guard.sh" "$(printf '%s' "$syn" | jq -r '.hooks.PreToolUse[0].hooks[0].command')"
nonsup='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"'"$CFG"'/hooks/command-guard.ts"}]}]}}'
assert_eq "build_superseded_add yields {} when the add has no superseded hook" \
  "{}" "$( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1; build_superseded_add "$nonsup" )"
# selector is `contains` (not endswith): a kit command with an interpreter prefix / trailing
# args is still selected (selector-only; equality remains the gate).
trail='{"hooks":{"PreToolUse":[{"matcher":"WebSearch|WebFetch|mcp__searxng__","hooks":[{"type":"command","command":"bun '"$CFG"'/hooks/leak-guard.sh --flag"}]}]}}'
assert_eq "build_superseded_add selects a command with a prefix + trailing args" \
  "WebSearch|WebFetch" "$( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1; build_superseded_add "$trail" | jq -r '.hooks.PreToolUse[0].matcher // "NONE"')"

# ── 7. conservative boundary + robustness probes (from cold review) ──
# (a) command-also-changed across versions: equality fails → stale reg NOT pruned here (the
#     file-rename path AKA_LEGACY_HOOKS owns a command/file rename). No crash; new reg added.
SB7="$(sandbox)"; export HOME="$SB7"; CFG7="$SB7/prof"; mkdir -p "$CFG7/hooks"
cp "$REPO_ROOT/config/hooks/leak-guard.sh" "$CFG7/hooks/leak-guard.sh"
cat > "$CFG7/settings.json" <<JSON
{"hooks":{"PreToolUse":[{"matcher":"WebSearch|WebFetch","hooks":[{"type":"command","command":"$CFG7/hooks/OLD-DIFFERENT-NAME.sh"}]}]}}
JSON
CT_CONFIG_DIR="$CFG7" CT_ADDITIONS="leak-guard" HOME="$SB7" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB7/log" 2>&1
assert_eq "cmd-also-changed: --apply exits 0" "0" "$?"
assert_lit "cmd-also-changed: the old-command reg is conservatively left (no over-prune)" \
  "OLD-DIFFERENT-NAME.sh" "$CFG7/settings.json"
# (b) a malformed object .command present under the superseded matcher must not crash the path.
SB8="$(sandbox)"; export HOME="$SB8"; CFG8="$SB8/prof"; mkdir -p "$CFG8/hooks"
cp "$REPO_ROOT/config/hooks/leak-guard.sh" "$CFG8/hooks/leak-guard.sh"
cat > "$CFG8/settings.json" <<JSON
{"hooks":{"PreToolUse":[
  {"matcher":"WebSearch|WebFetch","hooks":[{"type":"command","command":{"obj":1}}]},
  {"matcher":"WebSearch|WebFetch","hooks":[{"type":"command","command":"$CFG8/hooks/leak-guard.sh"}]}
]}}
JSON
CT_CONFIG_DIR="$CFG8" CT_ADDITIONS="leak-guard" HOME="$SB8" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB8/log" 2>&1
assert_eq "malformed-.command present: --apply exits 0 (no crash)" "0" "$?"
assert_ok "malformed-.command present: settings.json still valid JSON" jq -e . "$CFG8/settings.json"
assert_eq "malformed-.command present: the genuine stale leak-guard reg still collapsed to ONE" \
  "1" "$(n_lg "$CFG8/settings.json")"
# (c) a matcher group whose inner .hooks is a NON-ARRAY scalar must not abort the upgrade —
#     the 4d-pre3b/4d-pre4 pruner now guards a non-array .hooks (was: Cannot iterate over string).
SB9="$(sandbox)"; export HOME="$SB9"; CFG9="$SB9/prof"; mkdir -p "$CFG9/hooks"
cp "$REPO_ROOT/config/hooks/leak-guard.sh" "$CFG9/hooks/leak-guard.sh"
cat > "$CFG9/settings.json" <<JSON
{"hooks":{"PreToolUse":[
  {"matcher":"WebSearch|WebFetch","hooks":"oops-not-an-array"},
  {"matcher":"WebSearch|WebFetch","hooks":[{"type":"command","command":"$CFG9/hooks/leak-guard.sh"}]}
]}}
JSON
CT_CONFIG_DIR="$CFG9" CT_ADDITIONS="leak-guard" HOME="$SB9" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB9/log" 2>&1
assert_eq "non-array inner .hooks present: --apply exits 0 (no jq iterate-over-string crash)" "0" "$?"
assert_ok "non-array inner .hooks present: settings.json still valid JSON" jq -e . "$CFG9/settings.json"
assert_eq "non-array inner .hooks present: genuine stale leak-guard reg still collapsed to ONE" \
  "1" "$(n_lg "$CFG9/settings.json")"

# ── 6. SUBSET INVARIANT (security guarantee): every AKA_SUPERSEDED_MATCHERS entry must be
#    SUBSUMED by the current kit matcher for that hook in additions.json. If a future entry
#    NARROWS coverage (the superseded matcher has a tool the current one lacks), pruning the
#    stale reg would silently drop egress scanning — exactly what this test forbids. For each
#    entry: a current matcher must exist for the hook AND superseded-tools ⊆ current-tools.
SUP="$( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1; printf '%s' "$AKA_SUPERSEDED_MATCHERS" )"
inv="$(printf '%s' "$SUP" | jq -c --slurpfile add "$REPO_ROOT/config/additions.json" '
  [ .[] as $s
    | ($add[0].additions[] | select((.hook // "" | split("/") | last) == $s.hook) | .matcher) as $cur
    | { hook:$s.hook,
        has_current: ($cur != null),
        subset: (($cur != null) and (($s.matcher | split("|")) - ($cur // "" | split("|")) | length == 0)) } ]')"
assert_eq "every superseded entry has a live additions.json matcher" \
  "true" "$(printf '%s' "$inv" | jq -r 'all(.has_current)')"
assert_eq "every superseded matcher is SUBSUMED by the current kit matcher (no coverage loss)" \
  "true" "$(printf '%s' "$inv" | jq -r 'all(.subset)')"

t_summary
