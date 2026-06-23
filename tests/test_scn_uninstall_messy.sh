#!/usr/bin/env bash
# Scenario T25 — UNINSTALL over a MESSY profile. A real-world profile drifts: some
# kit hooks have lost their managed marker (hand-edited / pre-marker era), random
# orphan hooks the kit never shipped sit in hooks/, and the user has their own
# unmarked hooks. A deselect/cleanup re-run must:
#   (1) remove kit-OWNED files for deselected additions (by additions.json manifest),
#       even when the on-disk hook lost its managed marker, and prune their regs;
#   (2) remove MARKED kit hooks the kit no longer ships (marker self-clean);
#   (3) PRESERVE the user's own unmarked hooks (file + registration);
#   (4) NEVER crash on orphan hooks the kit never shipped (no marker, not in manifest)
#       — leave them in place and exit 0.
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit; never touches a real
# ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_uninstall_messy:"

SB="$(sandbox)"; touch "$SB/.bashrc"; P="$SB/.claude-aka"
run() { CT_ADDITIONS="$1" SHELL=/bin/bash HOME="$SB" \
        bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# Verify the kit hooks this scenario relies on are actually shipped + have a hook
# file in additions.json. leak-guard + harness-pointer are both hook additions.
WG_HOOK="$(jq -r '.additions[]|select(.id=="leak-guard")|.hook' "$ADDITIONS")"
HP_HOOK="$(jq -r '.additions[]|select(.id=="harness-pointer")|.hook' "$ADDITIONS")"
assert_eq "fixture: leak-guard ships hooks/leak-guard.ts" "hooks/leak-guard.ts" "$WG_HOOK"
assert_eq "fixture: harness-pointer ships hooks/harness-pointer.sh" "hooks/harness-pointer.sh" "$HP_HOOK"

# ── (1) Install both kit hook additions (secure-settings gives a base settings.json).
run "secure-settings leak-guard harness-pointer"
assert_eq "initial install exits 0" "0" "$?"
assert_file "leak-guard hook deployed"      "$P/hooks/leak-guard.ts"
assert_file "harness-pointer hook deployed" "$P/hooks/harness-pointer.sh"
assert_lit  "deployed leak-guard carries managed marker" \
  "aka-claude-tools:managed-hook" "$P/hooks/leak-guard.ts"

# ── (2) Make the profile MESSY ───────────────────────────────────────────────
# (a) leak-guard LOSES its managed marker (hand-edited / pre-marker era), but stays
#     a kit-owned hook in the manifest. We'll deselect it below — it must still be
#     removed via the manifest-driven (by-path) cleanup, not the marker self-clean.
grep -v 'aka-claude-tools:managed-hook' "$P/hooks/leak-guard.ts" > "$P/hooks/leak-guard.ts.tmp" \
  && mv "$P/hooks/leak-guard.ts.tmp" "$P/hooks/leak-guard.ts"
assert_nlit "leak-guard marker stripped (messy fixture)" \
  "aka-claude-tools:managed-hook" "$P/hooks/leak-guard.ts"

# (b) An ORPHAN hook the kit never shipped: no marker, not in additions.json. The
#     cleanup must never touch or crash on it. Also register it in settings so we
#     can prove its registration survives too.
printf '#!/usr/bin/env bash\necho orphan\n' > "$P/hooks/orphan-cruft.sh"

# (c) The user's OWN unmarked hook — must be preserved (file + registration).
printf '#!/usr/bin/env bash\necho mine\n'   > "$P/hooks/my-hook.sh"

# (d) A MARKED kit hook the kit NO LONGER ships (renamed/retired) — marker self-clean
#     must remove it + prune its reg.
printf '#!/usr/bin/env bash\n# aka-claude-tools:managed-hook\necho stale\n' > "$P/hooks/old-kit.sh"

# Register the orphan, the user hook, and the stale marked hook in settings.json.
jq --arg o "$P/hooks/orphan-cruft.sh" --arg m "$P/hooks/my-hook.sh" --arg s "$P/hooks/old-kit.sh" \
   '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$o}]},
                          {matcher:"Bash",hooks:[{type:"command",command:$m}]},
                          {matcher:"Bash",hooks:[{type:"command",command:$s}]}]' \
   "$P/settings.json" > "$P/s.tmp" && mv "$P/s.tmp" "$P/settings.json"
assert_ok "messy settings.json still valid JSON pre-cleanup" jq -e . "$P/settings.json"

# ── (3) Cleanup re-run: DESELECT leak-guard (keep harness-pointer selected) ────
run "secure-settings harness-pointer"
rc=$?
assert_eq "messy cleanup re-run exits 0 (never crashes on orphans)" "0" "$rc"
assert_ok "settings.json still valid JSON after cleanup" jq -e . "$P/settings.json"

# (1) Deselected kit-owned hook removed EVEN THOUGH its marker was stripped.
[ -e "$P/hooks/leak-guard.ts" ] \
  && fail "deselected kit hook removed despite missing marker" "still present" \
  || pass "deselected kit hook removed despite missing marker"
assert_ok "deselected leak-guard registration pruned" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.ts\")) | not' '$P/settings.json' >/dev/null"

# (2) MARKED kit hook the kit no longer ships removed by marker self-clean.
[ -e "$P/hooks/old-kit.sh" ] \
  && fail "stale marked kit hook removed (self-clean)" "still present" \
  || pass "stale marked kit hook removed (self-clean)"
assert_ok "stale marked hook registration pruned" \
  bash -c "jq -e --arg s '$P/hooks/old-kit.sh' '[.hooks.PreToolUse[]?.hooks[].command] | index(\$s) == null' '$P/settings.json' >/dev/null"

# (3) User's own unmarked hook PRESERVED (file + registration untouched).
assert_file "unmarked user hook file preserved" "$P/hooks/my-hook.sh"
assert_ok "unmarked user hook registration preserved" \
  bash -c "jq -e --arg m '$P/hooks/my-hook.sh' '[.hooks.PreToolUse[]?.hooks[].command] | index(\$m) != null' '$P/settings.json' >/dev/null"

# (4) ORPHAN hook (no marker, not in manifest) PRESERVED — never removed/crashed on.
assert_file "orphan hook file preserved (not kit-owned, no marker)" "$P/hooks/orphan-cruft.sh"
assert_ok "orphan hook registration preserved" \
  bash -c "jq -e --arg o '$P/hooks/orphan-cruft.sh' '[.hooks.PreToolUse[]?.hooks[].command] | index(\$o) != null' '$P/settings.json' >/dev/null"

# Still-selected kit hook (harness-pointer) retained.
assert_file "still-selected harness-pointer hook retained" "$P/hooks/harness-pointer.sh"

t_summary
