#!/usr/bin/env bash
# T21 — UPGRADE over a profile littered with orphan backup cruft.
#
# Real ~/.claude-clean shape: over its life a profile accumulates stale settings
# copies a human (or an earlier tool) left behind — settings.json.bak.20240101,
# settings.json.bak.20240615, settings.json.pre-phase6, settings.json.orig. These
# are NOT the canonical settings.json. An upgrade must:
#   1. operate ONLY on settings.json (the one canonical file),
#   2. NOT choke on the extra *.bak.* / *.pre-phase6 / *.orig siblings (exit 0),
#   3. NOT merge any stale backup's content into the live settings.json,
#   4. (rebuild path) NOT restore the cruft into the rebuilt profile — only the
#      canonical settings.json comes back; the cruft stays in the backup.
#
# Sandboxed: fake $HOME, throwaway profile. Two upgrade paths exercised:
#   A) layer-in-place re-run over an existing non-default profile,
#   B) --clean back-up + rebuild.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_orphan_backups:"

# A unique marker only ever present in the STALE backups, never in the canonical
# settings.json. If the upgrade ever merges/restores cruft, this leaks in.
STALE_MARKER='Read(//STALE/cruft/should/never/merge/**)'
# A unique marker only in the canonical live settings.json — must survive.
LIVE_MARKER='Read(//Users/me/live/keep/**)'

# seed_cruft <profile> — plant the canonical settings.json + a litter of orphan
# backup files around it, each carrying the STALE_MARKER so a wrongful merge shows.
seed_cruft() {
  local P="$1"
  mkdir -p "$P/hooks"
  cat > "$P/settings.json" <<JSON
{ "permissions": { "deny": ["$LIVE_MARKER"] } }
JSON
  # Orphan cruft — the ~/.claude-clean littered shape. Valid JSON (so a wrongful
  # merge would actually succeed and leak), each with the STALE_MARKER.
  for suf in bak.20240101-000000 bak.20240615-120000 pre-phase6 orig; do
    cat > "$P/settings.json.$suf" <<JSON
{ "permissions": { "deny": ["$STALE_MARKER"] }, "stale": "$suf" }
JSON
  done
  # Also a non-JSON crufty backup, to make sure the upgrade doesn't try to parse it.
  printf 'this is a corrupt half-written backup {{{\n' > "$P/settings.json.bak.corrupt"
}

# count_cruft <profile> — how many orphan settings.json.* siblings remain.
count_cruft() { find "$1" -maxdepth 1 -name 'settings.json.*' 2>/dev/null | wc -l | tr -d ' '; }

# ── Path A: layer-in-place upgrade ────────────────────────────────────────────
SBA="$(sandbox)"; touch "$SBA/.bashrc"; PA="$SBA/.claude-aka"
seed_cruft "$PA"
n_cruft_before="$(count_cruft "$PA")"

CT_ADDITIONS="secure-settings leak-guard" SHELL=/bin/bash HOME="$SBA" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SBA/log" 2>&1
rcA=$?

assert_eq   "A: layer-in-place upgrade over cruft exits 0" "0" "$rcA"
assert_ok   "A: canonical settings.json still valid JSON" jq -e . "$PA/settings.json"
# The live rule must survive the merge.
assert_ok   "A: live rule preserved through upgrade" \
  bash -c "jq -e --arg r '$LIVE_MARKER' '.permissions.deny | index(\$r) != null' '$PA/settings.json' >/dev/null"
# No stale backup content leaked into the canonical settings.json.
assert_nlit "A: stale backup content NOT merged into settings.json" "$STALE_MARKER" "$PA/settings.json"
assert_ok   "A: no leftover \"stale\" key in settings.json" \
  bash -c "jq -e 'has(\"stale\") | not' '$PA/settings.json' >/dev/null"
# The upgrade did not choke loudly on the cruft.
assert_nlit "A: no jq parse error reported on cruft" "parse error" "$SBA/log"
# The cruft is the user's own files — the in-place path must not silently delete it.
n_cruft_after="$(count_cruft "$PA")"
assert_eq   "A: orphan backup cruft left untouched (not deleted)" "$n_cruft_before" "$n_cruft_after"

# ── Path B: --clean back-up + rebuild upgrade ─────────────────────────────────
SBB="$(sandbox)"; touch "$SBB/.bashrc"; PB="$SBB/.claude-aka"
seed_cruft "$PB"

CT_ADDITIONS="secure-settings leak-guard" SHELL=/bin/bash HOME="$SBB" \
  bash "$REPO_ROOT/install.sh" --clean --defaults --no-auth-inherit >"$SBB/log" 2>&1
rcB=$?

assert_eq   "B: --clean rebuild over cruft exits 0" "0" "$rcB"

# A timestamped backup was made.
bak="$(find "$SBB" -maxdepth 1 -type d -name '.claude-aka.backup-*' 2>/dev/null | head -1)"
assert_file "B: timestamped backup created" "$bak"

assert_ok   "B: rebuilt settings.json valid JSON" jq -e . "$PB/settings.json"
# Canonical settings.json restored — live rule survives the rebuild.
assert_ok   "B: live rule restored into rebuilt profile" \
  bash -c "jq -e --arg r '$LIVE_MARKER' '.permissions.deny | index(\$r) != null' '$PB/settings.json' >/dev/null"
# No stale backup content leaked into the rebuilt settings.json.
assert_nlit "B: stale backup content NOT merged on rebuild" "$STALE_MARKER" "$PB/settings.json"
assert_ok   "B: no leftover \"stale\" key after rebuild" \
  bash -c "jq -e 'has(\"stale\") | not' '$PB/settings.json' >/dev/null"
# The orphan settings.json.* siblings are the USER'S files — a rebuild migrates
# everything (we never silently drop a user file), so they ARE restored. The
# guarantee that matters is above: none of their STALE content was MERGED into the
# canonical settings.json. (They're inert siblings; the kit only reads settings.json.)
assert_eq   "B: orphan siblings preserved into rebuilt profile (not dropped)" \
  "$n_cruft_before" "$(count_cruft "$PB")"
# ...and they also remain in the backup (cp, not mv).
assert_file "B: cruft preserved in backup (pre-phase6)" "$bak/settings.json.pre-phase6"
assert_file "B: cruft preserved in backup (.bak)"       "$bak/settings.json.bak.20240101-000000"
assert_nlit "B: no jq parse error reported on cruft" "parse error" "$SBB/log"

t_summary
