#!/usr/bin/env bash
# sync-public scenario: the published refset must equal the AUDITED refset. The
# commit-history leak gate alone is not enough — a tag can carry unaudited objects
# (off-main targets), and tag NAMES / annotated tag MESSAGES are a separate leak
# surface. These cases pin that tools/sync-public.sh:
#   A. publishes ONLY main-reachable, on-remote tags (off-main secret tag excluded);
#   B. ABORTS on a leak pattern in a tag NAME;
#   C. ABORTS on a leak pattern in an annotated tag MESSAGE.
# Fully sandboxed: throwaway bare "origin"/"public" repos under $TMP — no network,
# no real remote, never touches a real profile.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_sync_public:"

SYNC="$REPO_ROOT/tools/sync-public.sh"
LEAK='example-host|example-user'   # stand-in operator identifiers for the gate

# ── build a dev repo (with the tools) that tracks a bare "origin" ────────────
ORIGIN="$(sandbox)/origin.git"; git init -q --bare "$ORIGIN"
PUB="$(sandbox)/public.git";    git init -q --bare "$PUB"
DEV="$(sandbox)/dev"
git clone -q "$ORIGIN" "$DEV" 2>/dev/null
cd "$DEV"
git config user.email t@t.test; git config user.name tester
git checkout -q -b main
mkdir -p tools tests
cp "$REPO_ROOT/tools/sync-public.sh" "$REPO_ROOT/tools/audit-history.sh" \
   "$REPO_ROOT/tools/leak-lib.sh" tools/
cp "$REPO_ROOT/tests/audit-allow.txt" tests/
git add -A; git commit -qm "tooling"
SEED="$(git rev-parse HEAD)"            # public will be seeded here (behind)
echo base > f.txt; git add -A; git commit -qm "base on main"
git tag -a v1.0 -m "first release"      # clean annotated tag, on main
git push -q origin main --tags

# off-main commit carrying a unique sentinel, tagged — pushed to origin but NOT on
# main. (A real-shaped secret would collide with audit-allow.txt fixtures; a unique
# sentinel proves the off-main content never enters the publish set.)
git checkout -q -b side
printf 'OFFMAIN-ONLY-SENTINEL-9q7-do-not-publish\n' > secret.txt
git add -A; git commit -qm "side work (off-main, must stay private)"
git tag offmain-secret
git push -q origin side --tags
git checkout -q main

# seed public BEHIND main (fast-forwardable)
git push -q "$PUB" "$SEED:refs/heads/main"

run_sync() { # -> writes $OUT, returns sync exit code
  OUT="$(sandbox)/out.txt"
  PUB_URL="$PUB" DEV_REMOTE=origin DRY_RUN=1 RUN_TESTS=0 AKA_LEAK_EXTRA="$LEAK" \
    bash "$SYNC" >"$OUT" 2>&1
}

# ── A. happy path: only the main-reachable on-remote tag is in the manifest ──
git remote remove public 2>/dev/null || true
run_sync; rcA=$?
assert_eq   "A: dry-run succeeds (gates pass)" "0" "$rcA"
assert_grep "A: clean main-reachable tag v1.0 IS published"   "tag: v1\.0"     "$OUT"
assert_ngrep "A: off-main secret tag is NOT in the publish set" "offmain-secret" "$OUT"
# the off-main content must never enter the publish set
assert_ngrep "A: off-main sentinel never surfaces"            "OFFMAIN-ONLY-SENTINEL" "$OUT"

# ── B. leak pattern in a tag NAME → abort ───────────────────────────────────
git tag "v1.0-example-user-host" main           # main-reachable, leaky NAME
git push -q origin "v1.0-example-user-host"
git remote remove public 2>/dev/null || true
run_sync; rcB=$?
assert_eq   "B: leaky tag NAME aborts (non-zero)" "1" "$rcB"
assert_grep "B: abort names the tag-NAME leak" "leak pattern in tag NAME" "$OUT"
git tag -d "v1.0-example-user-host" >/dev/null; git push -q origin :refs/tags/v1.0-example-user-host

# ── C. leak pattern in an annotated tag MESSAGE → abort ──────────────────────
git tag -a "v1.1" -m "release built on example-host" main
git push -q origin "v1.1"
git remote remove public 2>/dev/null || true
run_sync; rcC=$?
assert_eq   "C: leaky tag MESSAGE aborts (non-zero)" "1" "$rcC"
assert_grep "C: abort names the tag-OBJECT leak" "leak pattern in tag OBJECT" "$OUT"
git tag -d "v1.1" >/dev/null; git push -q origin :refs/tags/v1.1

# ── D. clean NAME + clean MESSAGE, but leaky TAGGER identity → abort ─────────
# The tagger header lives in the tag OBJECT, not in %(contents); a name/message-
# only scan would miss it. cat-file scanning catches it.
git -c user.name="example-user host" -c user.email="example-user@desk.example" \
  tag -a "v2.0" -m "clean release notes" main
git push -q origin "v2.0"
git remote remove public 2>/dev/null || true
run_sync; rcD=$?
assert_eq   "D: leaky tag TAGGER identity aborts (non-zero)" "1" "$rcD"
assert_grep "D: abort names the tag-OBJECT leak (tagger)" "leak pattern in tag OBJECT" "$OUT"
git tag -d "v2.0" >/dev/null; git push -q origin :refs/tags/v2.0   # clear so the gate passes for E

# ── E. a tag already on PUBLIC but OUTSIDE the audited manifest → abort ──────
# The invariant is over the published STATE: a stray public tag (e.g. from an
# earlier --tags or manual test) is unaudited and must be surfaced, not ignored.
git push -q "$PUB" "$(git rev-parse main):refs/tags/stray-public-only"
git remote remove public 2>/dev/null || true
run_sync; rcE=$?
assert_eq   "E: stray public tag outside the manifest aborts (non-zero)" "1" "$rcE"
assert_grep "E: abort names the unaudited public tag" "outside the audited manifest" "$OUT"

t_summary
