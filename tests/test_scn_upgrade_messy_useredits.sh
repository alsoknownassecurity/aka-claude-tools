#!/usr/bin/env bash
# Upgrade over a MESSY, hand-edited profile (T19) — the real-world upgrade where a
# user has been living in their profile and has:
#   (a) hand-edited a MANAGED kit file (changed leak-guard.sh's body),
#   (b) added their OWN permission rules (a deny + an allow the kit never ships),
#   (c) added their OWN hook (an unmarked hook file + its settings registration),
#   (d) TWEAKED a kit hook's registration (changed leak-guard's matcher).
# Re-running the installer (a plain layered re-run, which re-places kit-managed
# FILES at the current version) must:
#   • UNION the user's perms/hooks — never drop them,
#   • RESTORE the managed kit file to the kit version (user's body edit reverted),
#   • re-add the kit's CANONICAL hook registration,
#   • leave the user's non-kit additions intact.
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit. Never touches a
# real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_messy_useredits:"

SB="$(sandbox)"; touch "$SB/.bashrc"; P="$SB/.claude-aka"

# Deterministic recommended subset that needs no optional runtime (bun/rtk/
# trufflehog): leak-guard ships a marked kit hook + a registration we can tweak;
# secure-settings ships kit denies we can union against the user's own.
SEL="secure-settings leak-guard"
run() { CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB" \
        bash "$REPO_ROOT/install.sh" "$@" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# ── (1) clean baseline install ────────────────────────────────────────────────
run; assert_eq "baseline install exits 0" "0" "$?"
assert_file "kit hook present after baseline" "$P/hooks/leak-guard.sh"
S="$P/settings.json"

# A representative kit deny the baseline shipped (used later to prove kit rules
# stay adopted after the messy upgrade).
KIT_DENY="$(jq -r '.permissions.deny[0]' "$REPO_ROOT/config/settings.base.json")"
assert_ok "baseline adopted a kit deny" \
  bash -c "jq -e --arg r '$KIT_DENY' '.permissions.deny | index(\$r) != null' '$S' >/dev/null"

# ── (2) make the profile MESSY (simulate a user who has been living in it) ─────
# (a) hand-edit the MANAGED kit file — corrupt its body. The managed marker stays
#     (a real user editing the script keeps the comment), so this is the kit's
#     own file with user damage, which a re-run must overwrite with the kit version
#     (place_file re-places every kit hook on each run).
HAND_EDIT_SENTINEL="### USER HAND EDIT — should be reverted by upgrade"
printf '%s\n' "$HAND_EDIT_SENTINEL" >> "$P/hooks/leak-guard.sh"
assert_lit "managed marker still on the edited kit file" \
  "aka-claude-tools:managed-hook" "$P/hooks/leak-guard.sh"

# (b) user's OWN permission rules (a deny + an allow the kit NEVER ships, and not
#     in managed-permissions retired) — reconciliation must leave both untouched.
U_DENY='Read(//Users/me/private/**)'
U_ALLOW='Bash(mytool:*)'

# (c) user's OWN hook — an UNMARKED file + its registration.
U_HOOK="$P/hooks/my-own-hook.sh"
printf '#!/usr/bin/env bash\necho USER_OWN_HOOK\n' > "$U_HOOK"
chmod +x "$U_HOOK"

# (d) TWEAK the kit leak-guard registration: change its matcher to a custom one.
#     A user who edited their settings.json to scope the guard differently.
WG="$P/hooks/leak-guard.sh"
TWEAKED_MATCHER="WebFetch"   # not the kit's "WebSearch|WebFetch" / "Bash"
jq --arg wg "$WG" --arg uh "$U_HOOK" \
   --arg ud "$U_DENY" --arg ua "$U_ALLOW" --arg tm "$TWEAKED_MATCHER" '
     .permissions.deny  = ((.permissions.deny  // []) + [$ud]) |
     .permissions.allow = ((.permissions.allow // []) + [$ua]) |
     # drop the kit leak-guard registrations, replace with ONE tweaked-matcher reg
     .hooks.PreToolUse = ([ .hooks.PreToolUse[]
        | select((.hooks // [] | map(.command) | any(. == $wg)) | not) ]
        + [ {matcher:$tm, hooks:[{type:"command", command:$wg}]},
            {matcher:"Bash", hooks:[{type:"command", command:$uh}]} ])
   ' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
assert_ok "messy settings still valid JSON" jq -e . "$S"

# ── (3) re-run the installer (layers in place, re-placing kit files) ──────────
run; rc=$?
assert_eq "messy upgrade exits 0" "0" "$rc"
assert_ok "settings.json still valid JSON after upgrade" jq -e . "$S"

# Layer-in-place: nothing is moved, so NO timestamped backup is created (that was
# the retired --clean rebuild path). The kit files are refreshed via place_file.
n_bak=$(find "$SB" -maxdepth 1 -type d -name '.claude-aka.backup-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no rebuild backup (layered in place)" "0" "$n_bak"

# ── (4) ASSERTIONS ────────────────────────────────────────────────────────────

# (a) the MANAGED kit file is RESTORED to the kit version — user's body edit gone.
assert_file "managed kit file present after upgrade" "$P/hooks/leak-guard.sh"
assert_nlit "user's hand-edit to the managed kit file was reverted" \
  "$HAND_EDIT_SENTINEL" "$P/hooks/leak-guard.sh"
# It matches the shipped kit file byte-for-byte (true "restored to kit version").
if diff -q "$REPO_ROOT/config/hooks/leak-guard.sh" "$P/hooks/leak-guard.sh" >/dev/null 2>&1; then
  pass "managed kit file is byte-identical to the kit version"
else
  fail "managed kit file is byte-identical to the kit version" "profile copy differs from config/hooks/leak-guard.sh"
fi

# (b) the user's OWN permission rules survive (UNION, never dropped).
assert_ok "user deny preserved through messy upgrade" \
  bash -c "jq -e --arg r '$U_DENY' '.permissions.deny | index(\$r) != null' '$S' >/dev/null"
assert_ok "user allow preserved through messy upgrade" \
  bash -c "jq -e --arg r '$U_ALLOW' '.permissions.allow | index(\$r) != null' '$S' >/dev/null"

# kit denies stay adopted alongside the user's (the union added kit rules back).
assert_ok "kit deny still adopted after upgrade" \
  bash -c "jq -e --arg r '$KIT_DENY' '.permissions.deny | index(\$r) != null' '$S' >/dev/null"

# (c) the user's OWN (unmarked, non-kit) hook survives — file AND registration.
assert_file "user's own unmarked hook file kept" "$U_HOOK"
assert_ok "user's own hook registration kept" \
  bash -c "jq -e --arg h '$U_HOOK' '[.hooks.PreToolUse[]?.hooks[].command] | index(\$h) != null' '$S' >/dev/null"

# (d) the kit's CANONICAL leak-guard registration is present after the upgrade —
#     the kit re-adds its proper matcher set so the guard actually fires. The kit
#     ships leak-guard under BOTH "WebSearch|WebFetch" and "Bash".
assert_ok "kit canonical leak-guard registration re-added (WebSearch|WebFetch + Bash)" \
  bash -c "jq -e '
     [ .hooks.PreToolUse[]
       | select((.hooks // [] | map(.command) | any(endswith(\"/leak-guard.sh\"))))
       | .matcher ] as \$m
     | (\$m | index(\"WebSearch|WebFetch\") != null) and (\$m | index(\"Bash\") != null)
   ' '$S' >/dev/null"

# No maintainer-only \$comment keys ever leak into the user's settings.
assert_ok "no \$comment keys in upgraded settings" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$S' >/dev/null"

# No duplicate PreToolUse registrations after the upgrade (the union must not
# leave both the user's tweaked leak-guard reg AND the kit's canonical one as
# redundant entries — that double-fires the guard).
n_tot=$(jq '.hooks.PreToolUse | length' "$S")
n_uniq=$(jq '.hooks.PreToolUse | unique_by(tojson) | length' "$S")
assert_eq "no duplicate PreToolUse registrations after upgrade" "$n_tot" "$n_uniq"

# DECISION (operator): a user-tweaked KIT-hook registration is left UNIONED, not
# reconciled. The kit re-adds its canonical pair (asserted above) AND the user's
# extra matcher is preserved. The guards are idempotent, so an overlapping matcher
# is harmless redundancy (the guard fires its same allow/block decision), not a
# defect — so we do NOT assert "exactly 2". The real invariant: the kit's canonical
# registration is present (above) and the user's own edit is preserved (union).
assert_ok "user's tweaked leak-guard matcher preserved through the upgrade (union, by design)" \
  bash -c "jq -e '[.hooks.PreToolUse[] | select(.hooks[].command | endswith(\"/leak-guard.sh\")) | .matcher] | index(\"WebFetch\") != null' '$S' >/dev/null"

t_summary
