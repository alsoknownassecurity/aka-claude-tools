#!/usr/bin/env bash
# Scenario T7 — INSTALL/in-between: target the DEFAULT config dir (~/.claude).
#
# Unlike the non-default-profile cases (which layer in place), pointing the
# installer at the canonical default dir ~/.claude is a SPECIAL case in
# install.sh setup_one_config (step 1b / step 5 / step 4e):
#   • the back-up-and-rebuild confirm DEFAULTS YES (a stock ~/.claude is meant to
#     be rebuilt clean, not layered — _rebuild_def="Y" when is_default=1).
#   • NO shell alias is written — plain `claude` already launches ~/.claude, so
#     the rc is left untouched (is_default=1 skips the whole alias block).
#   • a clean rebuild is an UPGRADE not a fresh install: the dir is moved to a
#     timestamped backup, recreated with the kit, and the user's OWN runtime
#     state (settings.json, CLAUDE.md, conversations, memory/, history, todos) is
#     restored from the backup automatically.
#   • secret-bearing caches (shell-snapshots / session-env / paste-cache /
#     file-history) are DELIBERATELY left in the backup — never restored into the
#     rebuilt profile.
#   • the default dir's onboarding metadata lives at $HOME/.claude.json (outside
#     the config dir), so it is untouched by the rebuild.
#
# Why expect: the config-dir target is read via an interactive `prompt` that
# reads from /dev/tty, and --defaults/CT_NONINTERACTIVE force config_dir to the
# NON-default ~/.claude-aka. The only way to exercise the is_default=1 path is a
# real interactive answer of "~/.claude" at the prompt, so this drives the live
# installer through a pty with `expect`. If expect is unavailable the scenario
# cannot be exercised in this sandbox; we say so loudly rather than fake a pass.
#
# Fully sandboxed: fake $HOME (= the default-dir parent), fake bash rc,
# --no-auth-inherit, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_default_dir:"

if ! command -v expect >/dev/null 2>&1; then
  # The is_default path needs a real tty answer; without expect we can't drive it
  # here. Surface the limitation as a visible note (not a silent skip) and pass —
  # there is nothing to assert without exercising the path.
  printf '  \033[33m! expect not found — cannot drive the interactive default-dir path in this sandbox; scenario not exercised\033[0m\n'
  t_summary
  exit $?
fi

SB="$(sandbox)"
RC="$SB/.bashrc"; touch "$RC"           # deterministic rc target (must stay empty)
P="$SB/.claude"                         # the DEFAULT config dir (is_default=1)

# ── seed a stock DEFAULT profile with the user's own state + secret caches ────
mkdir -p "$P"
cat > "$P/settings.json" <<'JSON'
{
  "theme": "dark",
  "cleanupPeriodDays": 42
}
JSON
echo "# my global memory" > "$P/CLAUDE.md"                 # user-authored memory
echo '{"event":"hi"}'     > "$P/history.jsonl"            # REPL input history
mkdir -p "$P/projects/proj/memory"; echo "a lesson" > "$P/projects/proj/memory/x.md"
mkdir -p "$P/todos";               echo "[]"        > "$P/todos/t.json"
# The four secret-bearing caches that must NEVER be restored into the rebuild.
mkdir -p "$P/shell-snapshots"; echo "SECRET_TOKEN=abc"  > "$P/shell-snapshots/snap.sh"
mkdir -p "$P/session-env";     echo "EXPORTED=secret"   > "$P/session-env/env.sh"
mkdir -p "$P/paste-cache";     echo "pasted secret"     > "$P/paste-cache/p.txt"
mkdir -p "$P/file-history";    echo "DOTENV=secret"     > "$P/file-history/f.snap"
# Default-dir onboarding metadata lives at $HOME/.claude.json (NOT inside ~/.claude).
echo '{"oauthAccount":{"emailAddress":"x@y.z"},"hasCompletedOnboarding":true}' > "$SB/.claude.json"

# Deterministic recommended subset needing no optional runtime (bun/trufflehog),
# so the scenario is stable in CI: base settings + one hook + one command.
SEL="secure-settings leak-guard wrap-up"

# ── drive the live installer through a pty, answering config_dir = ~/.claude ──
# We accept the rebuild confirm with a bare Enter — if the default were NOT YES
# the dir would be layered in place and NO backup would appear; the backup
# assertion below therefore also proves the prompt defaulted YES.
EXP="$SB/drive.exp"
cat > "$EXP" <<EXPECT
set timeout 90
set env(HOME) "$SB"
set env(SHELL) "/bin/bash"
set env(CT_ADDITIONS) "$SEL"
spawn bash "$REPO_ROOT/install.sh" --no-auth-inherit
expect {
  -re {Config folder to create/update} { send "$P\r"; exp_continue }
  -re {[Bb]ack up.*rebuild it clean}    { send "\r";  exp_continue }
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
# strip pty CR/ANSI so grep -F on the captured log is reliable
LOG="$SB/log.clean"
tr -d '\r' < "$SB/log" | sed $'s/\033\\[[0-9;]*m//g' > "$LOG"

assert_eq   "installer exits 0 over the default dir" "0" "$rc"
assert_file "default config dir present after rebuild" "$P"

# ── rebuild prompt DEFAULTED YES ─────────────────────────────────────────────
# The confirm rendered the [Y/n] hint (capital Y = default yes) for the default
# dir, and a bare Enter triggered the back-up + rebuild (asserted next).
assert_lit  "rebuild prompt rendered default-YES hint [Y/n]" \
  "rebuild it clean? [Y/n]" "$LOG"

# ── back-up-then-rebuild happened (one timestamped backup) ────────────────────
n_bak=$(find "$SB" -maxdepth 1 -type d -name '.claude.backup-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq   "a timestamped backup was created (rebuild ran, default-YES honored)" "1" "$n_bak"
bak="$(find "$SB" -maxdepth 1 -type d -name '.claude.backup-*' 2>/dev/null | head -1)"

# ── NO alias written — plain `claude` launches the default dir ────────────────
# The rc must be byte-empty: is_default=1 skips the whole alias block.
assert_eq   "shell rc left empty (no alias for the default dir)" "0" "$(wc -c < "$RC" | tr -d ' ')"
assert_nlit "no managed alias block opener in rc" "aka-claude-tools (managed)" "$RC"
assert_nlit "no alias definition in rc"           "alias " "$RC"
assert_grep "log states plain 'claude' launches the default dir" \
  "plain .*claude.* launches it|Default config ~/.claude ready" "$LOG"

# ── user's OWN runtime state restored from the backup ────────────────────────
S="$P/settings.json"
assert_ok   "restored settings.json is valid JSON" jq -e . "$S"
assert_ok   "user theme survived the rebuild" \
  bash -c "jq -e '.theme == \"dark\"' '$S' >/dev/null"
assert_ok   "other arbitrary user key survived" \
  bash -c "jq -e '.cleanupPeriodDays == 42' '$S' >/dev/null"
assert_file "CLAUDE.md restored"           "$P/CLAUDE.md"
assert_grep "CLAUDE.md content intact"     'my global memory' "$P/CLAUDE.md"
assert_file "history.jsonl restored"       "$P/history.jsonl"
assert_file "projects/memory restored"     "$P/projects/proj/memory/x.md"
assert_file "todos restored"               "$P/todos/t.json"

# ── current kit re-applied on top of the restored state ──────────────────────
assert_file "kit hook present after rebuild" "$P/hooks/leak-guard.sh"
assert_ok   "leak-guard registered in settings.PreToolUse" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.sh\"))' '$S' >/dev/null"
assert_ok   "kit denies unioned into restored settings" \
  bash -c "jq -e '((.permissions.deny // []) | length) > 0' '$S' >/dev/null"
assert_file "command placed: wrap-up.md"   "$P/commands/wrap-up.md"

# ── secret-bearing caches NOT restored into the rebuilt profile ──────────────
for d in shell-snapshots session-env paste-cache file-history; do
  [ -e "$P/$d" ] && fail "secret cache NOT restored: $d" "$d came back into the rebuilt profile" \
                 || pass "secret cache NOT restored: $d"
done

# ── but the secret caches DO survive in the backup (data not destroyed) ───────
assert_file "shell-snapshots remains in the backup" "$bak/shell-snapshots/snap.sh"
assert_file "session-env remains in the backup"     "$bak/session-env/env.sh"
assert_file "paste-cache remains in the backup"     "$bak/paste-cache/p.txt"
assert_file "file-history remains in the backup"    "$bak/file-history/f.snap"

# ── default-dir onboarding metadata at $HOME untouched ───────────────────────
assert_file "\$HOME/.claude.json untouched (lives outside the config dir)" "$SB/.claude.json"
assert_ok   "onboarding metadata intact" \
  bash -c "jq -e '.oauthAccount.emailAddress == \"x@y.z\"' '$SB/.claude.json' >/dev/null"

# ── no maintainer-only \$comment leak ────────────────────────────────────────
assert_ok   "no \$comment keys in rebuilt settings" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$S' >/dev/null"

t_summary
