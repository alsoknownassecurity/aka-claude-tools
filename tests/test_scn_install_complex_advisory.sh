#!/usr/bin/env bash
# Scenario T22 — a COMPLEX existing config steers away from a destructive rebuild.
#
# detect_config_complexity flags configs that a deterministic copy can't reason
# about (MCP servers, CLAUDE.md @-imports, bespoke top-level content). For those,
# the installer:
#   • prints an advisory recommending Path A (agent-install.md),
#   • DEFAULTS the rebuild prompt to N — even for the default dir ~/.claude, which
#     normally defaults YES — so a bare Enter does NOT trigger the rebuild,
#   • on decline, LAYERS the additions in place (lossless) and says so — the user
#     is never dropped out of the installer.
#
# Driven over a pty with `expect`, NO_COLOR=1 so the prompt hint is clean, ANSI-free
# text (the colored "[Y/n]" hint otherwise sits between escape codes and defeats a
# naive matcher — the robustness fix this scenario also guards). A bare Enter at the
# rebuild prompt accepts the (now-N) default. Fully sandboxed; never touches a real
# ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_complex_advisory:"

if ! command -v expect >/dev/null 2>&1; then
  printf '  \033[33m! expect not found — cannot drive the interactive path here; scenario not exercised\033[0m\n'
  pass "expect unavailable: complex-advisory path skipped (limitation noted)"
  t_summary
  exit "$?"
fi

SB="$(sandbox)"; RC="$SB/.bashrc"; touch "$RC"
P="$SB/.claude"                              # default dir (is_default=1 → would default YES)

# ── seed a COMPLEX default profile: each of the three complexity signals ──────
mkdir -p "$P/hooks"
echo '{"theme":"dark","mcpServers":{"demo":{"command":"x"}}}' > "$P/settings.json"  # MCP signal
printf '# memory\n@~/shared/agents.md\n' > "$P/CLAUDE.md"                            # @-import signal
mkdir -p "$P/myframework/MEMORY"; echo 'framework' > "$P/myframework/MEMORY/note.md"                 # bespoke top-level
echo 'do not move me' > "$P/myframework/keepme.txt"
echo '{"oauthAccount":{"emailAddress":"x@y.z"}}' > "$SB/.claude.json"

SEL="secure-settings leak-guard wrap-up"

EXP="$SB/drive.exp"
cat > "$EXP" <<EXPECT
set timeout 90
set env(HOME) "$SB"
set env(SHELL) "/bin/bash"
set env(NO_COLOR) "1"
set env(CT_ADDITIONS) "$SEL"
spawn bash "$REPO_ROOT/install.sh" --no-auth-inherit
expect {
  -re {Config folder to create/update} { send "$P\r"; exp_continue }
  -re {[Bb]ack up.*rebuild it clean}    { send "\r";  exp_continue }
  -re {Migrate items from an existing}  { send "n\r"; exp_continue }
  -re {Set up another config folder}    { send "n\r"; exp_continue }
  -re {skip any}                        { send "\r";  exp_continue }
  -re {keep any}                        { send "\r";  exp_continue }
  eof {}
}
catch wait result
exit [lindex \$result 3]
EXPECT

expect -f "$EXP" > "$SB/log" 2>&1
rc=$?
LOG="$SB/log.clean"; tr -d '\r' < "$SB/log" > "$LOG"   # NO_COLOR=1 already → no ANSI to strip

assert_eq "installer exits 0 over the complex default dir" "0" "$rc"

# ── the advisory fired and recommended Path A ─────────────────────────────────
assert_grep "complexity advisory shown"     'complex config' "$LOG"
assert_grep "advisory flags MCP servers"    'MCP servers'     "$LOG"
assert_grep "advisory flags @-imports"      '@-imports'       "$LOG"
assert_grep "advisory points at Path A"     'agent-install.md' "$LOG"
assert_grep "advisory reassures: not dropped out" "dropped out" "$LOG"

# ── rebuild prompt DEFAULTED N (complex overrode the default-dir YES) ─────────
# NO_COLOR=1 → the hint is the literal "[y/N]" (capital N = default no).
assert_lit  "rebuild prompt rendered default-NO hint [y/N]" \
  "rebuild it clean? [y/N]" "$LOG"

# ── bare Enter declined → NO backup, layered in place ─────────────────────────
n_bak=$(find "$SB" -maxdepth 1 -type d -name '.claude.backup-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq   "NO backup created (rebuild declined by default)" "0" "$n_bak"
assert_grep "log says it layered in place" 'Layering additions onto' "$LOG"

# ── additions were still installed (layer-in-place is lossless, not an exit) ──
assert_file "kit hook layered onto the existing dir" "$P/hooks/leak-guard.sh"
assert_file "command layered onto the existing dir"  "$P/commands/wrap-up.md"
assert_ok   "settings.json still valid JSON"         jq -e . "$P/settings.json"
assert_ok   "kit secure-baseline deny merged in"     \
  bash -c "jq -e '((.permissions.deny // []) | length) > 0' '$P/settings.json' >/dev/null"
assert_ok   "user's MCP servers untouched in place"  \
  bash -c "jq -e '(.mcpServers.demo != null) and (.theme == \"dark\")' '$P/settings.json' >/dev/null"

# ── the bespoke content was NOT moved/backed-up — it stayed exactly in place ──
assert_file "myframework/ framework still in place (not moved to a backup)" "$P/myframework/MEMORY/note.md"
assert_file "bespoke file still in place"                           "$P/myframework/keepme.txt"
assert_grep "CLAUDE.md @-import preserved in place"  '@~/shared/agents.md' "$P/CLAUDE.md"

t_summary
