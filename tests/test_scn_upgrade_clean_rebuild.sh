#!/usr/bin/env bash
# UPGRADE over a MESSY profile via --clean: the back-up-then-clean-rebuild path (T20).
#
# The real-world upgrade where a user has been living in their DEFAULT-shaped profile
# and accumulated state + an out-of-date (stale) kit. `--clean` must:
#   • move the whole profile to a timestamped backup, then recreate it clean;
#   • RESTORE the profile's OWN runtime state from the backup so the upgrade is never
#     a fresh install — settings.json (merged with this version's kit), CLAUDE.md, and
#     EVERY session item (history.jsonl, projects/, sessions/, todos/, tasks/);
#   • REFRESH kit-managed files to the CURRENT version (a stale/edited kit hook is
#     overwritten with the shipped kit file, byte-for-byte);
#   • RESTORE the profile's own caches too (shell-snapshots/, paste-cache/,
#     file-history/, session-env/) — a rebuild returns a profile's data to itself,
#     so nothing is dropped; the restored content must NOT be merged into settings.json;
#   • leave the timestamped backup behind as a safety net.
# Plus: the rollback trap (ct_rebuild_rollback) restores the backup over a half-built
# dir if the rebuild is interrupted before completion — all-or-nothing.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit. Never touches a real
# ~/.claude*. The rollback trap is exercised two ways: directly via the source-guarded
# helper (deterministic) AND by signalling a real install mid-rebuild.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_clean_rebuild:"

SB="$(sandbox)"; touch "$SB/.bashrc"; P="$SB/.claude-aka"

# Deterministic recommended subset needing no optional runtime (bun/rtk/trufflehog):
# leak-guard ships a marked kit hook we can corrupt to simulate a stale kit; secure-
# settings ships kit denies to prove settings reconciliation on restore.
SEL="secure-settings leak-guard"
run() { CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB" \
        bash "$REPO_ROOT/install.sh" "$@" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# ── (1) clean baseline install ────────────────────────────────────────────────
run; assert_eq "baseline install exits 0" "0" "$?"
S="$P/settings.json"
assert_file "kit hook present after baseline"  "$P/hooks/leak-guard.sh"
assert_file "settings.json present after baseline" "$S"

# A representative kit deny the baseline shipped — proves kit settings get re-merged
# on top of the RESTORED user settings.json after the rebuild.
KIT_DENY="$(jq -r '.permissions.deny[0]' "$REPO_ROOT/config/settings.base.json")"
assert_ok "baseline adopted a kit deny" \
  bash -c "jq -e --arg r '$KIT_DENY' '.permissions.deny | index(\$r) != null' '$S' >/dev/null"

# ── (2) make the profile MESSY: user state + a STALE kit file + secret caches ──
# User's OWN settings rule (kit never ships it) — must survive the restore+merge.
U_DENY='Read(//Users/me/secrets/**)'
jq --arg ud "$U_DENY" '.permissions.deny = ((.permissions.deny // []) + [$ud])' \
   "$S" > "$S.tmp" && mv "$S.tmp" "$S"
assert_ok "messy settings still valid JSON" jq -e . "$S"

# User's global memory.
printf '# my global memory\nremember this\n' > "$P/CLAUDE.md"

# Full session-state spread — one of EVERY CT_SESSION_ITEM the kit promises to carry.
echo '{"event":"hi"}'                        > "$P/history.jsonl"
mkdir -p "$P/projects/proj/memory"; echo "a lesson"   > "$P/projects/proj/memory/x.md"
mkdir -p "$P/projects/proj";        echo '{"x":1}'     > "$P/projects/proj/conv.jsonl"
mkdir -p "$P/sessions";             echo "SESSION"     > "$P/sessions/s1.json"
mkdir -p "$P/todos";                echo "[]"          > "$P/todos/t.json"
mkdir -p "$P/tasks";                echo "TASK"        > "$P/tasks/task1.json"

# STALE kit file: corrupt the managed kit hook (user kept the managed marker). The
# clean rebuild must overwrite it with the current shipped kit version.
STALE_SENTINEL="### STALE KIT BODY — must be refreshed to current version"
printf '%s\n' "$STALE_SENTINEL" >> "$P/hooks/leak-guard.sh"
assert_lit "managed marker still on the stale kit file" \
  "aka-claude-tools:managed-hook" "$P/hooks/leak-guard.sh"

# Secret-bearing caches — ALL of the categories the kit promises to leave behind.
mkdir -p "$P/shell-snapshots"; echo "EXPORT_TOKEN=sk-secret" > "$P/shell-snapshots/snap.sh"
mkdir -p "$P/paste-cache";     echo "pasted-secret"          > "$P/paste-cache/p.txt"
mkdir -p "$P/file-history";    echo "DB_PASS=hunter2"        > "$P/file-history/f.env"
mkdir -p "$P/session-env";     echo "AWS_KEY=AKIA..."        > "$P/session-env/e.env"

# ── (3) re-run the installer on the --clean back-up + rebuild path ─────────────
run --clean; rc=$?
assert_eq "clean rebuild exits 0" "0" "$rc"
assert_ok "settings.json still valid JSON after rebuild" jq -e . "$S"

# A timestamped backup was created and KEPT as a safety net.
n_bak=$(find "$SB" -maxdepth 1 -type d -name '.claude-aka.backup-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly one timestamped backup created" "1" "$n_bak"
bak="$(find "$SB" -maxdepth 1 -type d -name '.claude-aka.backup-*' 2>/dev/null | head -1)"

# ── (4a) USER DATA RESTORED ───────────────────────────────────────────────────
# settings.json restored AND reconciled with this version's kit (union of both).
assert_ok "user's own deny restored into settings" \
  bash -c "jq -e --arg r '$U_DENY' '.permissions.deny | index(\$r) != null' '$S' >/dev/null"
assert_ok "kit deny re-merged on top of restored settings" \
  bash -c "jq -e --arg r '$KIT_DENY' '.permissions.deny | index(\$r) != null' '$S' >/dev/null"

# CLAUDE.md restored verbatim.
assert_file "CLAUDE.md restored"          "$P/CLAUDE.md"
assert_grep "CLAUDE.md content intact"    'my global memory' "$P/CLAUDE.md"

# Every session item is back in the rebuilt dir.
assert_file "history.jsonl restored"      "$P/history.jsonl"
assert_grep "history.jsonl content intact" 'hi' "$P/history.jsonl"
assert_file "projects/ memory restored"   "$P/projects/proj/memory/x.md"
assert_file "projects/ conversation restored" "$P/projects/proj/conv.jsonl"
assert_file "sessions/ restored"          "$P/sessions/s1.json"
assert_file "todos/ restored"             "$P/todos/t.json"
assert_file "tasks/ restored"             "$P/tasks/task1.json"

# ── (4b) KIT FILES AT CURRENT VERSION ─────────────────────────────────────────
assert_file "kit hook present after rebuild" "$P/hooks/leak-guard.sh"
assert_nlit "stale kit body refreshed (sentinel gone)" \
  "$STALE_SENTINEL" "$P/hooks/leak-guard.sh"
if diff -q "$REPO_ROOT/config/hooks/leak-guard.sh" "$P/hooks/leak-guard.sh" >/dev/null 2>&1; then
  pass "kit hook is byte-identical to the current shipped version"
else
  fail "kit hook is byte-identical to the current shipped version" \
       "profile copy differs from config/hooks/leak-guard.sh"
fi

# ── (4c) the profile's OWN caches come home (rebuild returns its data to itself) ─
for cache in shell-snapshots paste-cache file-history session-env; do
  assert_file "cache '$cache' restored into rebuilt profile" "$P/$cache"
done
# ...and they're also still in the backup (cp, not mv — nothing destroyed).
assert_file "shell-snapshots kept in backup" "$bak/shell-snapshots/snap.sh"
assert_file "paste-cache kept in backup"     "$bak/paste-cache/p.txt"
assert_file "file-history kept in backup"    "$bak/file-history/f.env"
assert_file "session-env kept in backup"     "$bak/session-env/e.env"
# The cache's own content comes back verbatim (it's the profile's data)...
assert_lit  "cache content restored verbatim" "sk-secret" "$P/shell-snapshots/snap.sh"
# ...but it must NOT have been merged into the kit-managed settings.json.
if grep -qF 'sk-secret' "$P/settings.json" 2>/dev/null; then
  fail "cache content not merged into settings.json" "found sk-secret in settings.json"
else
  pass "cache content not merged into settings.json"
fi

# ── (5) ROLLBACK TRAP: deterministic, via the source-guarded helper ───────────
# Simulate an interrupt AFTER the profile moved to backup but BEFORE the rebuild
# finished (_CT_REBUILD_DONE=0): the trap must restore the backup over the target.
RB="$(sandbox)"; bk="$RB/backup"; tg="$RB/target"
mkdir -p "$bk"; echo SENTINEL > "$bk/keepme"          # backup holds the "real" config
mkdir -p "$tg"; echo HALF     > "$tg/halfbuilt"        # a half-built target dir
( source "$REPO_ROOT/install.sh" >/dev/null 2>&1
  _CT_REBUILD_BACKUP="$bk"; _CT_REBUILD_TARGET="$tg"; _CT_REBUILD_DONE=0; _CT_ROLLBACK_RAN=0
  ct_rebuild_rollback >/dev/null 2>&1 )
assert_file "interrupted rebuild restored target from backup" "$tg/keepme"
assert_grep "restored content intact"                         'SENTINEL' "$tg/keepme"
[ -e "$tg/halfbuilt" ] && fail "half-built target was replaced by the backup" "halfbuilt lingers" \
                       || pass "half-built target was replaced by the backup"
[ -e "$bk" ] && fail "backup consumed by the restore (mv, not copy)" "backup still present" \
             || pass "backup consumed by the restore (mv, not copy)"

# ── (6) ROLLBACK TRAP: end-to-end, via a real SIGTERM mid-rebuild ─────────────
# Seed a fresh profile with a sentinel, launch a --clean rebuild, and TERM it once
# the timestamped backup appears (i.e. after the profile was moved aside but before
# the rebuild completes). The signal trap must restore the original profile.
SB2="$(sandbox)"; touch "$SB2/.bashrc"; P2="$SB2/.claude-aka"
CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB2" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB2/log0" 2>&1
echo "ROLLME" > "$P2/CLAUDE.md"            # the original state we must get back
echo '{"event":"orig"}' > "$P2/history.jsonl"

CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB2" \
  bash "$REPO_ROOT/install.sh" --clean --defaults --no-auth-inherit >"$SB2/log2" 2>&1 &
inst_pid=$!
# Wait until the backup dir exists (rebuild in progress), then signal. Cap the wait.
hit=0
for _ in $(seq 1 200); do
  if find "$SB2" -maxdepth 1 -type d -name '.claude-aka.backup-*' 2>/dev/null | grep -q .; then
    hit=1; kill -TERM "$inst_pid" 2>/dev/null; break
  fi
  sleep 0.02
done
wait "$inst_pid" 2>/dev/null; sig_rc=$?

if [ "$hit" = "1" ]; then
  pass "observed the backup mid-rebuild (signal window reached)"
  # After a TERM-driven rollback, the original profile is back with its state, and
  # no orphaned backup is left behind.
  assert_file "CLAUDE.md present after interrupted rebuild"   "$P2/CLAUDE.md"
  assert_grep "original CLAUDE.md content restored"          'ROLLME' "$P2/CLAUDE.md"
  assert_file "history.jsonl present after interrupted rebuild" "$P2/history.jsonl"
  assert_grep "original history restored"                    'orig' "$P2/history.jsonl"
  n_orphan=$(find "$SB2" -maxdepth 1 -type d -name '.claude-aka.backup-*' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "no orphaned backup left after rollback" "0" "$n_orphan"
else
  # The rebuild can be fast enough that the backup window is never observed; in that
  # case the run completed and the profile must simply be intact (not a failure of the
  # trap, just an un-hit race). Pin the safe outcome rather than skipping silently.
  pass "rebuild completed before signal window (race not hit; deterministic check in step 5 covers the trap)"
  assert_file "profile intact when signal window not hit" "$P2/CLAUDE.md"
fi

t_summary
