#!/usr/bin/env bash
# Unit tests for install.sh's pure helpers. install.sh is SOURCED (its entrypoint
# is source-guarded) inside a SUBSHELL so its top-level `set -euo`/traps/preflight
# stay contained and never corrupt the test shell. No install is performed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_helpers:"

# Run a helper in a sourced subshell. stdin (for the prune helpers) is inherited;
# only the helper's stdout is returned (the source's banner is silenced).
src() { ( source "$REPO_ROOT/install.sh" >/dev/null 2>&1; "$@" ); }
jqe() { printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }   # quiet jq predicate

# ── merge_settings: deep-merge, UNION permission + hook arrays, strip $comment ──
E='{"permissions":{"deny":["Read(~/a)"],"allow":["Bash(x)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"user.sh"}]}]},"model":"opus"}'
A='{"permissions":{"deny":["Read(~/b)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"kit.sh"}]}]},"$comment":["maintainer note"]}'
M="$(src merge_settings "$E" "$A")"

assert_ok "merge output is valid JSON"            jqe "$M" '.'
assert_ok "deny is the UNION of both inputs"      jqe "$M" '.permissions.deny | (index("Read(~/a)")!=null) and (index("Read(~/b)")!=null)'
assert_ok "user allow preserved through merge"    jqe "$M" '.permissions.allow | index("Bash(x)")!=null'
assert_ok "hook arrays unioned (both commands)"   jqe "$M" '[.hooks.PreToolUse[].hooks[].command] | (index("user.sh")!=null) and (index("kit.sh")!=null)'
assert_ok "scalar deep-merge keeps existing key"  jqe "$M" '.model == "opus"'
assert_ok "\$comment stripped from merged result" jqe "$M" 'has("$comment") | not'

# Idempotent union: re-merging the same additions doesn't grow the deny array.
M2="$(src merge_settings "$M" "$A")"
n1="$(printf %s "$M"  | jq '.permissions.deny | length')"
n2="$(printf %s "$M2" | jq '.permissions.deny | length')"
assert_eq "re-merging same additions is idempotent (deny count stable)" "$n1" "$n2"

# ── prune_hook_regs: remove a kit hook by basename, leave the user's own ──────
S='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/p/hooks/leak-guard.sh"}]},{"matcher":"Bash","hooks":[{"type":"command","command":"echo USER"}]}]}}'
P="$(printf %s "$S" | src prune_hook_regs leak-guard.sh)"
assert_ok "prune removed the targeted kit hook"     jqe "$P" '[.hooks.PreToolUse[]?.hooks[].command] | index("/p/hooks/leak-guard.sh") == null'
assert_ok "prune left the user's own hook untouched" jqe "$P" '[.hooks.PreToolUse[]?.hooks[].command] | index("echo USER") != null'

# Pruning the only hook drops the now-empty PreToolUse event entirely.
SONLY='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/p/hooks/leak-guard.sh"}]}]}}'
PONLY="$(printf %s "$SONLY" | src prune_hook_regs leak-guard.sh)"
assert_ok "pruning the last hook removes the empty event" jqe "$PONLY" '(.hooks // {}) == {}'

# ── prune_statusline: drop the kit statusLine by its EXACT quoted registered tail (EITHER
#    extension); keep everything else — a DIFFERENT dir with the same /hooks/statusline.ts
#    tail (#65), and a user command that passes the path as DATA (#67 review). ──
# Signature: prune_statusline <quoted-anchor-stem>, e.g. '/p'/hooks/statusline — the SAME
# shq(config_dir) the registration used. The matcher end-anchors VERBATIM (no quote-strip),
# so the surrounding quotes distinguish the kit's command from a data argument. mkc builds a
# {statusLine.command} fixture from a literal command string (single quotes stay literal in
# the double-quoted arg). STEM is config_dir=/p, so shq(/p)='/p'.
mkc() { jq -nc --arg c "$1" '{statusLine:{command:$c}}'; }
STEM="'/p'/hooks/statusline"
# Current kit shape: shq(bun) + space + shq(/p) + /hooks/statusline.ts.
PLBUN="$(mkc "'/usr/bin/bun' '/p'/hooks/statusline.ts" | src prune_statusline "$STEM")"
assert_ok "kit statusLine pruned (quoted bun .ts tail)" jqe "$PLBUN" 'has("statusLine") | not'
# A pre-port profile carries a quoted .sh command (no interpreter) in the SAME dir — the
# either-extension stem must prune it too (the upgrade-then-deselect path).
PLSH="$(mkc "'/p'/hooks/statusline.sh" | src prune_statusline "$STEM")"
assert_ok "residual quoted .sh statusLine pruned (either-extension stem)" jqe "$PLSH" 'has("statusLine") | not'
# A config dir WITH A SPACE registers a quoted dir token — the same-shape stem still matches.
PLSP="$(mkc "'/usr/bin/bun' '/My Cfg/.c'/hooks/statusline.ts" | src prune_statusline "'/My Cfg/.c'/hooks/statusline")"
assert_ok "kit statusLine in a space-containing dir pruned (#67)" jqe "$PLSP" 'has("statusLine") | not'
# An unrelated statusLine in a wholly different path is kept.
KEEP="$(mkc "/my/own.sh" | src prune_statusline "$STEM")"
assert_ok "unrelated statusLine kept (no tail match)" jqe "$KEEP" '.statusLine.command == "/my/own.sh"'
# #65: a user's OWN kit-style statusLine ending in /hooks/statusline.ts but in a DIFFERENT
# config dir must NOT be treated as the kit's (the old bare-tail matcher wrongly pruned it).
KEEP2="$(mkc "'/usr/bin/bun' '/opt/custom'/hooks/statusline.ts" | src prune_statusline "$STEM")"
assert_ok "user statusLine in a DIFFERENT dir kept (quoted-tail anchor, #65)" jqe "$KEEP2" '.statusLine | has("command")'
# #67-review (the critical cross-check finding): a user command that ends with the kit path
# only as a QUOTED DATA argument (`echo '\''/p/hooks/statusline.ts'\''`) must NOT match — its
# closing quote sits AFTER .ts, not before /hooks, so the verbatim tail differs. A quote-
# stripping matcher would have conflated the two and deleted this user's statusLine.
KEEP3="$(mkc "echo '/p/hooks/statusline.ts'" | src prune_statusline "$STEM")"
assert_ok "user statusLine passing the path as DATA kept (quotes not stripped)" jqe "$KEEP3" '.statusLine | has("command")'

# ── adversarial characterization — the merge/prune INVARIANTS that make the gnarly
#    jq safe to modify: a future edit that breaks any of these fails HERE. Asserted
#    as jq PREDICATES (semantic), never byte-snapshots — so jq-version number/format
#    drift can't flap them, and no latent bug is frozen as a "golden". (Seeds the
#    nasty classes the merge is known to be sensitive to: nested $comment, key-order
#    dedup, permission overlap, empty edges, array-valued commands.)

# (1) $comment is stripped RECURSIVELY, not just top-level — a note nested inside a
#     payload must never leak into the user's settings.
NESTED='{"hooks":{"PreToolUse":[{"matcher":"Bash","$comment":"mid","hooks":[{"type":"command","command":"kit.sh","$comment":"deep"}]}]},"$comment":"top"}'
MN="$(src merge_settings '{}' "$NESTED")"
assert_ok "\$comment stripped at EVERY depth (recursive)" \
  jqe "$MN" '[.. | objects | has("$comment")] | any | not'

# (2) Hook dedup is KEY-ORDER-INSENSITIVE: the same kit hook already present with its
#     object keys in a different order must NOT duplicate on merge (the canonicalizing
#     unique_by). Regression = a hook that fires twice and doubles each upgrade.
EH='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"command":"kit.sh","type":"command"}]}]}}'
AH='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"kit.sh"}]}]}}'
MH="$(src merge_settings "$EH" "$AH")"
assert_ok "key-order-insensitive hook dedup (no duplicate)" \
  jqe "$MH" '[.hooks.PreToolUse[].hooks[] | select(.command=="kit.sh")] | length == 1'

# (3) Permission union DEDUPS overlap across both inputs.
MP="$(src merge_settings '{"permissions":{"deny":["Read(~/x)","Read(~/y)"]}}' '{"permissions":{"deny":["Read(~/y)","Read(~/z)"]}}')"
assert_ok "permission union dedups the overlap" \
  jqe "$MP" '.permissions.deny | (length==3) and (index("Read(~/y)")!=null)'

# (4) Empty/missing edges.
ME="$(src merge_settings '{}' "$A")"
assert_ok "empty existing → additions land (minus \$comment)" jqe "$ME" '(.permissions.deny|index("Read(~/b)")!=null) and (has("$comment")|not)'
MA="$(src merge_settings "$E" '{}')"
assert_ok "empty additions → existing preserved"             jqe "$MA" '(.model=="opus") and (.permissions.allow|index("Bash(x)")!=null)'

# (5) merge is idempotent on the WHOLE object (re-merge == first merge) — the
#     strongest safe-to-modify invariant. Compared semantically (jq -s deep-equal).
MII="$(src merge_settings "$M" "$A")"
if printf '%s\n%s' "$M" "$MII" | jq -s -e '.[0]==.[1]' >/dev/null 2>&1; then
  pass "merge is idempotent (re-merge equals first merge)"
else fail "merge is idempotent (re-merge equals first merge)" "re-merge drifted"; fi

# (6) prune_hook_regs TOLERATES a user hook whose .command is an ARRAY (a valid
#     shape) — must not crash, still prunes the kit hook, keeps the user's array hook.
SARR='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/p/hooks/leak-guard.sh"}]},{"matcher":"Edit","hooks":[{"type":"command","command":["my-tool","--run"]}]}]}}'
PARR="$(printf %s "$SARR" | src prune_hook_regs leak-guard.sh)"
assert_ok "prune tolerates an array-valued user .command (no crash, valid JSON)" jqe "$PARR" '.'
assert_ok "prune removed the kit hook past the array entry" \
  jqe "$PARR" '[.hooks.PreToolUse[]?.hooks[].command | select(type=="string")] | index("/p/hooks/leak-guard.sh") == null'
assert_ok "prune kept the user's array-command hook" \
  jqe "$PARR" '[.hooks.PreToolUse[]?.hooks[].command] | any(. == ["my-tool","--run"])'

# (7) prune is idempotent: pruning an already-pruned settings is a no-op.
PP="$(printf %s "$P" | src prune_hook_regs leak-guard.sh)"
if printf '%s\n%s' "$P" "$PP" | jq -s -e '.[0]==.[1]' >/dev/null 2>&1; then
  pass "prune is idempotent (second prune = no-op)"
else fail "prune is idempotent (second prune = no-op)" "second prune drifted"; fi

# (8) Scalar CONFLICT precedence — the UPGRADE CONTRACT. When existing and additions
#     set the SAME scalar to DIFFERENT values, additions (the kit) win ($e * $a): an
#     upgrade re-asserts the kit's value. A non-conflicting user key is kept. This is
#     the one most likely to flip SILENTLY: a refactor swapping operand order would
#     reverse kit-overrides-user and still pass every other test — this catches it.
MSC="$(src merge_settings '{"model":"opus","theme":"dark"}' '{"model":"sonnet"}')"
assert_ok "scalar conflict: additions (kit) win; non-conflicting user key kept" \
  jqe "$MSC" '(.model=="sonnet") and (.theme=="dark")'

t_summary
