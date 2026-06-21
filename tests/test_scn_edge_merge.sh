#!/usr/bin/env bash
# Settings-merge adversarial edges (upgrade path). Pins two CONFIRMED defects in
# the merge/prune jq, both rooted in assuming a hook entry is byte-canonical and
# its `.command` is always a string:
#
#  (A) unique_by(tojson) dedup is KEY-ORDER sensitive. If the existing
#      settings.json has the kit's hook entries with their object keys in a
#      different order (Claude Code / any JSON tool can rewrite key order), an
#      upgrade re-run re-adds the kit registration as a "new" entry — the hook
#      gets DUPLICATED and fires twice; each subsequent upgrade doubles again.
#
#  (B) prune_hook_regs uses `(.command // "") | contains($b)`. If ANY hook entry
#      in the user's settings has an array-valued `.command` (a valid shape), the
#      jq aborts (exit 5: "array and string cannot have their containment
#      checked"), so the prune is a silent no-op: deselecting a kit addition
#      FAILS to remove its hook — the security hook stays registered while the
#      installer reports success.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_edge_merge:"

# ── (A) key-order-insensitive dedup on upgrade ───────────────────────────────
SB="$(sandbox)"; touch "$SB/.bashrc"
SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="leak-guard" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/l1" 2>&1
PROFILE="$(ls -d "$SB"/.claude* 2>/dev/null | head -1)"
S="$PROFILE/settings.json"
assert_file "install placed settings.json" "$S"

n0="$(jq '[.hooks.PreToolUse[]?] | length' "$S" 2>/dev/null)"
assert_eq "leak-guard registered 2 hook entries on fresh install" "2" "$n0"

# Simulate the app/user rewriting the SAME entries with object keys reordered
# (semantically identical — every command string is unchanged).
jq '.hooks.PreToolUse |= map({hooks: .hooks, matcher: .matcher})' "$S" > "$S.t" && mv "$S.t" "$S"

# Upgrade in place with the SAME selection.
SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="leak-guard" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/l2" 2>&1

n1="$(jq '[.hooks.PreToolUse[]?] | length' "$S" 2>/dev/null)"
# CORRECT behavior: still 2 (semantically-equal entries deduped). BUG: 4.
assert_eq "upgrade must NOT duplicate kit hooks after a key-order rewrite" "2" "$n1"

# ── (B) prune survives an array-valued command in user settings ──────────────
SB2="$(sandbox)"; touch "$SB2/.bashrc"
SHELL=/bin/bash HOME="$SB2" CT_ADDITIONS="leak-guard" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB2/l1" 2>&1
P2="$(ls -d "$SB2"/.claude* 2>/dev/null | head -1)"
S2="$P2/settings.json"
assert_file "second install placed settings.json" "$S2"

# A user hook whose command is an ARRAY (a valid shape the kit must tolerate).
jq '.hooks.PreToolUse += [{"matcher":"Edit","hooks":[{"type":"command","command":["my-tool","--run"]}]}]' \
  "$S2" > "$S2.t" && mv "$S2.t" "$S2"

WG="$P2/hooks/leak-guard.sh"
assert_lit "leak-guard hook registered before deselect" "$WG" "$S2"

# Deselect everything (uninstall the kit additions in place).
SHELL=/bin/bash HOME="$SB2" CT_ADDITIONS="" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB2/l2" 2>&1

assert_ok "settings.json still valid JSON after deselect" jq -e . "$S2"
# The user's own array-command hook must survive.
assert_ok "user's array-command hook preserved" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.matcher] | index(\"Edit\") != null' '$S2' >/dev/null"
# BUG: prune_hook_regs aborts on the array command, so the kit hook is NOT removed.
assert_nlit "deselected leak-guard hook registration removed" "$WG" "$S2"

t_summary
