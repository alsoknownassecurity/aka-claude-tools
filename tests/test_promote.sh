#!/usr/bin/env bash
# Reverse flow: tools/promote.sh carries a live profile edit back into the repo,
# path-remapped (profile skills/X -> repo config/skills/X), and REFUSES to stage
# anything carrying a personal trace. All against throwaway clones/sandboxes.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_promote:"

PROMOTE="$REPO_ROOT/tools/promote.sh"

# A fresh clone of the repo (committed state) we can stage into without touching
# the real working tree. A fake profile carrying just one product skill.
make_repo()    { local d; d="$(sandbox)/repo"; git clone --quiet "$REPO_ROOT" "$d"; printf '%s' "$d"; }
make_profile() { local d; d="$(sandbox)/profile"; mkdir -p "$d/skills"; cp -R "$REPO_ROOT/config/skills/shell-audit" "$d/skills/"; printf '%s' "$d"; }

# ── Scenario A: a real edit round-trips, path-remapped ───────────────────────
repoA="$(make_repo)" ; profA="$(make_profile)"
MARK="PROMOTE_ROUNDTRIP_$$"
printf '\n# %s\n' "$MARK" >> "$profA/skills/shell-audit/SKILL.md"

assert_ok   "promote stages a live edit" \
  "$PROMOTE" --repo "$repoA" --profile "$profA" --branch test/rt shell-audit
assert_file "landed at remapped path config/skills/..." "$repoA/config/skills/shell-audit/SKILL.md"
assert_grep "promoted content matches the edit" "$MARK" "$repoA/config/skills/shell-audit/SKILL.md"
_staged=$(git -C "$repoA" diff --cached --name-only | wc -l | tr -d ' ')
[ "$_staged" -gt 0 ] && pass "promote staged file(s) ($_staged)" || fail "promote staged file(s)" "nothing staged"

# ── Scenario B: a planted personal trace is REFUSED (never staged) ───────────
repoB="$(make_repo)" ; profB="$(make_profile)"
printf '\ncontact someone@example.ts.net\n' >> "$profB/skills/shell-audit/SKILL.md"

assert_fail "promote refuses a planted leak" \
  "$PROMOTE" --repo "$repoB" --profile "$profB" --branch test/leak shell-audit
_leaked=$(git -C "$repoB" diff --cached --name-only | wc -l | tr -d ' ')
assert_eq   "leak was NOT staged" "0" "$_leaked"

# ── Scenario C: --list resolves the manifest ─────────────────────────────────
repoC="$(make_repo)"
assert_grep "promote --list shows declared additions" 'shell-audit' \
  <("$PROMOTE" --repo "$repoC" --list)

t_summary
