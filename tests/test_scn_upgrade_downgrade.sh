#!/usr/bin/env bash
# T22 — UPGRADE / edge: DOWNGRADE (run an OLDER kit over a profile built by a NEWER kit).
#
# The kit has NO version tracking: install.sh only knows the strings in THIS
# checkout's config (settings.base.json, managed-permissions.json .retired[] /
# .retiredAdditions[], additions.json manifest). So when an OLDER kit runs over a
# profile a NEWER kit produced, the older kit cannot recognise anything the newer
# kit introduced — neither newer permission rules nor newer additions nor newer
# retirements. The documented behaviour is therefore conservative:
#   • union merge NEVER removes a newer entry it doesn't ship/know-about,
#   • a newer addition's files the older kit's manifest doesn't list are not
#     touched (uninstall loop only sees ids in the manifest; retiredAdditions only
#     lists what the OLDER kit retired),
#   • the profile is not corrupted (settings stays valid JSON, the older kit's own
#     footprint still lands).
#
# We can't ship a literal older tarball in-tree, so we model the situation the way
# install.sh actually sees it: run THIS checkout's install.sh (the "older kit")
# over a profile pre-seeded with NEWER-kit artefacts — strings/paths chosen to be
# UNKNOWN to this checkout (absent from base, from .retired[], from .retiredAdditions,
# and from the additions manifest). That is exactly the input an older binary faces.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit, never touches a real
# ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_downgrade:"

MP="$REPO_ROOT/config/managed-permissions.json"
BASE="$REPO_ROOT/config/settings.base.json"

SB="$(sandbox)"; touch "$SB/.bashrc"
PROFILE="$SB/.claude-aka"
S="$PROFILE/settings.json"
run() { SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# ── 1. Build a profile with the current ("older") kit first ───────────────────
run
assert_eq "initial install (the profile baseline) exits 0" "0" "$?"
assert_file "settings.json created" "$S"

# ── 2. Layer on NEWER-kit artefacts the current checkout cannot know about ────
# A "newer" deny rule: a string that is NOT in this kit's base deny set AND NOT in
# the retired history (so an older kit has no rule by which to drop it). Build it
# from a clearly user-/future-shaped path so it can never collide with a shipped rule.
NEW_DENY='Read(~/.future-kit-only-secret/**)'
# Guard the premise: the chosen "newer" rule really is unknown to this checkout.
if jq -e --arg r "$NEW_DENY" '.permissions.deny | index($r) != null' "$BASE" >/dev/null \
   || jq -e --arg r "$NEW_DENY" '(.retired.deny // []) | index($r) != null' "$MP" >/dev/null; then
  fail "chosen NEW_DENY is genuinely unknown to this kit" "collides with a shipped/retired rule: $NEW_DENY"
else
  pass "chosen NEW_DENY is genuinely unknown to this kit (not in base, not retired)"
fi

# A "newer" addition skill dir: an id/path NOT in the additions manifest and NOT in
# retiredAdditions. The older kit's uninstall loop (manifest ids only) + the
# retiredAdditions tombstone loop both miss it, so it must survive untouched.
NEW_SKILL_REL='skills/future-only-skill'
if jq -e --arg p "$NEW_SKILL_REL" '[.additions[].skill // empty] | index($p) != null' "$ADDITIONS" >/dev/null \
   || jq -e --arg p "$NEW_SKILL_REL" '[.retiredAdditions[]?.paths[]?] | index($p) != null' "$MP" >/dev/null; then
  fail "chosen NEW_SKILL_REL is genuinely unknown to this kit" "collides with manifest/tombstone: $NEW_SKILL_REL"
else
  pass "chosen NEW_SKILL_REL is genuinely unknown to this kit (not in manifest, not tombstoned)"
fi

# Inject the newer deny into the profile's settings, and an unrelated user rule to
# prove the older kit's reconcile is surgical even in a downgrade.
USER_DENY='Read(//Users/me/secret-vault/**)'
jq --arg nd "$NEW_DENY" --arg ud "$USER_DENY" \
  '.permissions.deny += [$nd, $ud]' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
NEW_SENTINEL="newer-kit skill body $(date +%s)"
mkdir -p "$PROFILE/$NEW_SKILL_REL"
printf '%s\n' "$NEW_SENTINEL" > "$PROFILE/$NEW_SKILL_REL/SKILL.md"
assert_file "newer-kit addition seeded before downgrade run" "$PROFILE/$NEW_SKILL_REL/SKILL.md"

# ── 3. The downgrade: re-run THIS ("older") kit over the newer-built profile ──
run
rc=$?
assert_eq "downgrade run exits 0 (does not abort)" "0" "$rc"

# ── 4. No corruption ──────────────────────────────────────────────────────────
assert_ok "settings.json still valid JSON after downgrade" jq -e . "$S"
assert_ok "no \$comment keys leaked into settings after downgrade" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$S' >/dev/null"

# ── 5. Union never removes a NEWER permission rule it doesn't know ────────────
assert_lit "newer-kit deny rule SURVIVES downgrade (union never removes it)" "$NEW_DENY" "$S"
# And the user's own rule is likewise preserved (surgical reconcile).
assert_lit "user's own deny rule preserved on downgrade" "$USER_DENY" "$S"

# ── 6. A NEWER addition's files are NOT removed by an older kit ───────────────
assert_file "newer-kit addition file SURVIVES downgrade" "$PROFILE/$NEW_SKILL_REL/SKILL.md"
assert_grep "newer-kit addition content intact (not corrupted)" "$NEW_SENTINEL" "$PROFILE/$NEW_SKILL_REL/SKILL.md"

# ── 7. The older kit's OWN footprint still lands (downgrade is a real install) ─
# Every deny the current kit ships must be present (proves it still reconciled/merged
# its own set rather than no-op'ing).
assert_ok "all current-kit deny rules present after downgrade" \
  bash -c "jq -e --slurpfile b '$BASE' '(\$b[0].permissions.deny - .permissions.deny) | length == 0' '$S' >/dev/null"
assert_file "current-kit hook still present after downgrade" "$PROFILE/hooks/leak-guard.ts"

# ── 8. Idempotent: a second downgrade run changes nothing ────────────────────
cp "$S" "$SB/after1.json"
run
assert_eq "second downgrade run exits 0" "0" "$?"
if diff <(jq -S . "$SB/after1.json") <(jq -S . "$S") >/dev/null 2>&1; then
  pass "downgrade is idempotent (settings.json unchanged on re-run)"
else
  fail "downgrade is idempotent (settings.json unchanged on re-run)" "settings differ on second run"
fi
assert_file "newer-kit addition still present after second run" "$PROFILE/$NEW_SKILL_REL/SKILL.md"

# ── 9. The limitation must be CAPTURED somewhere a user/maintainer can find it ─
# Documented behaviour T22 asserts: "no version tracking; union never removes newer
# entries." If neither the docs nor the config comments record that the kit has no
# version awareness (so a downgrade can leave newer entries behind), that gap is a
# real finding — pin it as a red assertion rather than passing silently.
note_files=(
  "$REPO_ROOT/README.md"
  "$REPO_ROOT/agent-install.md"
  "$REPO_ROOT/AGENTS.md"
  "$MP"
  "$BASE"
)
if grep -liE 'no version (track|aware)|version[ -]track|downgrade|older kit|newer kit|never remove' "${note_files[@]}" >/dev/null 2>&1; then
  pass "the no-version-tracking / union-never-removes limitation is captured in docs/config"
else
  fail "the no-version-tracking / downgrade limitation is captured in docs/config" \
       "no doc/config note explains that the kit has no version tracking and a downgrade leaves newer entries behind"
fi

t_summary
