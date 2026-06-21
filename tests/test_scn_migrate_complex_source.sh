#!/usr/bin/env bash
# Scenario T23 — migrating INTO a new profile FROM a complex source warns + suggests
# Path A. detect_config_complexity is also run on the migration SOURCE (not just a
# rebuild target): importing MCP config / CLAUDE.md @-imports / bespoke layout into a
# fresh profile is exactly where a deterministic copy can't rewrite paths or reason
# about auth, so the installer flags it and points at agent-install.md — then still
# performs the verbatim copy if the user continues.
#
# The target is a BRAND-NEW dir (doesn't exist), so the existing-dir rebuild advisory
# can't fire — the only advisory that can appear is the migrate-source one, proving
# the suggestion now covers the import path too. Driven over a pty with NO_COLOR=1
# (clean prompts). Fully sandboxed; never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_migrate_complex_source:"

if ! command -v expect >/dev/null 2>&1; then
  printf '  \033[33m! expect not found — cannot drive the interactive migrate path here; scenario not exercised\033[0m\n'
  pass "expect unavailable: migrate-source-advisory path skipped (limitation noted)"
  t_summary
  exit "$?"
fi

SB="$(sandbox)"; RC="$SB/.bashrc"; touch "$RC"
SRC="$SB/old-config"                     # the COMPLEX source we import FROM
T="$SB/.claude-work"                     # fresh target (does NOT exist → no rebuild path)

# ── seed a complex SOURCE config (all three complexity signals + real content) ─
mkdir -p "$SRC/agents" "$SRC/myframework/MEMORY"
echo '{"mcpServers":{"demo":{"command":"x"}}}' > "$SRC/settings.json"   # MCP signal
printf '# memory\n@~/shared/agents.md\n'        > "$SRC/CLAUDE.md"      # @-import signal
echo 'framework'                                > "$SRC/myframework/MEMORY/n.md" # bespoke top-level
echo 'my agent'                                 > "$SRC/agents/a.md"     # something to migrate

SEL="secure-settings leak-guard"          # no statusline → no location-pin prompt

EXP="$SB/drive.exp"
cat > "$EXP" <<EXPECT
set timeout 90
set env(HOME) "$SB"
set env(SHELL) "/bin/bash"
set env(NO_COLOR) "1"
set env(CT_ADDITIONS) "$SEL"
spawn bash "$REPO_ROOT/install.sh" --no-auth-inherit
expect {
  -re {Config folder to create/update} { send "$T\r";   exp_continue }
  -re {Shell alias to launch it}        { send "\r";     exp_continue }
  -re {Migrate items from an existing}  { send "y\r";    exp_continue }
  -re {Migrate FROM which config}       { send "$SRC\r"; exp_continue }
  -re {merge your existing settings}    { send "y\r";    exp_continue }
  -re {copy your CLAUDE.md}             { send "n\r";    exp_continue }
  -re {migrate which}                   { send "all\r";  exp_continue }
  -re {also migrate session history}    { send "n\r";    exp_continue }
  -re {skip any}                        { send "\r";     exp_continue }
  -re {keep any}                        { send "\r";     exp_continue }
  -re {Set up another config folder}    { send "n\r";    exp_continue }
  eof {}
}
catch wait result
exit [lindex \$result 3]
EXPECT

expect -f "$EXP" > "$SB/log" 2>&1
rc=$?
LOG="$SB/log.clean"; tr -d '\r' < "$SB/log" > "$LOG"

assert_eq "installer exits 0 migrating from a complex source" "0" "$rc"

# ── the SOURCE-complexity advisory fired and pointed at Path A ────────────────
assert_grep "import advisory shown"          'importing from looks complex' "$LOG"
assert_grep "advisory flags MCP servers"     'MCP servers'      "$LOG"
assert_grep "advisory flags @-imports"       '@-imports'        "$LOG"
assert_grep "advisory points at Path A"      'agent-install.md' "$LOG"

# ── but migration still proceeded (advisory only) ────────────────────────────
assert_file "target profile created"          "$T"
assert_file "kit hook installed in target"    "$T/hooks/leak-guard.sh"
assert_file "source agent migrated verbatim"  "$T/agents/a.md"
assert_ok   "target settings.json valid JSON" jq -e . "$T/settings.json"
assert_ok   "source MCP servers copied verbatim" \
  bash -c "jq -e '.mcpServers.demo != null' '$T/settings.json' >/dev/null"

t_summary
