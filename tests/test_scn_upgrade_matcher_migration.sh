#!/usr/bin/env bash
# Scenario — superseded kit-MATCHER migration machinery (AKA_SUPERSEDED_MATCHERS).
#
# The kit can BROADEN a hook's MATCHER across versions while leaving the hook FILE unchanged.
# When that happens the file-rename cleanup (AKA_LEGACY_HOOKS / the marker self-clean) doesn't
# apply, and the matcher-gated dedup (prune_hook_regs_resolving) would read the stale OLD-matcher
# reg as a deliberate user tweak and keep it — leaving the guard registered under BOTH matchers
# (double-firing). build_superseded_add + AKA_SUPERSEDED_MATCHERS prune that stale KIT reg before
# the merge re-adds the current one, while a genuine user matcher tweak is preserved.
#
# AKA_SUPERSEDED_MATCHERS is CURRENTLY EMPTY (the one historical entry — leak-guard's SearXNG
# broadening — was subsumed by the leak-guard.sh→leak-guard.ts FILE rename, which the marker
# self-clean handles by basename; see common.sh and test_scn_upgrade_leakguard_ts.sh). So this
# test pins:
#   • the SUBSET INVARIANT (security guarantee) holds for the live (empty) set;
#   • build_superseded_add remains a correct GENERIC transform, exercised with a SYNTHETIC entry
#     so the machinery is proven independent of whether any hook currently has a live entry.
#
# Fully sandboxed: fake $HOME, --no-auth-inherit, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_matcher_migration:"

# ── 1. SUBSET INVARIANT (security guarantee): every AKA_SUPERSEDED_MATCHERS entry must be
#    SUBSUMED by the current kit matcher for that hook in additions.json. If a future entry
#    NARROWS coverage (the superseded matcher has a tool the current one lacks), pruning the
#    stale reg would silently drop egress scanning — exactly what this test forbids. Trivially
#    holds for the empty set; the assertions stay live so a future entry is checked. ──
SUP="$( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1; printf '%s' "$AKA_SUPERSEDED_MATCHERS" )"
assert_eq "AKA_SUPERSEDED_MATCHERS is valid JSON array" "array" "$(printf '%s' "$SUP" | jq -r 'type')"
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

# ── 2. build_superseded_add is a pure transform — proven GENERICALLY with a synthetic entry,
#    so the machinery is correct regardless of the live (currently empty) set. We invoke the
#    function with a temporarily-overridden AKA_SUPERSEDED_MATCHERS in the SAME subshell. ──
SB="$(sandbox)"; CFG="$SB/prof"; mkdir -p "$CFG/hooks"

# A real kit add for a HYPOTHETICAL future hook (gizmo.ts) whose matcher broadened
# "Foo" → "Foo|Bar"; the synthetic entry lists the superseded "Foo".
real_add="$(jq -nc --arg c "$CFG/hooks/gizmo.ts" '{hooks:{PreToolUse:[{matcher:"Foo|Bar",hooks:[{type:"command",command:$c}]}]}}')"
syn="$( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1
        AKA_SUPERSEDED_MATCHERS='[{"hook":"gizmo.ts","matcher":"Foo"}]'
        build_superseded_add "$real_add" )"
assert_eq "build_superseded_add maps the kit reg onto the SUPERSEDED matcher" \
  "Foo" "$(printf '%s' "$syn" | jq -r '.hooks.PreToolUse[0].matcher')"
assert_eq "build_superseded_add carries the SAME command the kit registers" \
  "$CFG/hooks/gizmo.ts" "$(printf '%s' "$syn" | jq -r '.hooks.PreToolUse[0].hooks[0].command')"

# selector is `contains` (not endswith): a kit command with an interpreter prefix / trailing
# args is still selected (selector-only; the full-command equality in the pruner is the gate).
trail="$(jq -nc --arg c "bun $CFG/hooks/gizmo.ts --flag" '{hooks:{PreToolUse:[{matcher:"Foo|Bar",hooks:[{type:"command",command:$c}]}]}}')"
assert_eq "build_superseded_add selects a command with a prefix + trailing args" \
  "Foo" "$( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1
            AKA_SUPERSEDED_MATCHERS='[{"hook":"gizmo.ts","matcher":"Foo"}]'
            build_superseded_add "$trail" | jq -r '.hooks.PreToolUse[0].matcher // "NONE"')"

# yields {} when the add registers nothing the (synthetic) superseded set names.
nonsup="$(jq -nc --arg c "$CFG/hooks/command-guard.ts" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$c}]}]}}')"
assert_eq "build_superseded_add yields {} when the add has no superseded hook" \
  "{}" "$( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1
           AKA_SUPERSEDED_MATCHERS='[{"hook":"gizmo.ts","matcher":"Foo"}]'
           build_superseded_add "$nonsup" )"

# with the LIVE (empty) set, ANY add yields {} (no entries to map onto).
assert_eq "build_superseded_add yields {} with the live empty set" \
  "{}" "$( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1; build_superseded_add "$real_add" )"

t_summary
