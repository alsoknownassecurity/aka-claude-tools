#!/usr/bin/env bash
# Rebuild state preservation — `--clean` moves the profile to a timestamped backup,
# recreates it with the current kit files, and RESTORES the profile's own runtime
# state (settings.json, CLAUDE.md, session history) so an upgrade is never a fresh
# install. Secret-bearing caches (shell-snapshots/ etc.) are deliberately NOT
# restored — they stay in the backup.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_rebuild:"

SB="$(sandbox)"; touch "$SB/.bashrc"; P="$SB/.claude-aka"
SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log1" 2>&1

# Plant the profile's own state + one secret-bearing cache.
echo "# my global memory" > "$P/CLAUDE.md"
echo '{"event":"hi"}'     > "$P/history.jsonl"
mkdir -p "$P/projects/proj/memory"; echo "a lesson" > "$P/projects/proj/memory/x.md"
mkdir -p "$P/todos";               echo "[]"        > "$P/todos/t.json"
mkdir -p "$P/shell-snapshots";     echo "SECRET"    > "$P/shell-snapshots/snap.sh"

# Force the back-up + clean-rebuild path.
SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --clean --defaults --no-auth-inherit >"$SB/log2" 2>&1
assert_eq "rebuild exits 0" "0" "$?"

# A timestamped backup was made.
n_bak=$(find "$SB" -maxdepth 1 -type d -name '.claude-aka.backup-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "a timestamped backup was created" "1" "$n_bak"
bak="$(find "$SB" -maxdepth 1 -type d -name '.claude-aka.backup-*' 2>/dev/null | head -1)"

# The profile's OWN state came back into the rebuilt dir.
assert_file "CLAUDE.md restored"            "$P/CLAUDE.md"
assert_grep "CLAUDE.md content intact"      'my global memory' "$P/CLAUDE.md"
assert_file "history.jsonl restored"        "$P/history.jsonl"
assert_file "projects/memory restored"      "$P/projects/proj/memory/x.md"
assert_file "todos restored"                "$P/todos/t.json"

# The current kit files were (re)applied on top.
assert_file "kit hook present after rebuild" "$P/hooks/leak-guard.sh"

# Secret-bearing cache is NOT restored — it stays only in the backup.
[ -e "$P/shell-snapshots" ] && fail "secret cache NOT restored into profile" "shell-snapshots came back" \
                            || pass "secret cache NOT restored into profile"
assert_file "secret cache remains in the backup" "$bak/shell-snapshots/snap.sh"

t_summary
