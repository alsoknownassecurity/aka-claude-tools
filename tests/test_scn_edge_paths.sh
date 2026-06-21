#!/usr/bin/env bash
# Scenario (edge_paths) — INSTALL/path-edges: the config dir is a SYMLINK.
#
# A very common real setup: the user symlinks their Claude config dir to a synced
# / external store (e.g. ~/.claude -> ~/Dropbox/claude-config, or a profile dir
# on another volume). The LAYER-IN-PLACE path handles this fine — writes follow
# the link into the real store and the link is preserved (verified separately).
#
# The REBUILD path (--clean, or accepting the default-YES rebuild on ~/.claude)
# does NOT. install.sh setup_one_config step 1b does:
#
#     mv "$config_dir" "$rebuild_backup"   # config_dir is a SYMLINK
#     mkdir -p "$config_dir"               # recreates a REAL dir at the link path
#     default_src="$rebuild_backup"        # restore-source = the moved symlink
#
# Because `mv` on a symlink renames the LINK (not its target), three things go
# wrong, each its own data-integrity defect:
#
#   1. The "timestamped backup" the installer promises as a safety net is itself
#      just a SYMLINK pointing at the user's STILL-LIVE original store — not an
#      independent copy. There is no real backup; deleting it (or the store
#      moving) leaves nothing to recover from.
#   2. The symlink at the config-dir path is silently replaced by a brand-new
#      REAL directory. The user's deliberate symlink intent (config on a synced/
#      external volume) is destroyed without warning.
#   3. The original real store is orphaned: it keeps a stale copy of the data
#      while the active config dir is now a different, real directory. Future
#      writes diverge silently between the two.
#
# Expected (correct) behavior: a rebuild of a symlinked config dir should either
# resolve the link and back up / rebuild the REAL target (preserving the link),
# or refuse with a clear message — never convert the link to a real dir and leave
# a symlink masquerading as the backup.
#
# This test PINS the bug: it asserts the correct invariants, so it is RED against
# the current installer (probe_green=false) until the rebuild handles a symlinked
# config dir.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit, never touches a
# real ~/.claude*. Driven through a pty with expect (the config-dir target is read
# from /dev/tty; --defaults can't select a non-default dir). If expect is absent
# the scenario cannot be exercised and we say so loudly rather than fake a pass.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_edge_paths:"

if ! command -v expect >/dev/null 2>&1; then
  printf '  \033[33m! expect not found — cannot drive the interactive symlinked-config-dir rebuild in this sandbox; scenario not exercised\033[0m\n'
  t_summary
  exit $?
fi

SB="$(sandbox)"
RC="$SB/.bashrc"; touch "$RC"

# ── the user's REAL store (on a "synced/external volume") + a symlink to it ────
REAL="$SB/synced-store"
mkdir -p "$REAL/projects/p/memory"
cat > "$REAL/settings.json" <<'JSON'
{ "theme": "dark", "cleanupPeriodDays": 42 }
JSON
echo "# precious user memory" > "$REAL/CLAUDE.md"
echo "a hard-won lesson"      > "$REAL/projects/p/memory/x.md"

CFG="$SB/.claude-synced"        # config dir is a SYMLINK to the real store
ln -s "$REAL" "$CFG"

# sanity: the fixture starts as a symlink
assert_ok "fixture: config dir starts as a symlink" test -L "$CFG"

# ── drive the live installer: rebuild path over the symlinked config dir ───────
SEL="secure-settings"
EXP="$SB/drive.exp"
cat > "$EXP" <<EXPECT
set timeout 90
set env(HOME) "$SB"
set env(SHELL) "/bin/bash"
set env(CT_ADDITIONS) "$SEL"
spawn bash "$REPO_ROOT/install.sh" --no-auth-inherit --clean
expect {
  -re {Config folder to create/update} { send "$CFG\r"; exp_continue }
  -re {[Bb]ack up.*rebuild it clean}    { send "y\r"; exp_continue }
  -re {Shell alias to launch it}        { send "\r";  exp_continue }
  -re {Migrate items from an existing}  { send "n\r"; exp_continue }
  -re {Set up another config folder}    { send "n\r"; exp_continue }
  -re {skip any}                        { send "\r";  exp_continue }
  -re {keep any}                        { send "\r";  exp_continue }
  -re {migrate which}                   { send "\r";  exp_continue }
  eof {}
}
catch wait result
exit [lindex \$result 3]
EXPECT
expect -f "$EXP" > "$SB/log" 2>&1
rc=$?
assert_eq "installer exits 0 over a symlinked config dir" "0" "$rc"

bak="$(find "$SB" -maxdepth 1 -name '.claude-synced.backup-*' 2>/dev/null | head -1)"
assert_file "a timestamped backup entry was created" "$bak"

# ── INVARIANT 1: the backup must be a REAL independent copy, not a symlink ─────
# Currently RED: the backup is just the renamed symlink, pointing at the live
# store — so it is not a real safety-net copy at all.
if [ -L "$bak" ]; then
  fail "backup is an independent copy, not a symlink to the live store" \
       "backup is a symlink → $(readlink "$bak") (no real backup was made)"
else
  pass "backup is an independent copy, not a symlink to the live store"
fi

# ── INVARIANT 2: the symlink intent at the config-dir path is preserved ────────
# Currently RED: the link is replaced by a brand-new real directory, silently
# destroying the user's "config lives on a synced/external volume" setup.
if [ -L "$CFG" ]; then
  pass "config-dir symlink preserved (intent not destroyed)"
else
  fail "config-dir symlink preserved (intent not destroyed)" \
       "$CFG was converted from a symlink into a real directory"
fi

# ── INVARIANT 3: the user's data ends up in ONE place, not orphaned/diverged ──
# After a correct rebuild the active config dir (following any link) and the
# real store should be the SAME directory — there must not be two divergent
# copies. Currently RED: the active config dir is a new real dir while the
# original store is orphaned with a stale duplicate.
active="$(cd "$CFG" 2>/dev/null && pwd -P || echo "")"
storep="$(cd "$REAL" 2>/dev/null && pwd -P || echo "")"
if [ -n "$active" ] && [ "$active" = "$storep" ]; then
  pass "active config dir and the original store are the same dir (no orphan duplicate)"
else
  fail "active config dir and the original store are the same dir (no orphan duplicate)" \
       "active='$active' store='$storep' — the store is orphaned as a stale duplicate"
fi

# ── the user's data did at least survive somewhere (not destroyed) ────────────
# (This passes today — the bug is divergence/no-real-backup, not deletion. Kept
# so a future fix that accidentally drops data is caught too.)
assert_grep "user CLAUDE.md content survives somewhere" \
  'precious user memory' "$CFG/CLAUDE.md"

t_summary
