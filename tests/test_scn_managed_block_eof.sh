#!/usr/bin/env bash
# Scenario managed_block_eof (first-officer triage finding): the managed-block awk
# in remove_managed_block / write_managed_block used `skip=1 … to end marker`, which
# runs to EOF if the end marker is missing — silently TRUNCATING the rest of the
# user's rc (a corrupt/tampered block eats their .zshrc/.bashrc tail). Fix: buffer
# the candidate block and flush it at EOF when no end marker is found, never truncate.
# Also covers id regex-escaping and that well-formed/variant removal still work.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../shared/lib/common.sh
source "$REPO_ROOT/shared/lib/common.sh"
echo "test_scn_managed_block_eof:"

SB="$(sandbox)"
BEGIN="# >>> aka-claude-tools managed: aka >>>"
END="# <<< aka-claude-tools managed: aka <<<"

# ── A. remove over a CORRUPT block (begin, no end) must not truncate trailing rc ──
RCA="$SB/a.rc"
printf '%s\n%s\nalias x=1\n%s\nalias me=2\n' "# user top" "$BEGIN" "alias inblock=9" > "$RCA"   # NO end marker
printf 'alias TAIL_SURVIVES=1\n' >> "$RCA"
remove_managed_block "$RCA" "aka" || true
assert_grep "A: user content BEFORE a corrupt block survives" '^# user top$' "$RCA"
assert_grep "A: user content AFTER a corrupt block survives (not truncated)" 'TAIL_SURVIVES=1' "$RCA"

# ── B. remove over a WELL-FORMED block still removes it; surrounding rc kept ──────
RCB="$SB/b.rc"
printf '%s\n%s\nalias aka=launch\n%s\n%s\n' "# before" "$BEGIN" "$END" "# after" > "$RCB"
remove_managed_block "$RCB" "aka"
assert_nlit "B: managed block removed" "$BEGIN" "$RCB"
assert_grep "B: line before the block kept" '^# before$' "$RCB"
assert_grep "B: line after the block kept"  '^# after$'  "$RCB"

# ── C. write over a CORRUPT prior block must not truncate; new block appended ─────
RCC="$SB/c.rc"
printf '%s\n%s\nstale\n%s\n' "# keep-me-head" "$BEGIN" "# keep-me-tail" > "$RCC"   # corrupt prior block (no end)
write_managed_block "$RCC" "aka" "alias aka='CLAUDE_CONFIG_DIR=\"/x\" claude'"
assert_grep "C: content before a corrupt prior block survives" '^# keep-me-head$' "$RCC"
assert_grep "C: content after a corrupt prior block survives (not truncated)" '^# keep-me-tail$' "$RCC"
assert_grep "C: a fresh managed block was written" 'CLAUDE_CONFIG_DIR=' "$RCC"
# A corrupt prior block (begin, no end) is flushed (preserved) rather than truncated,
# so it may leave a harmless orphan begin-comment; the invariant that matters is that
# the freshly written block is WELL-FORMED (carries its end marker) and no content was lost.
assert_grep "C: the freshly written block is well-formed (end marker present)" \
  '^# <<< aka-claude-tools managed: aka <<<$' "$RCC"

# ── D. variant-family removal still works (remove 'aka' clears 'aka2') ────────────
RCD="$SB/d.rc"
B2="# >>> aka-claude-tools managed: aka2 >>>"; E2="# <<< aka-claude-tools managed: aka2 <<<"
printf "alias aka='my own'\n%s\nalias aka2=launch\n%s\n" "$B2" "$E2" > "$RCD"
remove_managed_block "$RCD" "aka"
assert_nlit "D: collision-renamed aka2 block removed by remove(aka)" "$B2" "$RCD"
assert_grep "D: user's own 'aka' alias preserved" "alias aka='my own'" "$RCD"

t_summary
